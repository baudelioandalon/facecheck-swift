import CoreMedia
import CoreVideo
import Foundation
import Vision

/// The default ``FaceDetectorBridge``: Apple's Vision, zero dependencies.
///
/// Runs one `VNDetectFaceLandmarksRequest` per frame and turns the largest
/// observation into a ``FaceFrame``.
///
/// ### Sign conventions, and why they are computed rather than assumed
///
/// ``FaceFrame`` fixes one convention for every platform: negative yaw is the
/// subject turning to **their own** left, negative pitch is chin down, negative
/// roll is a tilt towards the subject's left shoulder. If iOS disagreed with
/// Android on a single sign, the shared machine would still pass on one platform
/// and fail on the other with every threshold looking correct: the SDK would
/// tell an iOS user to turn left and then time them out for doing it. No test
/// catches that — only a device does.
///
/// Two things decide the sign:
///
/// 1. **Which way the image is mirrored.** A mirrored buffer inverts yaw and
///    roll and leaves pitch alone. That is not a constant to guess, it is a
///    property of the connection that produced the buffer — hence the
///    ``init(mirrored:)`` parameter. The shipped controller forces
///    `isVideoMirrored = false` on its analysis connection precisely so this
///    input is known rather than inferred.
/// 2. **The direction of Vision's own axes**, captured in the three sign
///    constants below. They are the only hardcoded signs in the whole pose path.
///
/// One-minute device check: set the log level to debug, run a session and turn
/// your head towards **your own** left. The logged yaw must be **negative**. If
/// it comes out positive, flip `yawSign` here — never swap ``Challenge/turnLeft``
/// and ``Challenge/turnRight``, and never widen a threshold to paper over it.
///
/// ### Eye openness is an estimate, not a probability
///
/// ML Kit gives a calibrated classifier; Vision gives points. This derives
/// openness from the eye aspect ratio and maps it linearly to 0...1 between
/// ``earClosed`` and ``earOpen``. Those two numbers are geometry, not a model,
/// and they vary with eyelid shape, glasses and camera angle far more than a
/// classifier would. The SDK does not use blink as a challenge for exactly this
/// reason, so nothing breaks if the estimate is mediocre; it exists so a host
/// can avoid capturing the still mid-blink.
///
/// Vision's `leftEye` is the eye on the left of the *image*, which in an
/// unmirrored frame is the subject's right. The pair is reported in Vision's own
/// order without trying to reconcile it with ML Kit, because nothing in the SDK
/// acts on a single eye (``FaceFrame/eyesClosed`` requires both) and a wink
/// challenge built on either detector's handedness would be a coin flip. Do not
/// add one.
///
/// `@unchecked Sendable` rests on one invariant: ``analyze(sampleBuffer:orientation:timestampMs:)``
/// is only ever called from the capture session's serial queue.
public final class VisionFaceDetector: FaceDetectorBridge, @unchecked Sendable {

    private let mirrored: Bool

    /// Reused across frames rather than rebuilt per frame. Safe **only** because
    /// analysis is serialised — reading `request.results` from two threads is a
    /// silent race.
    private let request = VNDetectFaceLandmarksRequest()

    /// - Parameter mirrored: whether the buffers this detector will see are
    ///   mirrored. Pass true when feeding frames from a front-camera connection
    ///   that has AVFoundation's default mirroring left on; the SDK's own
    ///   controller turns mirroring off and therefore passes false.
    public init(mirrored: Bool = false) {
        self.mirrored = mirrored
    }

    public func analyze(
        sampleBuffer: CMSampleBuffer,
        orientation: FrameOrientation,
        timestampMs: Int64
    ) -> FaceFrame? {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        guard let detected = detect(buffer, orientation: orientation) else { return nil }

        // Vision has no minimum-size option, so the filter ML Kit gets for free
        // from `FaceDetectorOptions.setMinFaceSize` is applied by hand — and it
        // has to happen *before* faceCount is taken. ChallengeMachine fails the
        // session immediately on faceCount > 1, so counting the unfiltered list
        // would end a session the moment a photo on the wall or somebody three
        // metres back entered frame, on iOS only.
        let observations = detected.filter {
            Float($0.boundingBox.size.width) >= LumaSampling.minFaceWidthRatio
        }

        // The machine scores one subject; when several faces are present it only
        // needs to know that, and the largest is the one the user is most likely
        // to be. Picking by area rather than by Vision's own ordering keeps the
        // choice stable frame to frame.
        guard let face = observations.max(by: { left, right in
            left.boundingBox.width * left.boundingBox.height
                < right.boundingBox.width * right.boundingBox.height
        }) else {
            // "Looked, found nobody" — a real observation the session reacts to,
            // as opposed to the nil above, which means "could not look".
            return FaceFrame(
                yaw: 0,
                pitch: 0,
                roll: 0,
                leftEyeOpen: nil,
                rightEyeOpen: nil,
                faceRatio: 0,
                trackingId: nil,
                timestampMs: timestampMs,
                faceCount: 0
            )
        }
        let angles = eulerDegrees(face)
        let eyes = eyeOpenness(face, buffer: buffer, orientation: orientation)
        let stats = pixelStats(buffer, face: face, orientation: orientation)

        return FaceFrame(
            yaw: angles.yaw,
            pitch: angles.pitch,
            roll: angles.roll,
            leftEyeOpen: eyes?.left,
            rightEyeOpen: eyes?.right,
            faceRatio: min(max(Float(face.boundingBox.size.width), 0), 1),
            // Vision's detect requests do not track: every frame produces a new
            // UUID for the same face. Reporting a synthesised id would make the
            // machine's swap check look alive while proving nothing, and
            // reporting the UUID itself would fail the session on every frame.
            // Nil is the honest answer; see FaceDetectorBridge.
            trackingId: nil,
            timestampMs: timestampMs,
            quality: FrameQuality(
                sharpness: stats?.sharpness ?? FrameQuality.defaultSharpness,
                brightness: stats?.brightness ?? FrameQuality.defaultBrightness,
                detectorScore: face.confidence
            ),
            faceCount: observations.count
        )
    }

    /// Vision holds no per-session state, but the hook is implemented explicitly.
    public func close() {}

    /// Runs the request against a fresh `VNImageRequestHandler` — required per
    /// frame — and returns the observations, or nil when Vision threw.
    private func detect(
        _ buffer: CVPixelBuffer,
        orientation: FrameOrientation
    ) -> [VNFaceObservation]? {
        // A handler is bound to one image, so it cannot be reused; the *request*
        // is, which is only safe because analysis is serialised.
        let handler = VNImageRequestHandler(
            cvPixelBuffer: buffer,
            orientation: orientation.cgOrientation,
            options: [:]
        )
        do {
            try handler.perform([request])
        } catch {
            // Warn rather than fail the session: a single dropped frame is
            // invisible to the user, and the deadlines already end a session
            // whose frames stop being usable.
            FaceCheckLogger.warn("Vision request failed: \(error.localizedDescription)")
            return nil
        }
        // Already typed in Swift; Kotlin needed `filterIsInstance` here.
        return request.results ?? []
    }

    /// Vision reports radians in optional numbers and omits what it is not
    /// confident about. A missing reading counts as zero, which is the *safe*
    /// absence rather than a lie the session believes: the machine only compares
    /// `abs(pitch)` against a tolerance, so an absent pitch degrades to "pitch is
    /// not checked" instead of blocking a user holding their head perfectly well.
    private func eulerDegrees(_ face: VNFaceObservation) -> Euler {
        let mirrorFlip: Float = mirrored ? -1 : 1
        return Euler(
            yaw: degrees(face.yaw) * Self.yawSign * mirrorFlip,
            // Mirroring does not affect pitch: it is a rotation about the
            // horizontal axis, which a horizontal flip leaves alone.
            pitch: degrees(face.pitch) * Self.pitchSign,
            // Roll is a rotation in the image plane, so mirroring reverses it
            // just as it reverses yaw.
            roll: degrees(face.roll) * Self.rollSign * mirrorFlip
        )
    }

    /// Vision's radians as degrees; an absent reading is zero. See
    /// ``eulerDegrees(_:)`` for why zero is the safe absence value.
    private func degrees(_ radians: NSNumber?) -> Float {
        guard let radians else { return 0 }
        return Float(radians.doubleValue * 180.0 / Double.pi)
    }

    /// Openness for both eyes, or nil when Vision reported no usable landmarks.
    private func eyeOpenness(
        _ face: VNFaceObservation,
        buffer: CVPixelBuffer,
        orientation: FrameOrientation
    ) -> EyePair? {
        guard let landmarks = face.landmarks,
              let left = landmarks.leftEye,
              let right = landmarks.rightEye
        else { return nil }
        let scale = faceBoxPixelSize(face, buffer: buffer, orientation: orientation)
        guard let leftEar = aspectRatio(left, scale: scale),
              let rightEar = aspectRatio(right, scale: scale)
        else { return nil }
        return EyePair(left: openness(leftEar), right: openness(rightEar))
    }

    /// Eye aspect ratio mapped linearly onto 0...1. Geometry, not a classifier —
    /// any threshold built on this number has to be calibrated per platform.
    private func openness(_ aspectRatio: Float) -> Float {
        let scaled = (aspectRatio - Self.earClosed) / (Self.earOpen - Self.earClosed)
        return min(max(scaled, 0), 1)
    }

    /// Eye aspect ratio, computed without depending on landmark point order.
    ///
    /// The textbook EAR formula indexes specific points, which requires knowing
    /// the order Vision emits them — and that order is a property of the
    /// request's *revision*, not of the API. An SDK that hardcodes it breaks on
    /// an OS update with a subtly wrong number rather than a crash. So the same
    /// quantity is derived geometrically: the **farthest-apart pair** of points
    /// is the eye's corner-to-corner axis, and the opening is how far the
    /// remaining points stray from that axis on either side. Upper and lower
    /// eyelids fall on opposite signs, so their extremes sum to the full opening.
    ///
    /// `scale` is **not** optional, and skipping it is the classic bug here: the
    /// normalised points are normalised to the *face box*, which is not square,
    /// so a ratio computed in normalised space silently tracks the box's aspect
    /// ratio instead of the eyelids'.
    ///
    /// - Returns: nil when there are fewer than ``minEyePoints`` points or the
    ///   widest distance is not positive.
    private func aspectRatio(_ region: VNFaceLandmarkRegion2D, scale: CGSize) -> Float? {
        let points = region.normalizedPoints
        if points.count < Self.minEyePoints { return nil }

        // Into pixels of the upright image. Doing this in normalised space is the
        // classic bug: the points are normalised to the face box, which is not
        // square, so the ratio would track the box's aspect, not the eyelids'.
        let xs = points.map { Float($0.x * scale.width) }
        let ys = points.map { Float($0.y * scale.height) }

        // O(n²) over at most eight points, so the brute force is free.
        var ax = 0
        var bx = 1
        var widest: Float = -1
        for i in 0..<points.count {
            for j in (i + 1)..<points.count {
                let dx = xs[i] - xs[j]
                let dy = ys[i] - ys[j]
                let distance = (dx * dx + dy * dy).squareRoot()
                if distance > widest {
                    widest = distance
                    ax = i
                    bx = j
                }
            }
        }
        if widest <= 0 { return nil }

        // Unit vector along the corner-to-corner axis, then the signed distance
        // of every point from it. Upper and lower lids land on opposite signs,
        // so their extremes sum to the full aperture.
        let ux = (xs[bx] - xs[ax]) / widest
        let uy = (ys[bx] - ys[ax]) / widest
        var above: Float = 0
        var below: Float = 0
        for i in 0..<points.count {
            let perpendicular = (xs[i] - xs[ax]) * -uy + (ys[i] - ys[ax]) * ux
            if perpendicular > above { above = perpendicular }
            if perpendicular < below { below = perpendicular }
        }
        return (above - below) / widest
    }

    /// The face box in pixels of the **upright** image, floored at 1×1.
    private func faceBoxPixelSize(
        _ face: VNFaceObservation,
        buffer: CVPixelBuffer,
        orientation: FrameOrientation
    ) -> CGSize {
        let upright = uprightSize(buffer, orientation: orientation)
        let box = face.boundingBox
        return CGSize(
            width: max(1, box.size.width * upright.width),
            height: max(1, box.size.height * upright.height)
        )
    }

    /// The only hardcoded signs in the pose path. See the type documentation.
    static let yawSign: Float = -1
    static let pitchSign: Float = 1
    static let rollSign: Float = -1

    /// Eye aspect ratio mapped linearly onto 0...1 between these two.
    static let earClosed: Float = 0.10
    static let earOpen: Float = 0.30

    /// Fewer landmark points than this and the geometry says nothing.
    static let minEyePoints = 4

    /// Named return types so the private helpers do not hand back bare tuples.
    private struct Euler {
        let yaw: Float
        let pitch: Float
        let roll: Float
    }

    private struct EyePair {
        let left: Float
        let right: Float
    }
}
