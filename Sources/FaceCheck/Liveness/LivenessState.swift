import Foundation

#if canImport(Combine)
import Combine
#endif

/// Where a challenge is in its own two-step lifecycle.
public enum ChallengePhase: Sendable, Hashable {

    /// Waiting for the user to reach the pose the challenge asks for.
    case awaitingAction

    /// The pose was reached; now the head has to come back to frontal.
    ///
    /// Requiring the return is what makes the challenge a *movement* rather than
    /// a pose. A single photo held at the right angle satisfies "turn left"; it
    /// cannot also satisfy "and then face forward again". Only turns use this
    /// phase — ``Challenge/center`` lives in ``awaitingAction`` and resolves by
    /// hold.
    case returningToCenter
}

/// The one thing currently standing between the user and the next step.
///
/// The detection order lives in the machine's `positioningProblem`, not here.
public enum PositioningHint: Sendable, Hashable, CaseIterable {
    case ok
    case noFace

    /// Present for API parity with the Kotlin SDK, but never emitted as a hint:
    /// a second face ends the session outright with ``FailureReason/multipleFaces``.
    case multipleFaces

    case moveCloser
    case moveAway
    case lookStraight
    case straightenHead
    case tooDark
    case tooBright
    case lowQuality

    /// The line to show the user, in Spanish.
    public var instructionEs: String {
        switch self {
        case .ok: return "Mantente así"
        case .noFace: return "Coloca tu rostro dentro del marco"
        case .multipleFaces: return "Debe haber solo una persona frente a la cámara"
        case .moveCloser: return "Acércate un poco más a la cámara"
        case .moveAway: return "Aléjate un poco de la cámara"
        case .lookStraight: return "Mira de frente a la cámara"
        case .straightenHead: return "Endereza la cabeza"
        case .tooDark: return "Busca un lugar con más luz"
        case .tooBright: return "Hay demasiada luz de fondo, cámbiate de lugar"
        case .lowQuality: return "Sostén el teléfono firme, la imagen se ve borrosa"
        }
    }
}

/// Why a session ended early. Every message is safe to show the user.
public enum FailureReason: Sendable, Hashable, CaseIterable {

    /// A step ran past its deadline.
    case timeout

    /// The face left the frame for longer than the grace period.
    case faceLost

    /// The tracked face was replaced by a different one mid-session.
    ///
    /// This is the check that stops a session being handed from one person to
    /// another between challenges — one person positions, another completes the
    /// turns. It is UX enforcement, not proof: see ``ChallengeMachine``.
    case faceSwapped

    /// More than one face appeared in frame.
    case multipleFaces

    /// The host app or the user aborted the session.
    case cancelled

    public var messageEs: String {
        switch self {
        case .timeout: return "Se acabó el tiempo. Vuelve a intentarlo."
        case .faceLost: return "Perdimos tu rostro. Mantente dentro del marco e intenta de nuevo."
        case .faceSwapped: return "Detectamos un cambio de persona. Vuelve a empezar."
        case .multipleFaces: return "Debe haber solo una persona frente a la cámara."
        case .cancelled: return "La verificación fue cancelada."
        }
    }

    /// The name Kotlin's `FailureReason.name` prints, for log parity.
    ///
    /// Interpolating the case itself would yield `faceSwapped`, so the same
    /// session failure would be spelled two ways across the two SDKs and a
    /// support engineer grepping `FACE_SWAPPED` across a mixed fleet would find
    /// only half of it. Not `rawValue`: giving the enum a raw type would put
    /// these strings in the public API and invite decoding a backend field into
    /// them, which no wire format ever carries.
    var logName: String {
        switch self {
        case .timeout: return "TIMEOUT"
        case .faceLost: return "FACE_LOST"
        case .faceSwapped: return "FACE_SWAPPED"
        case .multipleFaces: return "MULTIPLE_FACES"
        case .cancelled: return "CANCELLED"
        }
    }

    /// A cancelled session is the user's own decision, not a liveness failure.
    /// The distinction matters because a host app must not show
    /// "no pudimos verificarte" to someone who pressed the back button.
    var errorCode: FaceCheckErrorCode {
        switch self {
        case .cancelled: return .cancelled
        case .timeout: return .timeout
        case .faceLost, .faceSwapped, .multipleFaces: return .livenessFailed
        }
    }
}

/// One challenge and the single frame chosen to represent it.
public struct ChallengeCapture: Sendable, Equatable {

    public let challenge: Challenge

    /// The frame at the most extreme point of the movement. For a turn that is
    /// the largest yaw in the requested direction; for a hold it is the most
    /// frontal and sharpest frame.
    public let frame: FaceFrame

    public init(challenge: Challenge, frame: FaceFrame) {
        self.challenge = challenge
        self.frame = frame
    }
}

/// The frames a completed session selected.
///
/// This is a record of what happened on device, useful for debugging and for a
/// host app that wants to show the user what it saw. It is **not** evidence in
/// the security sense and nothing here is sent to the backend as proof: the
/// backend receives a still photo and decides for itself.
public struct LivenessEvidence: Sendable, Equatable {

    /// The most frontal, sharpest frame seen while positioning.
    public let primary: FaceFrame

    /// One entry per challenge, in the order the plan asked for them.
    public let challenges: [ChallengeCapture]

    public init(primary: FaceFrame, challenges: [ChallengeCapture]) {
        self.primary = primary
        self.challenges = challenges
    }

    /// The primary frame followed by each challenge frame.
    public var frames: [FaceFrame] {
        [primary] + challenges.map(\.frame)
    }

    /// Wall time from the primary frame to the last challenge frame.
    public var durationMs: Int64 {
        (challenges.last?.frame.timestampMs ?? primary.timestampMs) - primary.timestampMs
    }
}

/// What the liveness session is doing right now.
///
/// Emitted on ``ChallengeMachine/state`` so a UI can render the current
/// instruction and progress without knowing anything about yaw thresholds.
/// Every case carries ``instructionEs``, which is the exact string to put on
/// screen — a host app should never have to build one from the state's shape.
public enum LivenessState: Sendable, Equatable {

    /// Nothing has happened yet; no frame has arrived.
    case idle

    /// Waiting for the user to hold a usable frontal pose before the first
    /// challenge. `hint` says what is currently wrong, if anything, and
    /// `holdProgress` is how much of the required steady hold has elapsed, 0..1.
    case positioning(hint: PositioningHint = .noFace, holdProgress: Float = 0)

    /// A challenge is in flight.
    case challengeActive(ChallengeActive)

    /// Every challenge passed; the still photo is being taken.
    ///
    /// The machine cannot take the photo itself — that is I/O — so it parks here
    /// until the orchestrator calls ``ChallengeMachine/completeCapture()``.
    case capturing

    /// The session succeeded. The payload holds the frames that were selected.
    case done(LivenessEvidence)

    /// The session ended without completing. The reason is safe to show the user.
    case failed(FailureReason)

    /// A challenge in flight, with everything the UI needs to render it.
    ///
    /// Bundled into one struct rather than spread across five associated values
    /// because the machine repeatedly needs Kotlin's `current.copy(hint: …)`;
    /// with a struct that is `var next = current; next.hint = x` instead of
    /// rebuilding the whole case at five separate call sites.
    public struct ChallengeActive: Sendable, Equatable {

        public let challenge: Challenge

        /// Zero-based, so "reto 2 de 3" is `index + 1` of ``total``.
        public let index: Int

        public let total: Int

        public var phase: ChallengePhase

        /// A problem that is blocking progress right now (face too far, face
        /// lost). Nil while the user simply has not completed the action yet.
        public var hint: PositioningHint?

        public init(
            challenge: Challenge,
            index: Int,
            total: Int,
            phase: ChallengePhase,
            hint: PositioningHint? = nil
        ) {
            self.challenge = challenge
            self.index = index
            self.total = total
            self.phase = phase
            self.hint = hint
        }

        /// The hint always wins: if the face is too far away, saying "turn your
        /// head" asks for something the user cannot usefully do.
        public var instructionEs: String {
            if let hint { return hint.instructionEs }
            switch phase {
            case .awaitingAction: return challenge.instructionEs
            case .returningToCenter: return "Regresa a ver de frente"
            }
        }

        /// Uses ``index`` rather than `index + 1`, so the first of two
        /// challenges reports 0.0 and the second 0.5.
        public var progress: Float {
            total <= 0 ? 0 : Float(index) / Float(total)
        }
    }

    /// The line to show the user, in Spanish.
    public var instructionEs: String {
        switch self {
        case .idle: return "Prepárate para la verificación"
        case let .positioning(hint, _): return hint.instructionEs
        case let .challengeActive(active): return active.instructionEs
        case .capturing: return "No te muevas, estamos tomando la foto"
        case .done: return "Listo"
        case let .failed(reason): return reason.messageEs
        }
    }

    /// 0..1, for a progress bar. Positioning counts as zero progress.
    public var progress: Float {
        switch self {
        case .idle: return 0
        case .positioning: return 0
        case let .challengeActive(active): return active.progress
        case .capturing: return 1
        case .done: return 1
        case .failed: return 0
        }
    }

    /// True once no further frame can change the outcome.
    public var isTerminal: Bool {
        switch self {
        case .done, .failed: return true
        default: return false
        }
    }
}

/// A `StateFlow` in Swift: one current value, many observers, conflated writes.
///
/// This replaces Kotlin's `MutableStateFlow`/`StateFlow` and exists because none
/// of the obvious Swift options do the job on their own:
///
/// - A bare `AsyncStream` is **single-consumer** (a second `for await` steals
///   elements from the first) and does not replay its current value. The port
///   needs both: the UI and ``runLivenessSession(camera:machine:timeoutMs:sleeper:)``
///   observe at the same time, and there is a test that cancels the session
///   *before* the runner subscribes and still expects to see `.failed` — without
///   replay that hangs forever.
/// - `@Published`/`ObservableObject` forces `MainActor`, which is exactly wrong
///   for a value written from the video-analysis queue at 30 fps, and still does
///   not offer the synchronous read the runner and the tests use. `@Observable`
///   is iOS 17 and the floor here is 15.
///
/// So: ``value`` is a synchronous read, ``values`` hands every subscriber its
/// own stream that replays the current value first, and ``send(_:)`` conflates
/// by equality the way `MutableStateFlow` does — otherwise the UI receives
/// thirty identical states per second while the user holds a pose.
///
/// `@unchecked Sendable` because a lock guards the value, the subscriber table
/// and the one-shot waiters; the compiler cannot see that invariant.
public final class StateStream<Value: Sendable & Equatable>: @unchecked Sendable {

    /// One lock over the value, the subscriber table and the waiter table
    /// together. They have to move as a unit: a value published to the streams
    /// but not tested against the waiters would let the runner's gate sleep
    /// through the very transition it is waiting for.
    private let lock = NSLock()

    private var storage: Value
    private var subscribers: [UUID: AsyncStream<Value>.Continuation] = [:]
    private var waiters: [UUID: Waiter] = [:]

    /// A one-shot `first(where:)` suspension.
    private struct Waiter {
        let predicate: @Sendable (Value) -> Bool
        let continuation: CheckedContinuation<Value, Never>
    }

    public init(_ initial: Value) {
        storage = initial
    }

    /// The current value, read synchronously under the lock.
    public var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    /// A fresh subscription that **replays the current value** as its first
    /// element and then delivers changes, buffering only the newest.
    ///
    /// `bufferingNewest(1)` is deliberate: for painting UI the right thing is
    /// always the most recent state, never a stale instruction.
    public var values: AsyncStream<Value> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            // Installed before the subscriber goes into the table because a
            // handler attached after termination is not guaranteed to run at
            // all, and never unregistering is the worse failure: this stream
            // outlives the session. The inverse window — terminating between
            // this line and the insert below — leaves one entry whose yields
            // are no-ops until the machine is released, which is bounded by the
            // one or two subscriptions a session ever takes out.
            continuation.onTermination = { [weak self] _ in
                self?.removeSubscriber(id)
            }
            lock.lock()
            subscribers[id] = continuation
            let current = storage
            // The replay, and it happens INSIDE the lock. A UI subscribes before
            // the session starts and must be able to paint the first instruction
            // without waiting for a frame — but if this yield ran after the
            // unlock, a `send` racing it could deliver the newer value first and
            // this stale replay would overwrite it, because the buffering policy
            // keeps only the newest element. Against a stream whose last value is
            // terminal that is not a stale frame of UI, it is a permanent hang:
            // the machine never publishes again, so a consumer looping until it
            // sees a terminal state waits forever.
            //
            // Safe to hold the lock across: no consumer can be attached yet (this
            // closure runs before `values` has even returned the stream), so the
            // yield is pure buffer bookkeeping with no continuation to resume and
            // no subscriber code to run re-entrantly.
            continuation.yield(current)
            lock.unlock()
        }
    }

    private func removeSubscriber(_ id: UUID) {
        lock.lock()
        subscribers.removeValue(forKey: id)
        lock.unlock()
    }

    /// Waits for the first value satisfying `predicate`, current value included.
    ///
    /// Evaluated inside the lock on every ``send(_:)``, so unlike ``values`` it
    /// cannot miss a short-lived transition such as `.capturing` — which is
    /// precisely what the session runner gates on.
    /// A cancelled wait resumes with whatever the value happens to be, because
    /// the signature has nowhere to put "cancelled" — so a caller that can be
    /// cancelled must follow this with `Task.checkCancellation()` rather than
    /// trusting that the result satisfies `predicate`. The alternative, leaving
    /// the continuation suspended, would hang the enclosing task group forever
    /// on the timeout path.
    public func first(where predicate: @Sendable @escaping (Value) -> Bool) async -> Value {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Value, Never>) in
                lock.lock()
                // `isCancelled` is tested inside the lock together with the
                // predicate: without it, a cancellation that lands between the
                // handler being installed and the waiter being registered would
                // find nothing to cancel and the continuation would never resume.
                if Task.isCancelled || predicate(storage) {
                    let current = storage
                    lock.unlock()
                    continuation.resume(returning: current)
                    return
                }
                waiters[id] = Waiter(predicate: predicate, continuation: continuation)
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            let waiter = waiters.removeValue(forKey: id)
            let current = storage
            lock.unlock()
            // Nil when `send` already claimed it; removal under the lock is what
            // makes double resumption impossible.
            waiter?.continuation.resume(returning: current)
        }
    }

    /// Publishes a new value. A no-op when it equals the current one.
    func send(_ newValue: Value) {
        lock.lock()
        guard storage != newValue else {
            // Conflation, exactly as MutableStateFlow does it. Without this the
            // UI receives thirty identical states a second while the user holds
            // a pose.
            lock.unlock()
            return
        }
        storage = newValue

        let listeners = Array(subscribers.values)
        let matched = waiters.filter { $0.value.predicate(newValue) }
        for key in matched.keys {
            waiters.removeValue(forKey: key)
        }
        lock.unlock()

        // Outside the lock: yielding runs a consumer's buffer bookkeeping and
        // resuming schedules another task, and neither may happen with the lock
        // held or a subscriber could deadlock the producer.
        for listener in listeners {
            listener.yield(newValue)
        }
        for waiter in matched.values {
            waiter.continuation.resume(returning: newValue)
        }
    }
}

#if canImport(Combine)
/// A thin, **optional** SwiftUI adapter. Not the source of truth.
///
/// It exists because SwiftUI on iOS 15 wants an `ObservableObject` and because
/// publishing to `@Published` requires the main actor: this subscribes to
/// ``StateStream/values`` and reassigns `state` on the main thread, leaving the
/// machine itself free to live on the analysis queue.
///
/// Seeded from `stream.value`, so the first instruction
/// ("Prepárate para la verificación") is painted before any frame arrives.
///
/// A host already using async/await can ignore this type entirely and write
/// `for await state in machine.state.values`.
@MainActor
public final class LivenessStateModel: ObservableObject {

    @Published public private(set) var state: LivenessState

    /// The observation task lives in a box rather than a stored property so
    /// `deinit` — which is not main-actor isolated — can cancel it without
    /// reaching into main-actor state.
    private let observation = ObservationBox()

    public init(_ stream: StateStream<LivenessState>) {
        state = stream.value
        // A `Task` started here inherits the main actor, so the assignment below
        // is already on the thread SwiftUI requires; the machine stays free to
        // run on the analysis queue.
        observation.task = Task { [weak self] in
            for await next in stream.values {
                guard let self else { return }
                self.state = next
            }
        }
    }

    /// Cancels the observation task. `deinit` does this too.
    public func stop() {
        observation.cancel()
    }

    deinit {
        observation.cancel()
    }
}

/// Nonisolated storage for one cancellable task.
private final class ObservationBox: @unchecked Sendable {

    private let lock = NSLock()
    private var stored: Task<Void, Never>?

    var task: Task<Void, Never>? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            let previous = stored
            stored = newValue
            lock.unlock()
            previous?.cancel()
        }
    }

    func cancel() {
        lock.lock()
        let current = stored
        stored = nil
        lock.unlock()
        current?.cancel()
    }
}
#endif
