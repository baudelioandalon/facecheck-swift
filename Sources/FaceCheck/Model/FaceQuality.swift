import Foundation

/// Quality signals the backend computed on the image it actually processed.
///
/// These describe the caller's own photo and say nothing about the enrolled
/// subject, which is why the backend still returns them while it withholds match
/// scores. Their whole purpose is coaching a retry: see ``hintEs``.
///
/// Mirrors `FaceQuality` in `functions-python/facecheck/engine.py`. Every field
/// is defaulted so a backend that starts reporting one more signal does not
/// break apps compiled against this version — which in Swift is not free, and is
/// why ``init(from:)`` is written by hand: the synthesised `Decodable` ignores
/// property defaults and throws `keyNotFound` for anything the backend omits.
public struct FaceQuality: Codable, Sendable, Equatable, Hashable {

    public let imageWidth: Int
    public let imageHeight: Int
    public let faceWidth: Int
    public let faceHeight: Int

    /// Face width as a fraction of image width. Below ~0.20 the crop is starved.
    public let faceRatio: Float

    /// MTCNN's confidence for the detected box, 0..1.
    public let detectorScore: Float

    /// Variance of the Laplacian on the aligned crop. Higher is sharper.
    public let sharpness: Float

    /// Mean luminance of the aligned crop, 0..255.
    public let brightness: Float

    /// Whether the five-landmark alignment succeeded.
    public let aligned: Bool

    public init(
        imageWidth: Int = 0,
        imageHeight: Int = 0,
        faceWidth: Int = 0,
        faceHeight: Int = 0,
        faceRatio: Float = 0,
        detectorScore: Float = 0,
        sharpness: Float = 0,
        brightness: Float = 0,
        aligned: Bool = false
    ) {
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.faceWidth = faceWidth
        self.faceHeight = faceHeight
        self.faceRatio = faceRatio
        self.detectorScore = detectorScore
        self.sharpness = sharpness
        self.brightness = brightness
        self.aligned = aligned
    }

    /// The one thing to tell the user before they retry, or nil when nothing
    /// about the image stands out as the reason a match failed.
    ///
    /// Ordered by how much each defect actually costs the embedding: a face too
    /// small to crop cleanly beats a blurry one, which beats a dark one.
    ///
    /// The `> 0` guards separate "not reported" from "bad". A `faceRatio` of 0
    /// means the backend sent no such signal, and coaching someone to move
    /// closer on the strength of a missing measurement is worse than saying
    /// nothing. Rule four needs no guard because 0 is never above 215.
    public var hintEs: String? {
        if faceRatio > 0 && faceRatio < Threshold.lowFaceRatio {
            return "Acércate más a la cámara: tu rostro se ve muy pequeño."
        }
        if sharpness > 0 && sharpness < Threshold.lowSharpness {
            return "La foto salió borrosa. Sostén el teléfono firme y vuelve a intentar."
        }
        if brightness > 0 && brightness < Threshold.lowBrightness {
            return "Hay poca luz. Colócate frente a una fuente de luz."
        }
        if brightness > Threshold.highBrightness {
            return "Hay demasiada luz de fondo. Evita ventanas o lámparas detrás de ti."
        }
        if !aligned {
            return "No se pudo alinear tu rostro. Mira de frente a la cámara."
        }
        return nil
    }

    /// Kept as `Float` rather than widened to `Double` on purpose: the
    /// thresholds are `Float` literals, and widening moves the comparisons at
    /// the boundary where the coaching hints actually flip.
    private enum Threshold {
        static let lowFaceRatio: Float = 0.20
        static let lowSharpness: Float = 40
        static let lowBrightness: Float = 55
        static let highBrightness: Float = 215
    }

    private enum CodingKeys: String, CodingKey {
        case imageWidth, imageHeight, faceWidth, faceHeight
        case faceRatio, detectorScore, sharpness, brightness, aligned
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // decodeIfPresent returns nil for both an absent key and an explicit
        // JSON null, which is exactly kotlinx.serialization's `explicitNulls = false`.
        imageWidth = try container.decodeIfPresent(Int.self, forKey: .imageWidth) ?? 0
        imageHeight = try container.decodeIfPresent(Int.self, forKey: .imageHeight) ?? 0
        faceWidth = try container.decodeIfPresent(Int.self, forKey: .faceWidth) ?? 0
        faceHeight = try container.decodeIfPresent(Int.self, forKey: .faceHeight) ?? 0
        faceRatio = try container.decodeIfPresent(Float.self, forKey: .faceRatio) ?? 0
        detectorScore = try container.decodeIfPresent(Float.self, forKey: .detectorScore) ?? 0
        sharpness = try container.decodeIfPresent(Float.self, forKey: .sharpness) ?? 0
        brightness = try container.decodeIfPresent(Float.self, forKey: .brightness) ?? 0
        aligned = try container.decodeIfPresent(Bool.self, forKey: .aligned) ?? false
    }
}
