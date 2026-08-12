import Foundation
import XCTest

@testable import FaceCheck

// MARK: - Frames

/// The production defaults, restated so tests read against a fixture rather than
/// against literals scattered through the assertions. Kotlin's `LivenessConfig()`
/// is non-throwing; the Swift initialiser validates, so the equivalent is
/// ``LivenessConfig/default``.
let testConfig = LivenessConfig.default

/// Ideal frame: one face, dead centre, well lit, sharp, filling 40% of the frame.
///
/// A test overrides exactly the field it is about, which keeps the interesting
/// value visible at the call site. Ported from the Kotlin `Frames.kt`.
func frame(
    atMs: Int64,
    yaw: Float = 0,
    pitch: Float = 0,
    roll: Float = 0,
    faceRatio: Float = 0.40,
    trackingId: Int? = 1,
    faceCount: Int = 1,
    sharpness: Float = FrameQuality.defaultSharpness,
    brightness: Float = FrameQuality.defaultBrightness,
    detectorScore: Float = FrameQuality.defaultDetectorScore
) -> FaceFrame {
    FaceFrame(
        yaw: yaw,
        pitch: pitch,
        roll: roll,
        leftEyeOpen: 0.9,
        rightEyeOpen: 0.9,
        faceRatio: faceRatio,
        trackingId: trackingId,
        timestampMs: atMs,
        quality: FrameQuality(
            sharpness: sharpness,
            brightness: brightness,
            detectorScore: detectorScore
        ),
        faceCount: faceCount
    )
}

extension ChallengeMachine {

    /// Walk the machine through positioning so a test can start at the first
    /// challenge.
    ///
    /// - Returns: the timestamp of the frame that triggered the transition.
    @discardableResult
    func completePositioning(startMs: Int64 = 0) -> Int64 {
        onFrame(frame(atMs: startMs))
        let advancedAt = startMs + testConfig.positioningHoldMs + 100
        onFrame(frame(atMs: advancedAt))
        return advancedAt
    }

    /// Perform a full turn: out past the threshold, then back to frontal.
    ///
    /// - Returns: the timestamp of the frame that completed the movement.
    @discardableResult
    func performTurn(from fromMs: Int64, yawAtExtreme: Float, trackingId: Int? = 1) -> Int64 {
        onFrame(frame(atMs: fromMs + 100, yaw: yawAtExtreme, trackingId: trackingId))
        onFrame(frame(atMs: fromMs + 200, yaw: 0, trackingId: trackingId))
        return fromMs + 200
    }
}

// MARK: - Pattern matching on LivenessState

/// Kotlin's `assertIs<LivenessState.Positioning>(…)` has no direct equivalent:
/// a Swift enum case is not a type, so there is nothing to cast to. These
/// accessors turn each case into an optional payload, which composes with
/// `XCTUnwrap` to give the same "fail here, with a message naming the state we
/// actually got" behaviour.
extension LivenessState {

    var asPositioning: (hint: PositioningHint, holdProgress: Float)? {
        guard case let .positioning(hint, holdProgress) = self else { return nil }
        return (hint, holdProgress)
    }

    var asChallengeActive: ChallengeActive? {
        guard case let .challengeActive(active) = self else { return nil }
        return active
    }

    var asFailed: FailureReason? {
        guard case let .failed(reason) = self else { return nil }
        return reason
    }

    var asDone: LivenessEvidence? {
        guard case let .done(evidence) = self else { return nil }
        return evidence
    }
}

// MARK: - Deterministic randomness

/// A reproducible `RandomNumberGenerator`, standing in for Kotlin's `Random(seed)`.
///
/// SplitMix64: three lines, no state beyond a `UInt64`, and it passes enough of
/// the usual test batteries that a plan drawn from it is not accidentally
/// structured. The point is only reproducibility — the same seed must give the
/// same plan twice — not cryptographic quality.
struct SeededGenerator: RandomNumberGenerator {

    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Log capture

/// Collects redacted log lines from a ``FaceCheckLogSink``.
///
/// A class behind a lock rather than a captured `var`: the sink closure is
/// `@Sendable`, so it cannot close over mutable local state.
final class LogCollector: @unchecked Sendable {

    private let lock = NSLock()
    private var storage: [String] = []

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ line: String) {
        lock.lock()
        storage.append(line)
        lock.unlock()
    }

    func clear() {
        lock.lock()
        storage.removeAll()
        lock.unlock()
    }
}
