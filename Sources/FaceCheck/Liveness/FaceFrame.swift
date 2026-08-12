import Foundation

/// Cheap image-quality signals for one frame.
///
/// The units match what the backend reports in ``FaceQuality`` so a platform can
/// compute them the same way on both sides and the numbers stay comparable.
public struct FrameQuality: Sendable, Equatable {

    /// Variance of the Laplacian over the face crop. Higher is sharper.
    public var sharpness: Float

    /// Mean luminance of the face crop, 0..255.
    public var brightness: Float

    /// Detector confidence for the box, 0..1.
    public var detectorScore: Float

    public init(
        sharpness: Float = FrameQuality.defaultSharpness,
        brightness: Float = FrameQuality.defaultBrightness,
        detectorScore: Float = FrameQuality.defaultDetectorScore
    ) {
        self.sharpness = sharpness
        self.brightness = brightness
        self.detectorScore = detectorScore
    }

    /// Reported when the platform could not measure, as opposed to measured zero.
    public static let defaultSharpness: Float = 120
    public static let defaultBrightness: Float = 128
    public static let defaultDetectorScore: Float = 0.99

    /// Sharpness treated as "as good as it needs to be" when scoring frames
    /// against each other. Laplacian variance is unbounded, so without a
    /// ceiling one specular highlight would outrank a well-framed face.
    public static let sharpnessReference: Float = 200
}

/// One analysed camera frame, as the platform's face detector saw it.
///
/// This is the entire contract between the platform layer (AVFoundation plus
/// Vision on iOS) and ``ChallengeMachine``. Everything the machine decides is a
/// function of these values and nothing else, which is what makes the machine
/// testable without a camera.
///
/// ### Sign conventions
///
/// All angles are degrees, from the subject's own point of view, as if you were
/// standing in their shoes rather than looking at them:
///
/// - ``yaw`` negative = head turned to the subject's **left**, positive = right.
/// - ``pitch`` negative = chin down, positive = chin up.
/// - ``roll`` negative = head tilted towards the subject's left shoulder.
///
/// Vision's `yaw` already uses this convention for a front camera; a platform
/// that disagrees must flip the sign **before** constructing a frame, never
/// inside the machine.
public struct FaceFrame: Sendable, Equatable {

    /// Head rotation left/right, degrees. Negative is the subject's left.
    public var yaw: Float

    /// Head rotation up/down, degrees. Negative is chin down.
    public var pitch: Float

    /// Head tilt, degrees. Negative leans towards the subject's left shoulder.
    public var roll: Float

    /// Eye-open probability 0..1, or nil when the detector does not report it.
    public var leftEyeOpen: Float?

    /// Eye-open probability 0..1, or nil when the detector does not report it.
    public var rightEyeOpen: Float?

    /// Face bounding-box width as a fraction of frame width, 0..1.
    public var faceRatio: Float

    /// The detector's tracking identity for this face.
    ///
    /// Stable for as long as the detector believes it is following the same
    /// face, and this is the only continuity signal the machine has: a change
    /// mid-session means the thing being tracked was swapped out. Nil when the
    /// platform runs in single-image mode, in which case the swap check cannot
    /// run at all — which is the case for the shipped Vision detector, since
    /// `VNDetectFaceLandmarksRequest` does not track.
    public var trackingId: Int?

    /// Monotonic milliseconds from the frame's own timestamp.
    ///
    /// The machine derives every deadline from this rather than from a clock, so
    /// a test drives ten seconds of session in microseconds and a slow device
    /// measures elapsed time in frames it actually saw.
    public var timestampMs: Int64

    /// Per-frame image quality; see ``FrameQuality``.
    public var quality: FrameQuality

    /// How many faces the detector found in this frame.
    ///
    /// Zero means the face was lost, which is legal for a moment and fatal if it
    /// persists; more than one is fatal immediately, because with two faces in
    /// frame there is no longer a single subject whose challenges are being
    /// scored. The other fields describe the largest face when this is >= 1 and
    /// are meaningless when it is 0.
    public var faceCount: Int

    public init(
        yaw: Float,
        pitch: Float,
        roll: Float,
        leftEyeOpen: Float?,
        rightEyeOpen: Float?,
        faceRatio: Float,
        trackingId: Int?,
        timestampMs: Int64,
        quality: FrameQuality = FrameQuality(),
        faceCount: Int = 1
    ) {
        self.yaw = yaw
        self.pitch = pitch
        self.roll = roll
        self.leftEyeOpen = leftEyeOpen
        self.rightEyeOpen = rightEyeOpen
        self.faceRatio = faceRatio
        self.trackingId = trackingId
        self.timestampMs = timestampMs
        self.quality = quality
        self.faceCount = faceCount
    }

    /// True when exactly one face is present, i.e. the frame is scorable at all.
    public var hasSingleFace: Bool { faceCount == 1 }

    /// Whether both eyes read as closed.
    ///
    /// Not used as a challenge — a blink is trivially replayed and asking a user
    /// to blink on cue fails often enough to be a support cost — but exposed so
    /// a host app can avoid capturing a still on a blink. A missing reading from
    /// either eye yields false rather than a guess.
    public var eyesClosed: Bool {
        guard let left = leftEyeOpen, let right = rightEyeOpen else { return false }
        return left < Self.eyesClosedThreshold && right < Self.eyesClosedThreshold
    }

    private static let eyesClosedThreshold: Float = 0.25
}
