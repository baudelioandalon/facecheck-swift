import CoreMedia
import Foundation
import ImageIO

/// The platform's side of a liveness session: a stream of analysed frames plus
/// the ability to take one full-resolution still.
///
/// The SDK orchestrates and the platform provides pixels. Nothing above this
/// protocol knows that a camera exists, which is what lets the whole decision
/// path (``ChallengeMachine``) be tested without a device — and it is also the
/// seam a host app takes over: an app that already runs its own camera stack
/// implements this directly instead of calling ``makeCameraController(viewController:options:)``.
public protocol CameraController: Sendable {

    /// Analysed frames, hot while the camera is running.
    ///
    /// Every access returns a **new** stream, built with `bufferingNewest(1)`:
    /// the session cares about what the face is doing *now*, and a queue of
    /// stale frames would have the machine scoring a movement the user finished
    /// a second ago. A slow consumer costs frame rate, never latency.
    ///
    /// This is also the failure channel. Every reason the camera can fail to
    /// open — permission denied, no front camera, an input the OS refuses to
    /// hand over — is discovered asynchronously, long after `start()` returned.
    /// Logging and returning would leave the session consuming a stream that
    /// never emits: the machine sits in `idle` and the user stares at black for
    /// the full session timeout before being told the verification "took too
    /// long". So the stream finishes throwing instead.
    var frames: AsyncThrowingStream<FaceFrame, any Error> { get }

    /// Take one still photo, encoded as JPEG.
    ///
    /// Called once, at the end of a successful session. The bytes go straight to
    /// the backend, so they must be a real encoded image (the backend re-decodes
    /// them) and must be the front camera's **un-mirrored** output — a mirrored
    /// selfie still matches, but it makes stored reference photos look wrong to
    /// a human reviewing them later.
    ///
    /// - Throws: ``FaceCheckError`` with ``FaceCheckErrorCode/cameraUnavailable``
    ///   when the capture fails.
    func captureStill() async throws -> Data

    /// Open the camera and start delivering ``frames``. Idempotent.
    ///
    /// Synchronous on purpose, like ``stop()``.
    nonisolated func start()

    /// Release the camera. Idempotent.
    ///
    /// The SDK calls this from a `defer`, including when a session fails, so a
    /// crashed verification never leaves the camera light on. `defer` cannot
    /// `await`, which is why this is not `async`.
    nonisolated func stop()
}

/// Capture parameters for the default platform controller.
public struct CameraOptions: Sendable, Equatable {

    /// Longest edge of the still photo, in pixels.
    public var targetStillSize: Int

    /// JPEG quality for the still, 1...100.
    public var jpegQuality: Int

    /// Front camera by default; a liveness selfie has no other sensible source.
    public var useFrontCamera: Bool

    /// Mirror the **preview** only.
    ///
    /// Users expect a mirrored preview — an unmirrored one makes them turn the
    /// wrong way and read the SDK as broken. The captured still is never
    /// mirrored, and this flag must not reach the analysis or photo connections.
    public var mirrorPreview: Bool

    /// Out-of-range values are **clamped and logged**, never fatal.
    ///
    /// This used to `precondition`, on the theory that it "traps in debug". It
    /// does not: `precondition` is live in `-O` too — `assert` is the one that
    /// compiles out — so a host passing `jpegQuality: 0` from a remote config
    /// crashed its users' phones from inside a public SDK initialiser.
    ///
    /// Throwing, the way ``LivenessConfig`` does, is not open here either: this
    /// initialiser is the default argument of
    /// ``makeCameraController(viewController:options:)``, and a default argument
    /// cannot `try`. Clamping keeps that ergonomics and still refuses to encode a
    /// still nobody can match against; the ``FaceCheckLogger/warn(_:)`` line is
    /// what makes the correction findable rather than mysterious.
    public init(
        targetStillSize: Int = 1080,
        jpegQuality: Int = 92,
        useFrontCamera: Bool = true,
        mirrorPreview: Bool = true
    ) {
        let clampedSize = max(targetStillSize, CameraOptions.minStillSize)
        if clampedSize != targetStillSize {
            FaceCheckLogger.warn(
                "targetStillSize \(targetStillSize) is below the \(CameraOptions.minStillSize) px "
                    + "floor; using \(clampedSize)"
            )
        }
        let clampedQuality = min(max(jpegQuality, 1), 100)
        if clampedQuality != jpegQuality {
            FaceCheckLogger.warn(
                "jpegQuality \(jpegQuality) is outside 1...100; using \(clampedQuality)"
            )
        }
        self.targetStillSize = clampedSize
        self.jpegQuality = clampedQuality
        self.useFrontCamera = useFrontCamera
        self.mirrorPreview = mirrorPreview
    }

    /// Below this the backend's detector has nothing left to work with.
    static let minStillSize = 480
}

/// How the camera buffer has to be rotated to be upright for the user.
///
/// The camera sensor does not rotate with the phone: unless the capture
/// connection is told otherwise, buffers arrive in the sensor's native landscape
/// regardless of how the device is held. A detector that skips this ends up
/// looking for an upright face in a sideways image and simply finds nothing,
/// which on a device looks exactly like "the camera is broken".
///
/// The raw values are the EXIF / `CGImagePropertyOrientation` codes, because
/// that is the vocabulary both Vision and ImageIO speak.
///
/// The shipped controller pins its connections to portrait and therefore always
/// passes ``up`` — AVFoundation has already done the rotation. A host driving
/// its own capture session usually cannot, and passes whatever matches its
/// connection.
public enum FrameOrientation: UInt32, Sendable, CaseIterable {

    /// Buffer is already upright.
    case up = 1

    /// Rotate 180° — upside-down portrait.
    case down = 3

    /// Rotate 90° clockwise to make it upright — the portrait case.
    case right = 6

    /// Rotate 90° counter-clockwise — landscape with the home button right.
    case left = 8

    /// The EXIF code, for APIs that want a bare number.
    public var exifValue: UInt32 { rawValue }

    /// The same orientation as Core Graphics spells it.
    ///
    /// In Kotlin/Native this conversion was the identity, because cinterop
    /// imports `CGImagePropertyOrientation` as a `UInt` typealias. In Swift it is
    /// a real enum, so this is a genuine conversion — and it stays a named
    /// property either way, since handing Vision a raw `1` and hoping it means
    /// "upright" is exactly how a pipeline ends up analysing sideways frames.
    /// The force-unwrap is safe: all four cases are valid EXIF codes.
    public var cgOrientation: CGImagePropertyOrientation {
        CGImagePropertyOrientation(rawValue: rawValue)!
    }

    /// The mirrored partner of ``cgOrientation``, per the EXIF table
    /// (1↔2, 3↔4, 6↔7, 8↔5). Only the fallback JPEG encoder needs it.
    var mirroredCGOrientation: CGImagePropertyOrientation {
        switch self {
        case .up: return .upMirrored
        case .down: return .downMirrored
        case .right: return .rightMirrored
        case .left: return .leftMirrored
        }
    }

    /// Quarter-turns clockwise needed to make the buffer upright.
    var quarterTurnsClockwise: Int {
        switch self {
        case .up: return 0
        case .right: return 1
        case .down: return 2
        case .left: return 3
        }
    }

    /// True when the upright image swaps the buffer's width and height.
    var swapsAxes: Bool { self == .right || self == .left }
}

/// The seam between the iOS capture pipeline and whatever detects faces in it.
///
/// ### Why this exists
///
/// The SDK does not link a face detector. Binding it to one ML Kit version, one
/// Firebase transitive graph and one linker configuration would stop every
/// consumer who disagrees with any of those from building at all. So it declares
/// this protocol, ships a default implementation on Apple's own Vision framework
/// (no dependency at all), and lets a host that wants ML Kit implement the same
/// protocol and inject it. Zero-dependency SPM is what makes the SDK installable.
///
/// ### Detector parity is not free
///
/// - **Eye openness.** ML Kit returns a *calibrated probability* from a trained
///   classifier. Vision returns landmark points and nothing else, so the default
///   implementation derives openness geometrically from the eye aspect ratio
///   with hand-picked constants. Any blink threshold must therefore be a
///   per-platform number and never a shared one.
/// - **Tracking identity.** ML Kit's stream mode assigns a stable tracking id.
///   `VNDetectFaceLandmarksRequest` does not track at all — every frame gets a
///   fresh UUID — so the default implementation reports a nil
///   ``FaceFrame/trackingId`` and the machine's face-swap check is inert on iOS.
///   A bridge backed by ML Kit restores it.
///
/// ### Threading
///
/// ``analyze(sampleBuffer:orientation:timestampMs:)`` is called on the capture
/// session's own serial queue, one frame at a time, never re-entrantly. It must
/// not block: the video output discards late frames, so a slow detector costs
/// frame rate rather than latency, but one that blocks for a second stalls the
/// whole session.
public protocol FaceDetectorBridge: AnyObject {

    /// Analyse one camera frame.
    ///
    /// - Parameters:
    ///   - sampleBuffer: the frame, valid **only** for the duration of this
    ///     call. The capture system reuses the underlying memory the moment this
    ///     returns; retain it yourself if you need it past the call. A
    ///     `CMSampleBuffer` rather than the bare `CVPixelBuffer` because that is
    ///     what the detectors a bridge gets written for actually want.
    ///   - orientation: how to rotate the buffer to upright. Pass it through to
    ///     the detector rather than rotating pixels yourself.
    ///   - timestampMs: the frame's own presentation timestamp in milliseconds,
    ///     monotonic. This becomes ``FaceFrame/timestampMs``, from which every
    ///     deadline in the session derives, so it must come from the buffer and
    ///     not from a wall clock.
    /// - Returns: the frame's analysis, or nil to drop this frame entirely.
    ///   Return a ``FaceFrame`` with `faceCount == 0` for "looked, found
    ///   nobody" — that is a real observation the session reacts to. Nil means
    ///   "could not look", which the session ignores.
    func analyze(
        sampleBuffer: CMSampleBuffer,
        orientation: FrameOrientation,
        timestampMs: Int64
    ) -> FaceFrame?

    /// Release per-session resources. Idempotent.
    ///
    /// Called every time the camera stops, and a controller can be started again
    /// afterwards — a user who fails a session and retries goes through exactly
    /// that path. So this must leave the bridge *usable*: drop caches and
    /// in-flight work, not the detector itself.
    func close()
}

public extension FaceDetectorBridge {
    /// Most bridges have nothing per-session to release.
    func close() {}
}
