import Foundation

/// The `/enroll` response body: the subject's reference face is now stored.
///
/// Enrollment is the primitive that binds a face to an email address, so it is
/// also the primitive an attacker would use to impersonate one. Replacing an
/// existing enrollment therefore needs both an explicit `overwrite` flag and a
/// selfie that already matches the stored template — possession of the API key
/// is not by itself authority to replace someone's reference face. The backend
/// enforces that; this type only documents it.
public struct EnrollResult: Decodable, Sendable, Equatable {

    public let enrolled: Bool
    public let subjectId: String

    /// `"test"` or `"live"`, decided by the API key's prefix, not by the caller.
    public let mode: String

    /// True when this call replaced an existing reference face.
    public let overwritten: Bool

    public let faceQuality: FaceQuality?
    public let ineEnrolled: Bool
    public let ineQuality: FaceQuality?
    public let modelVersion: String?

    /// Telemetry only, and currently always nil.
    ///
    /// The available anti-spoofing model scores ~1.0 ("attack") for every input,
    /// live faces included, so the backend records it and never gates on it. Do
    /// not build a decision on this field.
    /// See <https://facecheck.borealnetwork.org/docs/umbrales>.
    public let spoofScore: Double?

    public init(
        enrolled: Bool,
        subjectId: String,
        mode: String = "",
        overwritten: Bool = false,
        faceQuality: FaceQuality? = nil,
        ineEnrolled: Bool = false,
        ineQuality: FaceQuality? = nil,
        modelVersion: String? = nil,
        spoofScore: Double? = nil
    ) {
        self.enrolled = enrolled
        self.subjectId = subjectId
        self.mode = mode
        self.overwritten = overwritten
        self.faceQuality = faceQuality
        self.ineEnrolled = ineEnrolled
        self.ineQuality = ineQuality
        self.modelVersion = modelVersion
        self.spoofScore = spoofScore
    }

    private enum CodingKeys: String, CodingKey {
        case enrolled, subjectId, mode, overwritten
        case faceQuality, ineEnrolled, ineQuality, modelVersion, spoofScore
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // `enrolled` and `subjectId` are the only genuinely required fields, and
        // they must keep throwing when absent. The network layer turns that
        // throw into `.invalidResponse`; defaulting them "for robustness" would
        // hand the caller an empty EnrollResult that reads as a success.
        enrolled = try container.decode(Bool.self, forKey: .enrolled)
        subjectId = try container.decode(String.self, forKey: .subjectId)
        mode = try container.decodeIfPresent(String.self, forKey: .mode) ?? ""
        overwritten = try container.decodeIfPresent(Bool.self, forKey: .overwritten) ?? false
        faceQuality = try container.decodeIfPresent(FaceQuality.self, forKey: .faceQuality)
        ineEnrolled = try container.decodeIfPresent(Bool.self, forKey: .ineEnrolled) ?? false
        ineQuality = try container.decodeIfPresent(FaceQuality.self, forKey: .ineQuality)
        modelVersion = try container.decodeIfPresent(String.self, forKey: .modelVersion)
        spoofScore = try container.decodeIfPresent(Double.self, forKey: .spoofScore)
    }
}
