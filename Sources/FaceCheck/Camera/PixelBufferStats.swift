import CoreVideo
import Foundation
import Vision

/// Mean luminance and Laplacian variance over a rectangle of a luma plane.
///
/// A nil return from ``sampleLumaStats(left:top:right:bottom:luma:)`` means "not
/// enough readable pixels to say anything"; the caller reports its neutral
/// defaults rather than a number it made up. Keeping "measured zero" and "could
/// not measure" distinct is the whole reason the return type is optional.
struct LumaStats: Sendable, Equatable {

    /// Mean luminance of the sampled pixels, 0..255.
    let brightness: Float

    /// Variance of the Laplacian over the sampled pixels. Higher is sharper.
    let sharpness: Float

    /// How many pixels contributed. Exposed for tests and logging.
    let samples: Int
}

/// Constants shared by the sampler and the detector.
enum LumaSampling {

    /// Grid resolution per axis. ~2.3k samples is under a millisecond and plenty.
    static let samplesPerAxis = 48

    /// Below this many usable samples the numbers are noise; report neutral.
    static let minSamples = 16

    /// Head width as a fraction of frame width, below which a detection is dropped.
    ///
    /// Not cosmetic. ``FaceFrame/faceCount`` is counted *after* this filter, and
    /// ``ChallengeMachine`` fails the session outright with `multipleFaces` the
    /// first time it sees more than one — so skipping the filter kills sessions
    /// over a face in a poster on the far wall.
    ///
    /// Just under ``LivenessConfig/minFaceRatio`` (0.25), which leaves a narrow
    /// band where the SDK can see a face that is too small and say "acércate"
    /// instead of "no face".
    ///
    /// It is not lower than that for a measured reason. At 0.15 the detector
    /// reported transient false faces on ordinary room clutter — a whiteboard
    /// and a ceiling fan produced a steady stream of 6%-wide "faces", each with
    /// a *new* tracking id because none survived to the next frame. That is
    /// fatal rather than noisy: the machine binds to the first tracking id and
    /// fails with `faceSwapped` the moment a different one arrives, so sessions
    /// died in seconds with nobody in front of the camera.
    static let minFaceWidthRatio: Float = 0.2
}

/// The one sharpness/brightness estimator.
///
/// It is shared with the Android SDK for a reason that is not tidiness.
/// ``LivenessConfig/minSharpness`` (25) and ``FrameQuality/sharpnessReference``
/// (200) are single numbers compared against whatever the platform reports, and
/// they feed both the `lowQuality` coaching hint and 30% of the score that picks
/// the frame the SDK uploads. Two implementations of "variance of the Laplacian"
/// that disagree by a constant factor do not fail a build and do not fail a
/// test: they just mean the blur gate fires on one platform and never on the
/// other, on the same phone in the same room. So the arithmetic lives here and
/// the platform supplies nothing but a way to read a pixel.
///
/// ### Why the kernel is always at distance 1
///
/// The grid is subsampled — ``LumaSampling/samplesPerAxis`` squared points at
/// most, so cost does not grow with resolution — but the four neighbours are
/// always the *adjacent* pixels, never the next sample. Reading neighbours a
/// full step away measures a downscaled image, whose Laplacian variance grows
/// roughly with the square of the step, and reports every frame as far sharper
/// than it is. Worse, the step is derived from the face box, so the inflation
/// varies with how close the user is standing: the same face at two distances
/// would score two different sharpnesses on the same device. Subsample the
/// *centres*, never the stencil.
///
/// - Parameter luma: reads one pixel, returning 0...255, or **any negative
///   number** for a coordinate it cannot read. Called for the centre and its
///   four neighbours, so it must tolerate coordinates one pixel outside
///   `left`/`top`/`right`/`bottom`. Non-escaping, so a pointer into a locked
///   pixel buffer cannot outlive the unlock.
/// - Returns: nil when fewer than ``LumaSampling/minSamples`` pixels were readable.
func sampleLumaStats(
    left: Int,
    top: Int,
    right: Int,
    bottom: Int,
    luma: (Int, Int) -> Int
) -> LumaStats? {
    if right <= left || bottom <= top { return nil }

    let stepX = max(1, (right - left) / LumaSampling.samplesPerAxis)
    let stepY = max(1, (bottom - top) / LumaSampling.samplesPerAxis)

    var samples = 0
    var lumaSum = 0.0
    var laplacianSum = 0.0
    var laplacianSquareSum = 0.0

    var y = top
    while y < bottom {
        var x = left
        while x < right {
            let centre = luma(x, y)
            if centre >= 0 {
                // Distance 1, always — see the "why the kernel is always at
                // distance 1" note above. `stepX`/`stepY` move the centres only.
                let west = luma(x - 1, y)
                let east = luma(x + 1, y)
                let north = luma(x, y - 1)
                let south = luma(x, y + 1)
                // A point whose stencil cannot be completed is dropped whole,
                // brightness included, so both statistics describe the same set
                // of pixels.
                if west >= 0, east >= 0, north >= 0, south >= 0 {
                    let laplacian = Double(4 * centre - west - east - north - south)
                    laplacianSum += laplacian
                    laplacianSquareSum += laplacian * laplacian
                    lumaSum += Double(centre)
                    samples += 1
                }
            }
            x += stepX
        }
        y += stepY
    }

    if samples < LumaSampling.minSamples { return nil }

    // Accumulated in Double and narrowed once at the end, matching Kotlin: the
    // two platforms have to agree to the last bit a threshold can see.
    let count = Double(samples)
    let mean = laplacianSum / count
    let variance = (laplacianSquareSum / count) - (mean * mean)
    return LumaStats(
        brightness: Float(lumaSum / count),
        // Floored at zero: the one-pass variance identity can go slightly
        // negative on a perfectly flat crop, and a negative sharpness would read
        // as "blurrier than possible" to the coaching gate.
        sharpness: Float(max(0, variance)),
        samples: samples
    )
}

/// Mean luminance and Laplacian variance over the face crop.
///
/// These are the same two numbers the backend reports in ``FaceQuality``,
/// computed the same way, so a frame the SDK judged sharp and a frame the
/// backend judged sharp mean the same thing. They are measured over the *face*,
/// not the whole frame: a backlit user in a bright room has excellent frame
/// brightness and an unusable face, and telling them the light is fine is worse
/// than saying nothing.
struct PixelStats: Sendable {
    let brightness: Float
    let sharpness: Float
}

/// The image's size once `orientation` has been applied.
///
/// Vision reports every coordinate in this space, not in the buffer's, so every
/// conversion back to pixels has to start here.
func uprightSize(_ buffer: CVPixelBuffer, orientation: FrameOrientation) -> CGSize {
    let width = Double(CVPixelBufferGetWidth(buffer))
    let height = Double(CVPixelBufferGetHeight(buffer))
    return orientation.swapsAxes
        ? CGSize(width: height, height: width)
        : CGSize(width: width, height: height)
}

/// Luma statistics for the face box, or nil when the buffer cannot be read.
///
/// Works on the luma plane of a bi-planar YUV buffer when there is one — that is
/// what the shipped controller configures, and reading plane 0 is both free and
/// exactly the quantity wanted — and falls back to deriving luma from the green
/// channel of BGRA for a host that feeds something else. Green carries ~72% of
/// perceived luminance and the error is far below what a brightness threshold
/// cares about.
///
/// This function only locates and reads pixels; the arithmetic is
/// ``sampleLumaStats(left:top:right:bottom:luma:)``. Keep that split.
///
/// The crop is inset by one pixel on every side before sampling, which is what
/// keeps the stencil inside the buffer.
func pixelStats(
    _ buffer: CVPixelBuffer,
    face: VNFaceObservation,
    orientation: FrameOrientation
) -> PixelStats? {
    let width = CVPixelBufferGetWidth(buffer)
    let height = CVPixelBufferGetHeight(buffer)
    if width <= 0 || height <= 0 { return nil }

    let box = face.boundingBox
    guard let crop = bufferCrop(
        visionX: box.origin.x,
        visionY: box.origin.y,
        visionW: box.size.width,
        visionH: box.size.height,
        orientation: orientation,
        width: width,
        height: height
    ) else { return nil }

    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

    let planar = CVPixelBufferIsPlanar(buffer)
    let base = planar
        ? CVPixelBufferGetBaseAddressOfPlane(buffer, 0)
        : CVPixelBufferGetBaseAddress(buffer)
    guard let base else { return nil }
    let stride = planar
        ? CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        : CVPixelBufferGetBytesPerRow(buffer)
    if stride <= 0 { return nil }

    let bytes = base.assumingMemoryBound(to: UInt8.self)
    // Plane 0 of a bi-planar YUV buffer *is* luma, one byte per pixel: free, and
    // exactly the quantity wanted. BGRA has no luma plane, so it is approximated
    // from green (offset 1), which carries ~72% of perceived luminance — an error
    // far below what a brightness threshold cares about.
    let pixelStride = planar ? 1 : 4
    let channelOffset = planar ? 0 : 1

    // Negative for anything off the plane. `sampleLumaStats` reads one pixel past
    // the rectangle on every side, so this has to answer for out-of-range
    // coordinates rather than walking off the buffer.
    func luma(_ x: Int, _ y: Int) -> Int {
        if x < 0 || y < 0 || x >= width || y >= height { return -1 }
        return Int(bytes[y * stride + x * pixelStride + channelOffset])
    }

    // One pixel of inset so the stencil stays inside the buffer.
    guard let stats = sampleLumaStats(
        left: max(1, crop.left),
        top: max(1, crop.top),
        right: min(width - 1, crop.right),
        bottom: min(height - 1, crop.bottom),
        luma: luma
    ) else { return nil }

    return PixelStats(brightness: stats.brightness, sharpness: stats.sharpness)
}

/// A rectangle in the buffer's **own** space: unrotated, origin top-left.
struct BufferCrop: Equatable, Sendable {
    let left: Int
    let top: Int
    let right: Int
    let bottom: Int

    var width: Int { right - left }
    var height: Int { bottom - top }

    init(left: Int, top: Int, right: Int, bottom: Int) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }
}

/// Maps Vision's normalised box back to buffer pixels.
///
/// Two coordinate changes, both easy to get silently wrong:
///
/// 1. Vision's origin is **bottom-left** and its rect is normalised to the
///    *upright* image, not to the buffer.
/// 2. The buffer itself is not upright — `orientation` says how far it is
///    turned — so the rect has to be un-rotated by the same amount.
///
/// Getting either wrong yields a crop of the wrong corner of the image, which
/// produces perfectly plausible brightness and sharpness numbers for a piece of
/// wall. That failure never crashes and never looks like a bug; it just leaves
/// the coaching hints wrong for everybody. Which is why this function is pure,
/// deterministic and table-tested per orientation.
///
/// The four clamps are order-dependent: `right`'s and `bottom`'s lower bounds
/// derive from the already-clamped `left` and `top`, which is what guarantees a
/// rectangle of at least 1×1. Do not reorder them.
func bufferCrop(
    visionX: Double,
    visionY: Double,
    visionW: Double,
    visionH: Double,
    orientation: FrameOrientation,
    width: Int,
    height: Int
) -> BufferCrop? {
    if visionW <= 0 || visionH <= 0 { return nil }
    if width <= 0 || height <= 0 { return nil }
    // Kotlin's `roundToInt()` maps NaN to 0; Swift's `Int(_:)` **traps** on it,
    // which would turn a malformed observation into a dead process. Vision does
    // not emit non-finite boxes, but `visionW <= 0` does not catch NaN either
    // (every comparison against NaN is false), so the guard is explicit.
    guard visionX.isFinite, visionY.isFinite, visionW.isFinite, visionH.isFinite else {
        return nil
    }

    // Upright space, flipped to a top-left origin.
    let u0 = visionX
    let u1 = visionX + visionW
    let v0 = 1.0 - (visionY + visionH)
    let v1 = 1.0 - visionY

    // Un-rotate into buffer space. Each branch is the inverse of the rotation
    // that would make the buffer upright.
    let (bu0, bu1, bv0, bv1): (Double, Double, Double, Double)
    switch orientation {
    case .up: (bu0, bu1, bv0, bv1) = (u0, u1, v0, v1)
    case .right: (bu0, bu1, bv0, bv1) = (v0, v1, 1.0 - u1, 1.0 - u0)
    case .left: (bu0, bu1, bv0, bv1) = (1.0 - v1, 1.0 - v0, u0, u1)
    case .down: (bu0, bu1, bv0, bv1) = (1.0 - u1, 1.0 - u0, 1.0 - v1, 1.0 - v0)
    }

    // Order-dependent: `right` and `bottom` take their lower bound from the
    // already-clamped `left` and `top`, which is what guarantees a rectangle of
    // at least 1×1. Do not reorder.
    let left = pixel(bu0, of: width, atLeast: 0, atMost: width - 1)
    let right = pixel(bu1, of: width, atLeast: left + 1, atMost: width)
    let top = pixel(bv0, of: height, atLeast: 0, atMost: height - 1)
    let bottom = pixel(bv1, of: height, atLeast: top + 1, atMost: height)
    return BufferCrop(left: left, top: top, right: right, bottom: bottom)
}

/// A normalised coordinate as a pixel index, rounded and clamped in one step.
///
/// The clamp is applied in `Double` space, before the conversion, for the same
/// reason the caller guards against NaN: `Int(_:)` traps on anything outside
/// `Int`'s range, and a normalised value is only *conventionally* within 0...1 —
/// Vision reports boxes that extend past the frame edge when a face is partly
/// out of shot.
///
/// Rounding is `floor(x + 0.5)` rather than Swift's `rounded()`, which breaks
/// ties away from zero. Kotlin's `roundToInt()` breaks them towards positive
/// infinity, and this function has to agree with the Kotlin SDK on which pixel a
/// crop edge lands on.
private func pixel(_ normalised: Double, of extent: Int, atLeast: Int, atMost: Int) -> Int {
    let scaled = (normalised * Double(extent) + 0.5).rounded(.down)
    guard scaled.isFinite else { return atLeast }
    if scaled <= Double(atLeast) { return atLeast }
    if scaled >= Double(atMost) { return atMost }
    return Int(scaled)
}
