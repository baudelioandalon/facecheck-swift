import Foundation

/// Drives one liveness session: positioning, then a plan of challenges, then a
/// still capture, ending in ``LivenessState/done(_:)`` or ``LivenessState/failed(_:)``.
///
/// ## This class is UX, not security
///
/// Read this before building anything on top of it.
///
/// The machine runs on a device the attacker controls. Every input it sees is a
/// ``FaceFrame`` — a handful of floats produced by code on that same device. An
/// attacker rooting the phone, hooking the detector, or feeding a virtual camera
/// does not have to turn his head; he emits `yaw = -30` and the challenge
/// passes. No threshold in ``LivenessConfig`` changes that, and neither would ten
/// more challenge types, because the problem is not which values are demanded
/// but who computes them.
///
/// So what is it for? Two real jobs:
///
/// - **Coaching.** It walks a cooperative user into producing one good, frontal,
///   sharp, well-lit still photo. That is what the accuracy of the whole system
///   rests on, and it is what most users fail at without guidance.
/// - **Raising the floor.** It defeats the casual attack — holding up a printed
///   photo or a still on another phone — because a photo cannot turn its head.
///   It does not defeat a video replay, a 3D mask, or a hooked build.
///
/// The actual decision belongs to the backend, which receives a photo and matches
/// it against a stored template under a threshold the SDK never sees and cannot
/// influence. Nothing this class produces is sent as proof of anything: a `done`
/// state means "we captured a usable photo", never "this person is real".
/// Treating it as an authorisation would put the security boundary inside the
/// attacker's own process.
///
/// ## Purity
///
/// There is no clock, no camera, no dispatcher and no platform code here. Time
/// comes exclusively from ``FaceFrame/timestampMs`` (or ``onTick(nowMs:)``), so a
/// test drives a twenty-second session in microseconds and a slow device
/// measures elapsed time in frames it actually received rather than in seconds it
/// spent stalled.
///
/// ## Concurrency
///
/// The Kotlin original says "not thread-safe, feed it from one thread". That is
/// not enough in Swift 6: the host builds the machine (typically on the main
/// actor, so the UI can subscribe before the session starts) and the frame pump
/// feeds it from the video-analysis queue, so the type has to cross isolation
/// domains. Every mutable field therefore lives behind one lock, and the new
/// state is published **outside** that lock — each entry point accumulates the
/// last assignment of the call and does a single ``StateStream/send(_:)`` on the
/// way out, so subscriber code never runs re-entrantly with the lock held.
///
/// Publishing only the final state per call is also faithful to `StateFlow`:
/// `beginPositioning` followed by `handlePositioning` assigns twice within one
/// `onFrame`, and conflation made the intermediate invisible anyway.
///
/// Publications are additionally kept in the order the states were computed —
/// see `publishLock`. Two threads (the pump and a host calling ``cancel()``)
/// otherwise publish out of order, and against a conflated stream that loses the
/// terminal state outright rather than merely delaying it.
///
/// Deliberately **not** an actor: that would force `await onFrame`, break the
/// synchronous determinism the tests rely on, and add an executor hop per frame
/// at 30 fps.
public final class ChallengeMachine: @unchecked Sendable {

    /// The plan, in order.
    public let challenges: [Challenge]

    /// The current step, for the UI to render. Replays its latest value.
    public let state: StateStream<LivenessState>

    private let config: LivenessConfig

    /// Guards every field below. Never held across a ``StateStream/send(_:)``.
    private let lock = NSLock()

    /// Orders publications against each other, and nothing else.
    ///
    /// Taken while ``lock`` is still held and released only after the send, so
    /// states reach ``state`` in the order they were computed. Without it two
    /// callers can compute A then B and publish B then A, and because the stream
    /// conflates and buffers only the newest value, a terminal state published
    /// out of order is not merely late — it is **lost**: the machine will never
    /// publish again (every later call returns early on the terminal state), so
    /// a UI bound to `values` keeps painting the stale instruction forever and a
    /// consumer waiting for a terminal state waits forever.
    ///
    /// The realistic interleaving is not exotic: the host calls ``cancel()`` on
    /// the main actor while the capture queue is inside ``onFrame(_:)``.
    ///
    /// Acquisition order is always `lock` then `publishLock` and never the
    /// reverse, so the pair cannot deadlock. Frame handling is not serialised
    /// behind a send — only publication is — and a send never blocks, because
    /// yielding to an `AsyncStream` and resuming a continuation both just hand
    /// work to the executor.
    private let publishLock = NSLock()

    // MARK: Session-scoped mutable state, all guarded by `lock`

    /// Start of the deadline for whatever step is current.
    private var stepStartedMs: Int64 = 0

    /// Timestamp of the last frame that actually contained one face.
    private var lastFaceSeenMs: Int64 = 0

    /// Start of the current "hold still" run, or nil if it has been broken.
    private var holdStartedMs: Int64?

    /// The tracking id the session is bound to, once the detector reports one.
    private var boundTrackingId: Int?
    private var trackingBound = false

    private var challengeIndex = 0
    private var phase: ChallengePhase = .awaitingAction

    /// Best frame seen during positioning, by `scoreAsPrimary`.
    private var primaryFrame: FaceFrame?
    private var primaryScore: Float = -.infinity

    /// Most extreme frame of the challenge in flight.
    ///
    /// `extremeMagnitude` carries degrees of turn for a turn challenge and a
    /// 0..1 score for a centre hold. Mixing units in one field is safe only
    /// because `startChallenge` resets it to `-infinity` for every challenge.
    /// Port it as-is; it is not a bug to "fix".
    private var extremeFrame: FaceFrame?
    private var extremeMagnitude: Float = -.infinity

    private var completed: [ChallengeCapture] = []

    /// The authoritative state while a call is in flight.
    ///
    /// Kotlin reads and writes `_state.value` directly, but publishing from
    /// inside the lock would run subscriber code re-entrantly, so the machine
    /// works against this mirror and hands the final value to ``state`` on the
    /// way out of every entry point.
    private var currentState: LivenessState = .idle

    /// - Parameters:
    ///   - challenges: the plan, in order. Must not be empty; build one with
    ///     ``ChallengePlan/random(count:)``.
    ///   - config: thresholds and deadlines.
    /// - Throws: ``FaceCheckError`` with ``FaceCheckErrorCode/invalidConfig``
    ///   when `challenges` is empty.
    public init(challenges: [Challenge], config: LivenessConfig = .default) throws {
        guard !challenges.isEmpty else {
            throw FaceCheckError(
                code: .invalidConfig,
                message: "Una sesión de prueba de vida necesita al menos un reto."
            )
        }
        self.challenges = challenges
        self.config = config
        self.state = StateStream(.idle)
    }

    /// Feed one analysed frame.
    ///
    /// Ignored once ``state`` is terminal, so a camera that keeps delivering
    /// frames after the session ended cannot resurrect or corrupt it.
    ///
    /// The evaluation order is normative — changing it changes which failure
    /// wins: terminal check, begin positioning if idle, **deadlines**, then
    /// `faceCount > 1`, then `faceCount <= 0`, then the tracking-id bind, then
    /// per-state dispatch. Deadlines are checked before the frame is scored so a
    /// frame that arrives after the step expired cannot complete it.
    public func onFrame(_ frame: FaceFrame) {
        publishing {
            if currentState.isTerminal { return }

            if case .idle = currentState {
                beginPositioning(frame.timestampMs)
            }

            if checkDeadlines(frame.timestampMs) { return }

            if frame.faceCount > 1 {
                fail(.multipleFaces)
                return
            }
            if frame.faceCount <= 0 {
                onFaceMissing(frame.timestampMs)
                return
            }
            if !bindTracking(frame) {
                fail(.faceSwapped)
                return
            }
            lastFaceSeenMs = frame.timestampMs

            switch currentState {
            case .positioning:
                handlePositioning(frame)
            case .challengeActive(let active):
                handleChallenge(frame, current: active)
            default:
                // Capturing only needs the face to still be there, which the
                // checks above established. Idle cannot survive to here and the
                // terminal cases returned at the top.
                break
            }
        }
    }

    /// Advance deadlines without a frame.
    ///
    /// A no-op when idle or terminal. Exists so a session can still time out
    /// when the camera stops delivering frames altogether — frames are the only
    /// clock the machine has.
    public func onTick(nowMs: Int64) {
        publishing {
            if currentState.isTerminal { return }
            if case .idle = currentState { return }
            _ = checkDeadlines(nowMs)
        }
    }

    /// Move from ``LivenessState/capturing`` to ``LivenessState/done(_:)``.
    ///
    /// - Throws: ``FaceCheckError`` when the machine is not currently capturing.
    ///   A machine that failed **while** the photo was being taken reports that
    ///   failure's own code and message, not a misuse error; see below.
    public func completeCapture() throws {
        try publishingThrowing {
            guard case .capturing = currentState else {
                // Losing the session during the capture is a runtime condition,
                // not a caller mistake: the frame pump keeps feeding the machine
                // while `captureStill()` is in flight — deliberately, so
                // `lastFaceSeenMs` stays fresh — so a slow shutter can outlive
                // `captureTimeoutMs`, and a user who lowers the phone at the
                // sound of it trips `faceLostGraceMs`. Reporting either as
                // `invalidConfig` would put a message written for the SDK's
                // integrator in front of the end user, and would make a host that
                // switches on `error.code` treat a timeout as a build defect.
                if case .failed(let reason) = currentState {
                    throw FaceCheckError(code: reason.errorCode, message: reason.messageEs)
                }
                // Anything else — idle, positioning, an already-done session — is
                // genuine misuse. Kotlin raises IllegalStateException here; there
                // is no error code for "the SDK was driven wrong", so this reuses
                // the one the other local-misuse failures in this layer use.
                throw FaceCheckError(
                    code: .invalidConfig,
                    message: "completeCapture() solo es válido durante la captura."
                )
            }
            guard let primary = primaryFrame else {
                // Positioning cannot reach capturing without electing a primary
                // frame, so this is a broken invariant rather than a runtime
                // condition any caller can produce or recover from.
                preconditionFailure(
                    "reached capturing without a primary frame, which positioning cannot allow"
                )
            }
            currentState = .done(
                LivenessEvidence(primary: primary, challenges: completed)
            )
        }
    }

    /// End the session as ``FailureReason/cancelled``. Idempotent, and a no-op
    /// once the state is terminal.
    public func cancel() {
        publishing {
            if currentState.isTerminal { return }
            fail(.cancelled)
        }
    }

    /// Clear everything — deadlines, bound tracking id, selected frames — and
    /// return to ``LivenessState/idle``, leaving the instance reusable for
    /// another session.
    public func reset() {
        publishing {
            stepStartedMs = 0
            lastFaceSeenMs = 0
            holdStartedMs = nil
            boundTrackingId = nil
            trackingBound = false
            challengeIndex = 0
            phase = .awaitingAction
            primaryFrame = nil
            primaryScore = -.infinity
            extremeFrame = nil
            extremeMagnitude = -.infinity
            completed.removeAll()
            currentState = .idle
        }
    }

    // MARK: Publication

    /// Runs `body` under the lock and publishes at most one state change on the
    /// way out, so subscriber code never runs with the lock held.
    ///
    /// One publication per call is also faithful to `StateFlow`: `onFrame` can
    /// assign twice (begin positioning, then handle it) and conflation made the
    /// intermediate invisible anyway.
    private func publishing(_ body: () -> Void) {
        lock.lock()
        body()
        let latest = currentState
        // Hand over hand: claiming the publish lock before releasing `lock` is
        // what makes the publication order match the mutation order. See
        // `publishLock`.
        publishLock.lock()
        lock.unlock()
        state.send(latest)
        publishLock.unlock()
    }

    /// Same, for the one entry point that can reject before it mutates. A
    /// separate name rather than an overload, so no call site ever has to be
    /// resolved by whether its closure happens to throw.
    private func publishingThrowing<R>(_ body: () throws -> R) throws -> R {
        lock.lock()
        let result: R
        do {
            result = try body()
        } catch {
            // Nothing was published because nothing was assigned: every throwing
            // path in this type rejects before it mutates.
            lock.unlock()
            throw error
        }
        let latest = currentState
        publishLock.lock()
        lock.unlock()
        state.send(latest)
        publishLock.unlock()
        return result
    }

    // MARK: Steps, all called with `lock` held

    private func beginPositioning(_ nowMs: Int64) {
        stepStartedMs = nowMs
        lastFaceSeenMs = nowMs
        holdStartedMs = nil
        currentState = .positioning(hint: .noFace, holdProgress: 0)
    }

    private func handlePositioning(_ frame: FaceFrame) {
        // Scored before the pose gate: the sharpest, most frontal frame is worth
        // keeping even if the user has not yet held it long enough to advance.
        offerAsPrimary(frame)

        if let problem = positioningProblem(frame) {
            holdStartedMs = nil
            currentState = .positioning(hint: problem, holdProgress: 0)
            return
        }

        let start: Int64
        if let existing = holdStartedMs {
            start = existing
        } else {
            start = frame.timestampMs
            holdStartedMs = start
        }

        let held = frame.timestampMs - start
        if held >= config.positioningHoldMs {
            startChallenge(0, nowMs: frame.timestampMs)
        } else {
            let ratio = config.positioningHoldMs == 0
                ? 1
                : Float(held) / Float(config.positioningHoldMs)
            currentState = .positioning(hint: .ok, holdProgress: min(max(ratio, 0), 1))
        }
    }

    /// What is wrong with this frame as a starting pose, or nil if nothing is.
    ///
    /// Ordered by what the user should fix first: being out of frame beats being
    /// badly lit, which beats being slightly off-axis.
    private func positioningProblem(_ frame: FaceFrame) -> PositioningHint? {
        if frame.faceRatio < config.minFaceRatio { return .moveCloser }
        if frame.faceRatio > config.maxFaceRatio { return .moveAway }
        if frame.quality.detectorScore < config.minDetectorScore { return .noFace }
        if frame.quality.brightness < config.minBrightness { return .tooDark }
        if frame.quality.brightness > config.maxBrightness { return .tooBright }
        if frame.quality.sharpness < config.minSharpness { return .lowQuality }
        if abs(frame.roll) > config.maxRollDeg { return .straightenHead }
        if abs(frame.yaw) > config.centerToleranceDeg { return .lookStraight }
        if abs(frame.pitch) > config.centerToleranceDeg { return .lookStraight }
        return nil
    }

    private func startChallenge(_ index: Int, nowMs: Int64) {
        challengeIndex = index
        phase = .awaitingAction
        stepStartedMs = nowMs
        holdStartedMs = nil
        extremeFrame = nil
        extremeMagnitude = -.infinity
        currentState = .challengeActive(
            LivenessState.ChallengeActive(
                challenge: challenges[index],
                index: index,
                total: challenges.count,
                phase: .awaitingAction
            )
        )
    }

    private func handleChallenge(_ frame: FaceFrame, current: LivenessState.ChallengeActive) {
        // A face that drifted out of range still counts as present — the swap
        // and face-lost checks already passed — but it cannot advance the
        // challenge, because a pose measured on a face too small to resolve is
        // noise. Nothing else gates a challenge: brightness, sharpness and
        // detector score are positioning concerns only.
        let blocking: PositioningHint?
        if frame.faceRatio < config.minFaceRatio {
            blocking = .moveCloser
        } else if frame.faceRatio > config.maxFaceRatio {
            blocking = .moveAway
        } else {
            blocking = nil
        }

        if let blocking {
            holdStartedMs = nil
            var next = current
            next.hint = blocking
            currentState = .challengeActive(next)
            return
        }

        switch challenges[challengeIndex] {
        case .turnLeft: handleTurn(frame, current: current, toTheLeft: true)
        case .turnRight: handleTurn(frame, current: current, toTheLeft: false)
        case .center: handleCenter(frame, current: current)
        }
    }

    /// A turn is two events, not one: reach the angle, then come back to frontal.
    ///
    /// The return leg is what makes this a movement rather than a pose. Scoring
    /// only the extreme angle would accept a photograph held at the right angle;
    /// it cannot also be held straight a moment later.
    ///
    /// Turning the *wrong* way is not a failure — users overshoot and correct all
    /// the time — it simply does not advance anything, so a wrong turn burns the
    /// challenge's deadline and nothing else. That is also what keeps a later
    /// challenge from being satisfied early by a movement made during this one.
    private func handleTurn(
        _ frame: FaceFrame,
        current: LivenessState.ChallengeActive,
        toTheLeft: Bool
    ) {
        let reached = toTheLeft
            ? frame.yaw <= -config.turnThresholdDeg
            : frame.yaw >= config.turnThresholdDeg

        // Track the most extreme frame in the requested direction only. The
        // frame is worth keeping whether or not the threshold has been crossed
        // yet, but a yaw in the opposite direction never represents this
        // challenge.
        let signedMagnitude = toTheLeft ? -frame.yaw : frame.yaw
        if signedMagnitude > 0, signedMagnitude > extremeMagnitude {
            extremeMagnitude = signedMagnitude
            extremeFrame = frame
        }

        switch phase {
        case .awaitingAction:
            if reached {
                phase = .returningToCenter
                var next = current
                next.phase = phase
                next.hint = nil
                currentState = .challengeActive(next)
            } else if current.hint != nil {
                var next = current
                next.hint = nil
                currentState = .challengeActive(next)
            }

        case .returningToCenter:
            // Only yaw is inspected on the way back: a chin that drifted while
            // the head swung is not something to fail a cooperative user for.
            if abs(frame.yaw) < config.centerToleranceDeg {
                finishChallenge(nowMs: frame.timestampMs)
            } else if current.hint != nil {
                var next = current
                next.hint = nil
                currentState = .challengeActive(next)
            }
        }
    }

    /// ``Challenge/center`` is a hold, not a movement: frontal for
    /// ``LivenessConfig/centerHoldMs`` without interruption.
    private func handleCenter(_ frame: FaceFrame, current: LivenessState.ChallengeActive) {
        let frontal = abs(frame.yaw) < config.centerToleranceDeg
            && abs(frame.pitch) < config.centerToleranceDeg
        if !frontal {
            holdStartedMs = nil
            var next = current
            next.hint = .lookStraight
            currentState = .challengeActive(next)
            return
        }

        // "Most extreme" for a hold means "most frontal and sharpest".
        let score = scoreAsPrimary(frame)
        if score > extremeMagnitude {
            extremeMagnitude = score
            extremeFrame = frame
        }

        let start: Int64
        if let existing = holdStartedMs {
            start = existing
        } else {
            start = frame.timestampMs
            holdStartedMs = start
        }

        if frame.timestampMs - start >= config.centerHoldMs {
            finishChallenge(nowMs: frame.timestampMs)
        } else if current.hint != nil {
            var next = current
            next.hint = nil
            currentState = .challengeActive(next)
        }
    }

    private func finishChallenge(nowMs: Int64) {
        guard let frame = extremeFrame else {
            // Every path that completes a challenge has already recorded a frame
            // for it; reaching here would mean the machine's own bookkeeping is
            // broken, not that a caller did something wrong.
            preconditionFailure("a challenge completed without ever recording a frame for it")
        }
        completed.append(ChallengeCapture(challenge: challenges[challengeIndex], frame: frame))

        let next = challengeIndex + 1
        if next < challenges.count {
            startChallenge(next, nowMs: nowMs)
        } else {
            stepStartedMs = nowMs
            holdStartedMs = nil
            currentState = .capturing
        }
    }

    // MARK: Guards

    /// Bind the session to a tracking identity, or report that it changed.
    ///
    /// The first frame that carries an id claims it. A later frame carrying a
    /// *different* id means the detector stopped following the face this session
    /// started with, which is either a genuine re-acquisition or a swap — and the
    /// machine cannot tell those apart, so it treats both as a swap. Frames with
    /// a nil id are accepted without binding: a detector running in single-image
    /// mode reports no identity at all, and refusing to work on those platforms
    /// would be worse than losing the check there.
    ///
    /// - Returns: false when the identity changed.
    private func bindTracking(_ frame: FaceFrame) -> Bool {
        guard let incoming = frame.trackingId else { return true }
        guard trackingBound, let bound = boundTrackingId else {
            boundTrackingId = incoming
            trackingBound = true
            return true
        }
        return bound == incoming
    }

    private func onFaceMissing(_ nowMs: Int64) {
        switch currentState {
        case .positioning:
            // Nothing has been asked of the user yet, so a missing face is a
            // prompt, not a failure. The positioning deadline still applies.
            holdStartedMs = nil
            currentState = .positioning(hint: .noFace, holdProgress: 0)

        case .challengeActive(let current):
            // checkDeadlines already failed the session if the gap ran past the
            // grace period, so reaching here means it is still within it. The
            // hold is deliberately *not* reset, which is what lets a centre hold
            // survive a one-frame detector dropout.
            var next = current
            next.hint = .noFace
            currentState = .challengeActive(next)

        default:
            break
        }
    }

    /// Fail the session if any deadline has passed.
    ///
    /// - Returns: true when the session ended here, in which case the caller
    ///   must stop processing the frame.
    private func checkDeadlines(_ nowMs: Int64) -> Bool {
        let elapsed = nowMs - stepStartedMs

        let limit: Int64?
        switch currentState {
        case .positioning: limit = config.positioningTimeoutMs
        case .challengeActive: limit = config.challengeTimeoutMs
        case .capturing: limit = config.captureTimeoutMs
        default: limit = nil
        }
        // Strictly greater: a step that lands exactly on its deadline still counts.
        if let limit, elapsed > limit {
            fail(.timeout)
            return true
        }

        // Only meaningful once the user has been asked to do something. While
        // positioning, "no face" is the normal starting condition.
        let watchesForLoss: Bool
        switch currentState {
        case .challengeActive, .capturing: watchesForLoss = true
        default: watchesForLoss = false
        }
        if watchesForLoss, nowMs - lastFaceSeenMs > config.faceLostGraceMs {
            fail(.faceLost)
            return true
        }
        return false
    }

    // MARK: Frame selection

    private func offerAsPrimary(_ frame: FaceFrame) {
        if frame.faceRatio < config.minFaceRatio { return }
        if frame.faceRatio > config.maxFaceRatio { return }
        if frame.quality.detectorScore < config.minDetectorScore { return }
        let score = scoreAsPrimary(frame)
        if score > primaryScore {
            primaryScore = score
            primaryFrame = frame
        }
    }

    /// How good a frame is as *the* photo of this face: mostly how frontal it
    /// is, partly how sharp.
    ///
    /// Frontality dominates because pose is what actually moves an ArcFace
    /// embedding — a sharp three-quarter profile matches worse than a slightly
    /// soft frontal shot. Roll counts half: the backend re-aligns on the five
    /// landmarks, so a tilted head costs less than a turned one.
    private func scoreAsPrimary(_ frame: FaceFrame) -> Float {
        let deviation = abs(frame.yaw) + abs(frame.pitch) + abs(frame.roll) / 2
        let frontality = min(max(1 - (deviation / Self.maxUsefulDeviationDeg), 0), 1)
        let sharpness = min(max(frame.quality.sharpness / FrameQuality.sharpnessReference, 0), 1)
        return frontality * Self.frontalityWeight + sharpness * Self.sharpnessWeight
    }

    private func fail(_ reason: FailureReason) {
        currentState = .failed(reason)
    }

    /// Deviation beyond which extra degrees no longer tell us anything useful.
    static let maxUsefulDeviationDeg: Float = 90

    /// Frontality dominates the frame score because pose is what moves the
    /// embedding; roll counts half because the backend re-aligns on landmarks.
    static let frontalityWeight: Float = 0.7
    static let sharpnessWeight: Float = 0.3
}

/// A completed liveness session: the photo to upload, plus what was seen.
///
/// Kotlin needed a hand-written `equals`/`hashCode` here because the generated
/// ones compare `ByteArray` by identity. `Data` compares by content, which is
/// what anyone would expect, so that code disappears.
struct LivenessCapture: Sendable, Equatable {

    /// JPEG bytes from ``CameraController/captureStill()``.
    let still: Data

    let evidence: LivenessEvidence
}

/// Injectable delay, so tests do not actually wait.
///
/// Swift has no virtual clock equivalent to `runTest`, and the session runner
/// has to be testable at a 200 ms timeout without spending 200 ms.
protocol Sleeping: Sendable {
    func sleep(milliseconds: Int64) async throws
}

/// The real one: `Task.sleep(nanoseconds:)`.
///
/// Not `Task.sleep(for:)`/`ContinuousClock` — both are iOS 16 and the floor is 15.
struct SystemSleeper: Sleeping {
    init() {}

    func sleep(milliseconds: Int64) async throws {
        // Guarded because `UInt64(negative)` traps, and a caller reaching this
        // with a non-positive deadline wants "already expired", not a crash.
        guard milliseconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
    }
}

/// Thrown by ``withTimeout(milliseconds:sleeper:_:)`` when the body loses the race.
///
/// A distinct type rather than `CancellationError` on purpose: a parent task
/// that was cancelled must not be reported to the user as
/// "la verificación tardó demasiado".
struct TimeoutError: Error, Sendable {
    init() {}
}

/// Runs `body` against a sleeper and throws ``TimeoutError`` if the sleeper wins.
///
/// Replaces Kotlin's `withTimeout`. The loser of the race is cancelled.
func withTimeout<T: Sendable>(
    milliseconds: Int64,
    sleeper: any Sleeping,
    _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: TimeoutRace<T>.self) { group in
        group.addTask { .finished(try await body()) }
        group.addTask {
            try await sleeper.sleep(milliseconds: milliseconds)
            return .expired
        }

        // Whoever reports first decides. Leaving the group cancels the loser and
        // drains it, so neither task outlives this call.
        guard let first = try await group.next() else { throw TimeoutError() }
        group.cancelAll()
        switch first {
        case .finished(let value): return value
        case .expired: throw TimeoutError()
        }
    }
}

/// Which side of the ``withTimeout(milliseconds:sleeper:_:)`` race reported.
///
/// A named type because a generic one cannot be declared inside a generic
/// function.
private enum TimeoutRace<T: Sendable>: Sendable {
    case finished(T)
    case expired
}

/// What the session runner is waiting on inside its task group.
private enum SessionStep: Sendable {
    /// The frame stream ended by itself. Not a verdict — the gate still rules.
    case pumpEnded
    /// The machine reached a state the runner gates on.
    case gate(LivenessState)
}

/// Runs one liveness session end to end: pump frames into `machine`, take the
/// still when it asks for one, and stop the camera no matter how it ends.
///
/// The camera is released in a `defer` at the outermost level. A verification
/// that throws must not leave the camera light on — users read that as the app
/// spying on them, and they are not entirely wrong to.
///
/// Sequence: `camera.start()`; inside the global timeout, a task group runs a
/// pump (`for await frame in camera.frames { machine.onFrame(frame) }`) against
/// the gate `machine.state.first { $0 is .capturing or .failed }`. A `.failed`
/// gate throws ``FaceCheckError`` built from the reason's own error code and
/// Spanish message. A `.capturing` gate calls `camera.captureStill()`, then
/// `machine.completeCapture()`, then reads back the `.done` evidence.
///
/// The pump is cancelled in a `defer` that runs **after** the capture, never
/// before: while `captureStill()` is in flight the machine still needs frames to
/// refresh `lastFaceSeenMs`, or it fails with `faceLost` after 1500 ms. The flip
/// side is that the machine can still fail *during* the capture, which is why
/// ``ChallengeMachine/completeCapture()`` reports that failure's own code rather
/// than a misuse error.
///
/// - Throws: ``FaceCheckError`` with ``FaceCheckErrorCode/timeout`` and the
///   message "La verificación tardó demasiado. Vuelve a intentarlo." when the
///   global deadline expires. A `CancellationError` propagated from the parent
///   is rethrown unchanged.
func runLivenessSession(
    camera: any CameraController,
    machine: ChallengeMachine,
    timeoutMs: Int64,
    sleeper: any Sleeping = SystemSleeper()
) async throws -> LivenessCapture {
    camera.start()
    defer { camera.stop() }

    do {
        return try await withTimeout(milliseconds: timeoutMs, sleeper: sleeper) {
            try await withThrowingTaskGroup(of: SessionStep.self) { group in
                group.addTask {
                    // The stream is also the camera's failure channel, so an
                    // error here must reach `group.next()` rather than being
                    // logged and swallowed: a swallowed camera failure leaves
                    // the user staring at black until the global deadline.
                    for try await frame in camera.frames {
                        machine.onFrame(frame)
                    }
                    return .pumpEnded
                }
                group.addTask {
                    // The stream replays its current value, so a session that
                    // already failed before this subscribes is still observed.
                    .gate(
                        await machine.state.first { state in
                            switch state {
                            case .capturing, .failed: return true
                            default: return false
                            }
                        }
                    )
                }

                var gate: LivenessState?
                while gate == nil, let step = try await group.next() {
                    switch step {
                    case .pumpEnded:
                        continue
                    case .gate(let state):
                        // `first(where:)` also returns when the wait is
                        // cancelled, so confirm this is a real transition and
                        // not the global timeout tearing the group down.
                        try Task.checkCancellation()
                        gate = state
                    }
                }

                guard let gate else {
                    // Both children finished without a verdict, which only the
                    // cancellation path can produce.
                    try Task.checkCancellation()
                    throw FaceCheckError(code: .livenessFailed)
                }

                if case .failed(let reason) = gate {
                    FaceCheckLogger.info("liveness failed: \(reason.logName)")
                    throw FaceCheckError(code: reason.errorCode, message: reason.messageEs)
                }

                let still = try await camera.captureStill()
                try machine.completeCapture()
                guard case .done(let evidence) = machine.state.value else {
                    preconditionFailure("completeCapture() did not produce a done state")
                }

                FaceCheckLogger.info(
                    "liveness passed in \(evidence.durationMs) ms with "
                        + "\(evidence.challenges.count) challenges; still is "
                        + FaceCheckLogger.describeBytes(still.count)
                )
                // Leaving the group here is what cancels the pump — after the
                // capture, never before. While `captureStill()` is in flight the
                // machine still needs frames to refresh `lastFaceSeenMs`, or it
                // fails with `faceLost` 1500 ms in, and the capture deadline is
                // still running too.
                return LivenessCapture(still: still, evidence: evidence)
            }
        }
    } catch let expired as TimeoutError {
        // Deliberately not a `CancellationError` catch: a parent that cancelled
        // this call is not a user who ran out of time, and the two must not
        // produce the same message.
        machine.cancel()
        throw FaceCheckError(
            code: .timeout,
            message: "La verificación tardó demasiado. Vuelve a intentarlo.",
            underlying: expired
        )
    }
}
