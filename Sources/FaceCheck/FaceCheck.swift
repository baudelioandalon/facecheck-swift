import Foundation

/// The public entry point.
///
/// ```swift
/// try FaceCheck.initialize(
///     FaceCheckConfig(apiKey: "lk_test_…", baseUrl: "https://…")
/// )
///
/// let machine = try FaceCheck.makeChallengeMachine()   // observe machine.state in the UI
/// let result = try await FaceCheck.verify(
///     subjectId: "person_01",
///     camera: makeCameraController(viewController: host),
///     machine: machine
/// )
/// ```
///
/// ### What the SDK decides, and what it does not
///
/// It decides nothing. It coaches the user through a liveness session, captures
/// one good photo, and posts it. Whether that photo belongs to the enrolled
/// person is decided by the backend, against a threshold this code never sees.
/// A ``VerifyResult`` with `verified == true` is the backend's answer; anything
/// the on-device machine concluded on the way there is presentation.
///
/// ### Shape
///
/// A caseless `enum`, which is the exact equivalent of Kotlin's `object`: no API
/// here takes a `FaceCheck` instance, and an uninstantiable namespace cannot
/// accidentally grow one. A `final class` with `static let shared` would invite a
/// second singleton in tests.
///
/// Not an `actor`, and not `@MainActor`. An actor would make ``initialize(_:)``
/// `async`, and iOS app startup is synchronous (`@main App.init`,
/// `application(_:didFinishLaunchingWithOptions:)`), so it would have to be
/// wrapped in a `Task` — which breaks the documented "before any other call"
/// guarantee and throws the error inside a detached task where nobody sees it,
/// defeating the entire point of failing loudly on the developer's machine.
/// `@MainActor` is worse still: it would tie a UI-less SDK to the UI actor and
/// force hops to main just to read the config from the camera pipeline, which
/// runs off main by design. Since nothing inside the critical section awaits,
/// actor re-entrancy would buy nothing anyway.
///
/// ### Threading
///
/// ``initialize(_:)`` is expected once, from app startup, before any other call.
/// ``enroll(subjectId:camera:machine:grant:overwrite:ine:)`` and
/// ``verify(subjectId:camera:machine:compareWith:)`` are `nonisolated async` and safe
/// to call from any actor; each runs its own independent session, though sharing
/// one ``CameraController`` between concurrent sessions is not.
public enum FaceCheck {

    /// The configuration in force, or nil before ``initialize(_:)``.
    ///
    /// A synchronous read returning a copy by value: the caller cannot mutate
    /// the installed state.
    public static var config: FaceCheckConfig? {
        store.value?.config
    }

    public static var isInitialized: Bool {
        store.value != nil
    }

    /// Install the configuration. Idempotent for an **identical** config, and
    /// only for that one.
    ///
    /// Calling it again with a *different* config throws instead of silently
    /// re-pointing the SDK. Two configs in one process means two API keys, and
    /// therefore two tenants or two modes: whichever call happened to run last
    /// would decide whose data an enrollment landed in, and the resulting bug
    /// looks like data corruption rather than a misconfiguration. Better to fail
    /// at startup, loudly, on the developer's machine.
    ///
    /// The internal order is mandatory and matches the Kotlin SDK:
    /// compare-and-install, build the API client, set
    /// ``FaceCheckLogger/level``, and **only then** emit the
    /// "FaceCheck initialized" line. The other way round that line is filtered by
    /// the old level and never appears at all.
    ///
    /// Unlike the Kotlin original, the compare and the install happen inside one
    /// critical section. Kotlin has a latent read/write race there; Swift 6 will
    /// not let it stand, and closing it changes nothing observable for a correct
    /// caller.
    ///
    /// - Throws: ``FaceCheckError`` with ``FaceCheckErrorCode/invalidConfig`` and
    ///   the message "FaceCheck ya fue inicializado con una configuración
    ///   distinta. Llama a initialize() una sola vez, al arrancar la aplicación."
    ///   when already initialised with different settings.
    public static func initialize(_ config: FaceCheckConfig) throws {
        // Compare and install in one critical section. The client is built in
        // here too, so the idempotent path cannot leak a URLSession it would
        // immediately discard.
        let installed: FaceCheckConfig? = try store.withLock { state in
            if let current = state {
                guard current.config == config else {
                    throw FaceCheckError(
                        code: .invalidConfig,
                        message: "FaceCheck ya fue inicializado con una configuración distinta. "
                            + "Llama a initialize() una sola vez, al arrancar la aplicación."
                    )
                }
                return nil
            }
            state = State(config: config, api: FaceCheckAPIClient(config: config))
            return config
        }

        guard let installed else { return }
        // The level has to be raised before the line is emitted, or the very
        // first line the SDK ever writes is filtered by the old level and never
        // appears. Both happen outside the lock: the logger has a lock of its
        // own, and a sink is caller-supplied code that must not run under ours.
        FaceCheckLogger.level = installed.logLevel
        FaceCheckLogger.info("FaceCheck initialized: \(installed)")
    }

    /// Release the HTTP client and forget the configuration.
    ///
    /// Invalidates the API client's `URLSession` and clears the state, so a later
    /// ``initialize(_:)`` accepts a new config. Mostly for tests and for apps
    /// that tear the SDK down between user sessions.
    ///
    /// Deliberately does **not** reset ``FaceCheckLogger/level``: the Kotlin SDK
    /// does not either, and changing that would break parity.
    public static func shutdown() {
        let previous = store.withLock { state -> State? in
            defer { state = nil }
            return state
        }
        // Outside the lock: invalidating a URLSession calls into Foundation, and
        // an in-flight `enroll` already holds its own snapshot of this state.
        previous?.api.close()
    }

    /// A machine for one session, with a freshly randomised challenge plan.
    ///
    /// Built by the caller rather than internally so the UI can subscribe to
    /// ``ChallengeMachine/state`` *before* the session starts and render the very
    /// first instruction, instead of showing an empty screen until the first
    /// frame arrives.
    ///
    /// - Throws: ``FaceCheckError`` with ``FaceCheckErrorCode/notInitialized``
    ///   before ``initialize(_:)``.
    public static func makeChallengeMachine() throws -> ChallengeMachine {
        var generator = SystemRandomNumberGenerator()
        return try makeChallengeMachine(using: &generator)
    }

    /// The same, from a caller-supplied generator, so a test can pin the plan
    /// without reaching into internals.
    ///
    /// Swift's `RandomNumberGenerator` mutates, hence `inout`. This is the port
    /// of Kotlin's `random: Random = Random.Default` parameter.
    public static func makeChallengeMachine<G: RandomNumberGenerator>(
        using generator: inout G
    ) throws -> ChallengeMachine {
        let config = try requireState().config
        return try ChallengeMachine(
            challenges: ChallengePlan.random(count: config.challengeCount, using: &generator),
            config: config.liveness
        )
    }

    /// Registers a subject ID's reference face: run a liveness session, then upload.
    ///
    /// - Parameters:
    ///   - camera: supplies frames and the still; see ``CameraController``.
    ///   - machine: the session to drive; observe its state for the UI. Nil
    ///     builds one internally. It is an optional rather than a defaulted
    ///     expression because a Swift default argument cannot throw.
    ///   - grant: a short-lived token signed by the integrator's own **backend**
    ///     authorising this subject ID to be enrolled. Required for `lk_live_` keys
    ///     and optional for `lk_test_` ones, because the API key ships inside the
    ///     app and so proves nothing about who the caller is: without a grant,
    ///     anyone who extracts it could bind their face to someone else's
    ///     subject ID. **The SDK never signs anything** — it receives an
    ///     already-signed grant and forwards it, and the signing secret must
    ///     never reach the device. See
    ///     <https://facecheck.borealnetwork.org/docs/grants>.
    ///   - overwrite: replace an existing enrollment for this subject ID. Without
    ///     it an already-enrolled subject fails with
    ///     ``FaceCheckErrorCode/subjectAlreadyEnrolled`` rather than being
    ///     silently replaced. With it, the backend still demands that the new
    ///     selfie match the stored template.
    ///   - ine: an optional photo of the person's ID, JPEG-encoded, enabling
    ///     later verification against the credential portrait.
    ///
    /// Takes **one** snapshot of the installed state on entry, config and client
    /// together. That is a deliberate difference from the Kotlin SDK, which
    /// reads the config before the session and the client after it, so a
    /// concurrent `shutdown()` can throw `NOT_INITIALIZED` after the user has
    /// already completed the whole liveness test. The single snapshot stops the
    /// session being wasted.
    ///
    /// - Throws: ``FaceCheckError`` on a failed liveness session or a rejected
    ///   request.
    public static func enroll(
        subjectId: String,
        camera: any CameraController,
        machine: ChallengeMachine? = nil,
        grant: String? = nil,
        overwrite: Bool = false,
        ine: Data? = nil
    ) async throws -> EnrollResult {
        try FaceCheckSubjectId.validate(subjectId)
        let state = try requireState()
        let session = try machine ?? makeChallengeMachine()
        let capture = try await runLivenessSession(
            camera: camera,
            machine: session,
            timeoutMs: Int64(state.config.livenessTimeoutMs)
        )
        return try await state.api.enroll(
            subjectId: subjectId,
            selfie: capture.still,
            ine: ine,
            grant: grant,
            overwrite: overwrite
        )
    }

    /// Matches a fresh selfie for a subject ID against what is stored.
    ///
    /// - Parameter compareWith: which template to match. The backend may raise
    ///   this to a stricter comparison but never lowers it; see ``CompareWith``.
    ///
    /// - Throws: ``FaceCheckError`` on a failed liveness session or a rejected
    ///   request. A face that simply does not match is **not** an error: it comes
    ///   back as ``VerifyResult`` with `verified == false` and a reason.
    public static func verify(
        subjectId: String,
        camera: any CameraController,
        machine: ChallengeMachine? = nil,
        compareWith: CompareWith = .enrollment
    ) async throws -> VerifyResult {
        try FaceCheckSubjectId.validate(subjectId)
        let state = try requireState()
        let session = try machine ?? makeChallengeMachine()
        let capture = try await runLivenessSession(
            camera: camera,
            machine: session,
            timeoutMs: Int64(state.config.livenessTimeoutMs)
        )
        return try await state.api.verify(
            subjectId: subjectId,
            selfie: capture.still,
            compareWith: compareWith
        )
    }

    /// The installed state, or throws ``FaceCheckErrorCode/notInitialized``.
    private static func requireState() throws -> State {
        guard let state = store.value else {
            throw FaceCheckError(code: .notInitialized)
        }
        return state
    }

    /// Config and client packed together so a read is atomic.
    ///
    /// The Kotlin SDK keeps them in two fields, which makes a torn state
    /// (config present, client nil) observable between a `shutdown()` and an
    /// in-flight call. Bundling them removes that by construction — and requires
    /// ``FaceCheckAPIClient`` to be `Sendable`, which is a constraint the
    /// network layer must respect.
    private struct State: Sendable {
        let config: FaceCheckConfig
        let api: FaceCheckAPIClient
    }

    private static let store = LockedBox<State?>(nil)
}

/// The only place mutable global state lives in the whole SDK, shared by
/// ``FaceCheck`` and ``FaceCheckLogger``.
///
/// `@unchecked Sendable` is correct because every access to `storage` goes
/// through the lock and `Value` is already `Sendable`.
///
/// Upgrade path once the floor reaches iOS 18: replace the body with
/// `Synchronization.Mutex` without touching any public API. `Mutex` needs iOS 18
/// and `OSAllocatedUnfairLock` needs iOS 16, which is why neither is used at a
/// floor of 15.
///
/// Not exposed: this is an implementation detail, not API.
final class LockedBox<Value: Sendable>: @unchecked Sendable {

    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    /// Mutate under the lock. Do not call out to unknown code from `body` — the
    /// lock is held for its whole duration.
    func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&storage)
    }

    /// Convenience read.
    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
