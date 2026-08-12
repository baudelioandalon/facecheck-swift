import Foundation

/// Thresholds and deadlines for ``ChallengeMachine``.
///
/// These are ergonomics knobs, not security parameters. Loosening them makes the
/// session easier to pass on a bad phone in bad light; tightening them does not
/// make the SDK harder to defeat, because an attacker who controls the device
/// fabricates whatever ``FaceFrame`` values he likes regardless of what is set
/// here. Tune them against real users, not against a threat model.
///
/// Defaults were picked so a person holding a phone at arm's length, indoors,
/// passes on the first try — use ``default`` to get them without a `try`.
///
/// Milliseconds stay `Int64` rather than becoming `Duration`: the integer
/// arithmetic is part of the machine's purity contract, the literals are quoted
/// in the tests and in the Android SDK's docs, and `Duration` is iOS 16.
/// `Hashable` as well as `Equatable` only because ``FaceCheckConfig`` embeds one
/// and is itself `Hashable`; the comparison stays exact `Float` equality, same
/// as Kotlin's generated `equals`.
public struct LivenessConfig: Sendable, Equatable, Hashable {

    /// Minimum face width as a fraction of frame width.
    ///
    /// 0.25 keeps the face big enough that the still photo still has a usable
    /// crop after the backend's own detector runs on it — the backend's default
    /// `minFaceDivisor` of 5 means it will not even look for a face smaller than
    /// a fifth of the frame.
    public let minFaceRatio: Float

    /// Above this the user is too close and the face gets cropped by the frame.
    public let maxFaceRatio: Float

    /// Degrees of yaw that count as "turned".
    public let turnThresholdDeg: Float

    /// Degrees of yaw/pitch inside which the head counts as frontal.
    public let centerToleranceDeg: Float

    /// Degrees of roll tolerated while positioning.
    public let maxRollDeg: Float

    /// How long a good frontal pose must hold before the first challenge starts.
    public let positioningHoldMs: Int64

    /// How long a frontal pose must hold to satisfy ``Challenge/center``.
    public let centerHoldMs: Int64

    /// Deadline for reaching a usable starting pose.
    public let positioningTimeoutMs: Int64

    /// Deadline for each individual challenge.
    public let challengeTimeoutMs: Int64

    /// Deadline for the still capture once all challenges pass.
    public let captureTimeoutMs: Int64

    /// How long the face may be missing mid-session before the session fails.
    ///
    /// Non-zero because detectors drop a frame or two on any real device, and a
    /// session that dies on a single dropped frame is unusable. Small because a
    /// long gap is exactly when a swap would happen.
    public let faceLostGraceMs: Int64

    /// Frames below this detector confidence are ignored while positioning.
    public let minDetectorScore: Float

    /// Laplacian variance below this reads as motion blur.
    public let minSharpness: Float

    /// Mean luminance bounds, 0..255, outside which the user is coached.
    public let minBrightness: Float
    public let maxBrightness: Float

    /// The tuned defaults, without forcing `try` on every call site.
    ///
    /// Built through the non-validating initialiser below. That is safe only
    /// because these literals are the values the invariants were written for; do
    /// not point it at anything a caller supplied.
    public static let `default` = LivenessConfig(
        unchecked: (),
        minFaceRatio: 0.25,
        maxFaceRatio: 0.90,
        turnThresholdDeg: 25,
        centerToleranceDeg: 10,
        maxRollDeg: 20,
        positioningHoldMs: 700,
        centerHoldMs: 600,
        positioningTimeoutMs: 20_000,
        challengeTimeoutMs: 10_000,
        captureTimeoutMs: 8_000,
        faceLostGraceMs: 1_500,
        minDetectorScore: 0.85,
        minSharpness: 25,
        minBrightness: 50,
        maxBrightness: 220
    )

    /// Validates every invariant and throws ``FaceCheckError`` with
    /// ``FaceCheckErrorCode/invalidConfig`` on the first violation.
    ///
    /// Kotlin used `require`, whose failures the tests assert on; a `precondition`
    /// here would trap and no XCTest could catch it, so these throw instead.
    ///
    /// Invariants, in order:
    /// 1. `0 < minFaceRatio < 1`
    /// 2. `minFaceRatio < maxFaceRatio <= 1`
    /// 3. `turnThresholdDeg > centerToleranceDeg` — otherwise "turned" and
    ///    "frontal" are the same pose and every challenge self-completes on the
    ///    first frame.
    /// 4. `centerToleranceDeg > 0`
    /// 5. `maxRollDeg > 0`
    /// 6. `positioningHoldMs >= 0`
    /// 7. `centerHoldMs >= 0`
    /// 8. `positioningTimeoutMs > positioningHoldMs`
    /// 9. `challengeTimeoutMs > 0`
    /// 10. `captureTimeoutMs > 0`
    /// 11. `faceLostGraceMs >= 0`
    /// 12. `minBrightness < maxBrightness`
    public init(
        minFaceRatio: Float = 0.25,
        maxFaceRatio: Float = 0.90,
        turnThresholdDeg: Float = 25,
        centerToleranceDeg: Float = 10,
        maxRollDeg: Float = 20,
        positioningHoldMs: Int64 = 700,
        centerHoldMs: Int64 = 600,
        positioningTimeoutMs: Int64 = 20_000,
        challengeTimeoutMs: Int64 = 10_000,
        captureTimeoutMs: Int64 = 8_000,
        faceLostGraceMs: Int64 = 1_500,
        minDetectorScore: Float = 0.85,
        minSharpness: Float = 25,
        minBrightness: Float = 50,
        maxBrightness: Float = 220
    ) throws {
        // The order mirrors Kotlin's `require` block one for one. It is not
        // cosmetic: a config wrong in two ways must report the same violation on
        // both platforms, or the same misconfiguration produces two different
        // support tickets.
        guard minFaceRatio > 0, minFaceRatio < 1 else {
            throw Self.invalid("minFaceRatio debe estar entre 0 y 1, era \(minFaceRatio).")
        }
        guard maxFaceRatio > minFaceRatio, maxFaceRatio <= 1 else {
            throw Self.invalid(
                "maxFaceRatio debe ser mayor que minFaceRatio (\(minFaceRatio)) y no mayor "
                    + "que 1, era \(maxFaceRatio)."
            )
        }
        guard turnThresholdDeg > centerToleranceDeg else {
            throw Self.invalid(
                "turnThresholdDeg (\(turnThresholdDeg)) debe ser mayor que centerToleranceDeg "
                    + "(\(centerToleranceDeg)); de lo contrario 'girado' y 'de frente' son la "
                    + "misma pose y cada reto se completa solo en el primer frame."
            )
        }
        guard centerToleranceDeg > 0 else {
            throw Self.invalid("centerToleranceDeg debe ser mayor a cero.")
        }
        guard maxRollDeg > 0 else {
            throw Self.invalid("maxRollDeg debe ser mayor a cero.")
        }
        guard positioningHoldMs >= 0 else {
            throw Self.invalid("positioningHoldMs no puede ser negativo.")
        }
        guard centerHoldMs >= 0 else {
            throw Self.invalid("centerHoldMs no puede ser negativo.")
        }
        guard positioningTimeoutMs > positioningHoldMs else {
            throw Self.invalid(
                "positioningTimeoutMs (\(positioningTimeoutMs)) debe ser mayor que "
                    + "positioningHoldMs (\(positioningHoldMs))."
            )
        }
        guard challengeTimeoutMs > 0 else {
            throw Self.invalid("challengeTimeoutMs debe ser mayor a cero.")
        }
        guard captureTimeoutMs > 0 else {
            throw Self.invalid("captureTimeoutMs debe ser mayor a cero.")
        }
        guard faceLostGraceMs >= 0 else {
            throw Self.invalid("faceLostGraceMs no puede ser negativo.")
        }
        guard minBrightness < maxBrightness else {
            throw Self.invalid(
                "minBrightness (\(minBrightness)) debe ser menor que maxBrightness "
                    + "(\(maxBrightness))."
            )
        }

        self.init(
            unchecked: (),
            minFaceRatio: minFaceRatio,
            maxFaceRatio: maxFaceRatio,
            turnThresholdDeg: turnThresholdDeg,
            centerToleranceDeg: centerToleranceDeg,
            maxRollDeg: maxRollDeg,
            positioningHoldMs: positioningHoldMs,
            centerHoldMs: centerHoldMs,
            positioningTimeoutMs: positioningTimeoutMs,
            challengeTimeoutMs: challengeTimeoutMs,
            captureTimeoutMs: captureTimeoutMs,
            faceLostGraceMs: faceLostGraceMs,
            minDetectorScore: minDetectorScore,
            minSharpness: minSharpness,
            minBrightness: minBrightness,
            maxBrightness: maxBrightness
        )
    }

    private static func invalid(_ message: String) -> FaceCheckError {
        FaceCheckError(code: .invalidConfig, message: message)
    }

    /// Assigns without validating. Private so ``default`` is the only user.
    private init(
        unchecked: Void,
        minFaceRatio: Float,
        maxFaceRatio: Float,
        turnThresholdDeg: Float,
        centerToleranceDeg: Float,
        maxRollDeg: Float,
        positioningHoldMs: Int64,
        centerHoldMs: Int64,
        positioningTimeoutMs: Int64,
        challengeTimeoutMs: Int64,
        captureTimeoutMs: Int64,
        faceLostGraceMs: Int64,
        minDetectorScore: Float,
        minSharpness: Float,
        minBrightness: Float,
        maxBrightness: Float
    ) {
        self.minFaceRatio = minFaceRatio
        self.maxFaceRatio = maxFaceRatio
        self.turnThresholdDeg = turnThresholdDeg
        self.centerToleranceDeg = centerToleranceDeg
        self.maxRollDeg = maxRollDeg
        self.positioningHoldMs = positioningHoldMs
        self.centerHoldMs = centerHoldMs
        self.positioningTimeoutMs = positioningTimeoutMs
        self.challengeTimeoutMs = challengeTimeoutMs
        self.captureTimeoutMs = captureTimeoutMs
        self.faceLostGraceMs = faceLostGraceMs
        self.minDetectorScore = minDetectorScore
        self.minSharpness = minSharpness
        self.minBrightness = minBrightness
        self.maxBrightness = maxBrightness
    }
}
