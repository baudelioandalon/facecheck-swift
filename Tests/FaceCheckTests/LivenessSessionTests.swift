import Foundation
import XCTest

@testable import FaceCheck

/// A camera that replays a scripted list of frames and hands back fixed bytes.
///
/// `@unchecked Sendable` with a lock: ``CameraController`` is `Sendable` and the
/// session runner touches this from two child tasks at once.
private final class ScriptedCamera: CameraController, @unchecked Sendable {

    private let lock = NSLock()
    private let script: [FaceFrame]
    private let still: Data
    private let failCapture: Bool
    private var counters = (started: 0, stopped: 0, captures: 0)

    init(_ script: [FaceFrame], still: Data = Data("jpeg".utf8), failCapture: Bool = false) {
        self.script = script
        self.still = still
        self.failCapture = failCapture
    }

    var started: Int { lock.lock(); defer { lock.unlock() }; return counters.started }
    var stopped: Int { lock.lock(); defer { lock.unlock() }; return counters.stopped }
    var captures: Int { lock.lock(); defer { lock.unlock() }; return counters.captures }

    var frames: AsyncThrowingStream<FaceFrame, any Error> {
        AsyncThrowingStream { continuation in
            for frame in script {
                continuation.yield(frame)
            }
            continuation.finish()
        }
    }

    func captureStill() async throws -> Data {
        // Counted in a synchronous helper: taking an `NSLock` inside an `async`
        // function is an error in the Swift 6 language mode.
        countCapture()
        if failCapture {
            throw FaceCheckError(code: .cameraUnavailable, message: "sin cámara")
        }
        return still
    }

    private func countCapture() {
        lock.lock()
        counters.captures += 1
        lock.unlock()
    }

    func start() {
        lock.lock()
        counters.started += 1
        lock.unlock()
    }

    func stop() {
        lock.lock()
        counters.stopped += 1
        lock.unlock()
    }
}

private func happyScript() -> [FaceFrame] {
    [
        frame(atMs: 0),
        frame(atMs: 800),
        frame(atMs: 900, yaw: -35),
        frame(atMs: 1_000, yaw: 0),
    ]
}

/// Port of the Kotlin `LivenessSessionTest`.
///
/// Kotlin's `runTest` gives a virtual clock; Swift has no equivalent, which is
/// why ``runLivenessSession(camera:machine:timeoutMs:sleeper:)`` takes an
/// injectable ``Sleeping``. The timeout case installs one that returns
/// immediately, so a 90-second deadline is exercised in microseconds.
final class LivenessSessionTests: XCTestCase {

    /// Fires the deadline as soon as the race starts. The body still only loses
    /// if it has nothing to report, which is exactly what the timeout case sets up.
    private struct InstantSleeper: Sleeping {
        func sleep(milliseconds: Int64) async throws {}
    }

    func testASuccessfulSessionCapturesAStillAndReleasesTheCamera() async throws {
        let camera = ScriptedCamera(happyScript())
        let machine = try ChallengeMachine(challenges: [.turnLeft], config: testConfig)

        let capture = try await runLivenessSession(
            camera: camera,
            machine: machine,
            timeoutMs: 60_000
        )

        XCTAssertEqual(String(decoding: capture.still, as: UTF8.self), "jpeg")
        XCTAssertEqual(capture.evidence.challenges.count, 1)
        XCTAssertEqual(camera.started, 1)
        XCTAssertEqual(camera.captures, 1)
        XCTAssertEqual(camera.stopped, 1)
        XCTAssertNotNil(machine.state.value.asDone)
    }

    func testAFailedSessionStillReleasesTheCamera() async throws {
        // A verification that throws must not leave the camera light on; users
        // read that as the app spying on them, and they are not wrong to.
        let camera = ScriptedCamera([
            frame(atMs: 0),
            frame(atMs: 800),
            frame(atMs: 900, trackingId: 42),
        ])
        let machine = try ChallengeMachine(challenges: [.turnLeft], config: testConfig)

        let failure = await assertThrowsFaceCheckError(code: .livenessFailed) {
            try await runLivenessSession(camera: camera, machine: machine, timeoutMs: 60_000)
        }

        XCTAssertEqual(failure?.message, "Detectamos un cambio de persona. Vuelve a empezar.")
        XCTAssertEqual(camera.captures, 0, "no photo should be taken for a failed session")
        XCTAssertEqual(camera.stopped, 1)
    }

    func testACameraThatNeverDeliversAUsableFrameTimesOut() async throws {
        let camera = ScriptedCamera([frame(atMs: 0, faceCount: 0)])
        let machine = try ChallengeMachine(challenges: [.turnLeft], config: testConfig)

        let failure = await assertThrowsFaceCheckError(code: .timeout) {
            try await runLivenessSession(
                camera: camera,
                machine: machine,
                timeoutMs: 200,
                sleeper: InstantSleeper()
            )
        }

        XCTAssertEqual(failure?.message, "La verificación tardó demasiado. Vuelve a intentarlo.")
        XCTAssertEqual(camera.stopped, 1)
        // The machine is cancelled on the way out, so a UI bound to its state
        // stops showing a live instruction for a session that is over.
        XCTAssertNotNil(machine.state.value.asFailed)
    }

    func testACaptureFailurePropagatesAndStillStopsTheCamera() async throws {
        let camera = ScriptedCamera(happyScript(), failCapture: true)
        let machine = try ChallengeMachine(challenges: [.turnLeft], config: testConfig)

        await assertThrowsFaceCheckError(code: .cameraUnavailable) {
            try await runLivenessSession(camera: camera, machine: machine, timeoutMs: 60_000)
        }

        XCTAssertEqual(camera.stopped, 1)
    }

    func testASessionCancelledByTheUserIsNotReportedAsALivenessFailure() async throws {
        // Showing "no pudimos verificarte" to someone who pressed back is wrong.
        let machine = try ChallengeMachine(challenges: [.turnLeft], config: testConfig)
        machine.onFrame(frame(atMs: 0))
        machine.cancel()

        // The session already failed before the runner subscribes, so this only
        // passes because `StateStream` replays its current value.
        let camera = ScriptedCamera([])
        await assertThrowsFaceCheckError(code: .cancelled) {
            try await runLivenessSession(camera: camera, machine: machine, timeoutMs: 60_000)
        }
    }

    /// The frame pump is deliberately still running while the still is taken, so
    /// the session can fail *during* `captureStill()` — the user lowers the
    /// phone at the sound of the shutter. What must not come out of that is
    /// `INVALID_CONFIG` plus a sentence addressed to the SDK's integrator.
    func testASessionThatFailsDuringTheCaptureReportsTheRealReason() async throws {
        /// Fails the machine from inside `captureStill()`, which is exactly the
        /// window the runner leaves open.
        final class CameraThatLosesTheFaceMidCapture: CameraController, @unchecked Sendable {
            let machine: ChallengeMachine
            let lostAtMs: Int64

            init(machine: ChallengeMachine, lostAtMs: Int64) {
                self.machine = machine
                self.lostAtMs = lostAtMs
            }

            var frames: AsyncThrowingStream<FaceFrame, any Error> {
                AsyncThrowingStream { continuation in
                    for frame in happyScript() { continuation.yield(frame) }
                    continuation.finish()
                }
            }

            func captureStill() async throws -> Data {
                machine.onFrame(frame(atMs: lostAtMs, faceCount: 0))
                return Data("jpeg".utf8)
            }

            func start() {}
            func stop() {}
        }

        let machine = try ChallengeMachine(challenges: [.turnLeft], config: testConfig)
        let camera = CameraThatLosesTheFaceMidCapture(
            machine: machine,
            lostAtMs: 1_000 + testConfig.faceLostGraceMs + 1
        )

        let failure = await assertThrowsFaceCheckError(code: .livenessFailed) {
            try await runLivenessSession(camera: camera, machine: machine, timeoutMs: 60_000)
        }

        XCTAssertEqual(
            failure?.message,
            "Perdimos tu rostro. Mantente dentro del marco e intenta de nuevo."
        )
    }

    /// The stream is the camera's failure channel: permission denied and "no
    /// front camera" are discovered long after `start()` returned. Swallowing
    /// that would leave the user staring at black until the global deadline.
    func testAFailingFrameStreamSurfacesInsteadOfHangingTheSession() async throws {
        struct BrokenCamera: CameraController {
            var frames: AsyncThrowingStream<FaceFrame, any Error> {
                AsyncThrowingStream { $0.finish(throwing: FaceCheckError(code: .cameraUnavailable)) }
            }
            func captureStill() async throws -> Data { Data() }
            func start() {}
            func stop() {}
        }

        let machine = try ChallengeMachine(challenges: [.turnLeft], config: testConfig)
        await assertThrowsFaceCheckError(code: .cameraUnavailable) {
            try await runLivenessSession(
                camera: BrokenCamera(),
                machine: machine,
                timeoutMs: 60_000
            )
        }
    }
}
