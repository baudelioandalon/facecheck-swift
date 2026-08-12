import CoreImage
import CoreVideo
import Foundation

#if canImport(UIKit)
import UIKit

/// JPEG encoding for the still photo.
///
/// **The rule that governs this whole file: orientation is baked into the
/// pixels, never written as an EXIF tag.** The backend decodes with OpenCV, and
/// although `cv2.IMREAD_COLOR` does honour the tag, half the tools that will
/// ever touch these bytes do not — a debugging `imshow`, a hand-rolled
/// `np.frombuffer`, a reviewer opening the file in a viewer that ignores EXIF. A
/// JPEG whose pixels are already upright is correct under all of them, and the
/// only cost is a re-encode that has to happen anyway to reach
/// ``CameraOptions/targetStillSize``.
enum JPEGEncoding {

    /// The **fallback** path: encode straight from an analysis buffer.
    ///
    /// Used when `AVCapturePhotoOutput` cannot run — every simulator, and any
    /// host driving the analysis stream without a photo output. Quality is worse
    /// than a real photo capture: an analysis buffer is optimised for being
    /// discarded thirty times a second, so it is noisier and carries whatever
    /// motion smear the frame was taken with. That is why this is the fallback
    /// and not the default, even where both paths run at the same resolution.
    ///
    /// - Parameter mirrored: selects between ``FrameOrientation/cgOrientation``
    ///   and its mirrored partner. It matters for a host feeding buffers from
    ///   its own pipeline, where a mirrored front connection is *the default* and
    ///   forgetting it produces reference photos with the text on the user's
    ///   shirt reversed. The SDK turns mirroring off on its own connections and
    ///   so passes false.
    /// - Returns: nil when the image could not be rendered. The caller must
    ///   treat that as a capture failure, never as an empty upload.
    static func encode(
        pixelBuffer: CVPixelBuffer,
        orientation: FrameOrientation,
        mirrored: Bool,
        maxEdge: Int,
        quality: Int
    ) -> Data? {
        let exif = mirrored ? orientation.mirroredCGOrientation : orientation.cgOrientation
        // `oriented` rewrites the geometry rather than tagging it, which is the
        // whole point: what reaches `createCGImage` is already upright.
        let upright = CIImage(cvPixelBuffer: pixelBuffer).oriented(exif)
        guard let cgImage = context.createCGImage(upright, from: upright.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage).downscaledJpeg(maxEdge: maxEdge, quality: quality)
    }

    /// The **normal** path: re-encode `AVCapturePhoto.fileDataRepresentation()`.
    ///
    /// A photo capture is 3–5 MB, and up to 4032 px on its long edge on a
    /// session preset that allows it. The backend caps uploads at 10 MB and its
    /// detector cannot use the extra resolution (it downsamples before MTCNN
    /// anyway), so sending the original would spend the user's mobile data on
    /// pixels that get thrown away and leave the request within a factor of two
    /// of a hard rejection for no benefit. This runs even when the still is
    /// already small, because it is also what strips the EXIF rotation.
    ///
    /// Decoding through `UIImage` also normalises the EXIF rotation the photo
    /// output writes, because drawing applies `imageOrientation`: what comes out
    /// is upright pixels with no tag at all.
    static func reencode(_ data: Data, maxEdge: Int, quality: Int) -> Data? {
        UIImage(data: data)?.downscaledJpeg(maxEdge: maxEdge, quality: quality)
    }

    /// One `CIContext` for the whole SDK.
    ///
    /// Building one per frame is the classic Core Image performance trap: each
    /// instance compiles and caches its own GPU pipeline state, so a fresh
    /// context on a per-frame path costs more than everything else on that path
    /// combined. A `static let` gives lazy, thread-safe initialisation.
    static let context = CIContext()
}

private extension UIImage {

    /// Downscale to `maxEdge` on the long side and JPEG-encode.
    ///
    /// **Never upscales**: a camera returning something smaller than the target
    /// is giving all the detail that exists, and stretching it only inflates the
    /// upload.
    ///
    /// Rendered with an explicit `scale = 1`. The device default multiplies by
    /// the screen scale and silently produces an image three times larger than
    /// the one that was asked for.
    func downscaledJpeg(maxEdge: Int, quality: Int) -> Data? {
        let width = size.width
        let height = size.height
        guard width > 0, height > 0 else { return nil }

        let scale = min(CGFloat(maxEdge) / max(width, height), 1)
        let target = CGSize(
            width: max(1, (width * scale).rounded()),
            height: max(1, (height * scale).rounded())
        )

        let format = UIGraphicsImageRendererFormat.default()
        // The device default multiplies by the screen scale and would silently
        // produce an image three times larger than the one asked for.
        format.scale = 1
        // A camera frame has no transparency, and an opaque context skips the
        // alpha channel on a buffer that can reach 8 MP.
        format.opaque = true

        // `UIGraphicsImageRenderer` replaces the UIGraphicsBeginImageContext pair
        // the Kotlin SDK used, and unlike it is safe off the main thread — which
        // matters, because this runs on the capture queue.
        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            // Drawing applies `imageOrientation`, which is what normalises the
            // EXIF rotation the photo output writes into actual pixels.
            draw(in: CGRect(origin: .zero, size: target))
        }
        return rendered.jpegData(compressionQuality: CGFloat(quality) / 100)
    }
}
#endif
