import Foundation

/// The per-check breakdown inside a ``VerifyResult``.
///
/// The three optional flags are tri-state and nil is not false: nil means the
/// comparison never ran, false means it ran and did not pass. A consumer that
/// collapses nil to false shows the user a rejection the backend never issued.
public struct VerifyChecks: Decodable, Sendable, Equatable {

    /// Selfie vs. enrolled reference. Nil when the comparison did not run.
    public let faceMatch: Bool?

    /// Selfie vs. ID portrait. Nil when the comparison did not run.
    public let ineMatch: Bool?

    /// Advisory only; see ``livenessEnforced``.
    public let liveness: Bool?

    /// False in every current deployment: the spoof model cannot gate a decision.
    public let livenessEnforced: Bool

    public init(
        faceMatch: Bool? = nil,
        ineMatch: Bool? = nil,
        liveness: Bool? = nil,
        livenessEnforced: Bool = false
    ) {
        self.faceMatch = faceMatch
        self.ineMatch = ineMatch
        self.liveness = liveness
        self.livenessEnforced = livenessEnforced
    }

    private enum CodingKeys: String, CodingKey {
        case faceMatch, ineMatch, liveness, livenessEnforced
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        faceMatch = try container.decodeIfPresent(Bool.self, forKey: .faceMatch)
        ineMatch = try container.decodeIfPresent(Bool.self, forKey: .ineMatch)
        liveness = try container.decodeIfPresent(Bool.self, forKey: .liveness)
        livenessEnforced = try container
            .decodeIfPresent(Bool.self, forKey: .livenessEnforced) ?? false
    }
}

/// The `/verify` response body.
///
/// There is deliberately no similarity score here, and adding one later would be
/// a security regression rather than a feature. A score, together with the
/// threshold it is compared against, turns `/verify` into a distance oracle:
/// whoever holds the API key can optimise a face morph against the returned
/// number and climb to `verified = true` against a template they have never
/// seen — and the converged image approximately reconstructs the enrolled face.
/// The scores are still written to the tenant's dashboard, where the person
/// being probed cannot read them.
///
/// A face that simply does not match is a **result**, not an error: it arrives
/// as a `VerifyResult` with `verified == false` and a ``reason``. Throwing there
/// would force every integrator into a `do`/`catch` for the ordinary case.
public struct VerifyResult: Decodable, Sendable, Equatable {

    public let verified: Bool

    /// Machine-readable failure reason; nil when ``verified``.
    public let reason: String?

    /// Spanish prose for the failure, safe to show the user verbatim.
    public let message: String?

    /// The raw `compareWith` literal the backend sent.
    ///
    /// Stored as a string and resolved through ``compareWith`` rather than
    /// decoded straight into ``CompareWith`` for two reasons: a value added to
    /// the backend after an app shipped cannot break its parse, and the exact
    /// literal survives into logs.
    public let compareWithWire: String

    public let checks: VerifyChecks
    public let faceQuality: FaceQuality?
    public let verificationId: String

    /// Telemetry only, currently always nil. See ``EnrollResult/spoofScore``.
    public let spoofScore: Double?

    public init(
        verified: Bool,
        reason: String? = nil,
        message: String? = nil,
        compareWithWire: String = CompareWith.enrollment.rawValue,
        checks: VerifyChecks = VerifyChecks(),
        faceQuality: FaceQuality? = nil,
        verificationId: String = "",
        spoofScore: Double? = nil
    ) {
        self.verified = verified
        self.reason = reason
        self.message = message
        self.compareWithWire = compareWithWire
        self.checks = checks
        self.faceQuality = faceQuality
        self.verificationId = verificationId
        self.spoofScore = spoofScore
    }

    /// The comparison the backend actually ran, which may be stricter than requested.
    public var compareWith: CompareWith {
        CompareWith.fromWire(compareWithWire)
    }

    /// What to tell the user after a failure: the backend's own explanation when
    /// it gave one, otherwise a coaching hint derived from the image quality.
    ///
    /// Note the asymmetry with ``FaceCheckError``, which blank-checks the
    /// backend's message: here a present-but-empty `message` wins over the
    /// quality hint and this returns `""`. That is the Kotlin behaviour verbatim
    /// (`message != null`, not `isNotBlank()`). If it is a bug it has to be
    /// fixed on both sides and in the backend at once, not quietly in the port.
    public var messageEs: String? {
        if verified { return nil }
        if let message { return message }
        return faceQuality?.hintEs
    }

    /// The only key whose wire name differs from its Swift name.
    private enum CodingKeys: String, CodingKey {
        case verified, reason, message
        case compareWithWire = "compareWith"
        case checks, faceQuality, verificationId, spoofScore
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        verified = try container.decode(Bool.self, forKey: .verified)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        compareWithWire = try container
            .decodeIfPresent(String.self, forKey: .compareWithWire)
            ?? CompareWith.enrollment.rawValue
        checks = try container.decodeIfPresent(VerifyChecks.self, forKey: .checks) ?? VerifyChecks()
        faceQuality = try container.decodeIfPresent(FaceQuality.self, forKey: .faceQuality)
        verificationId = try container
            .decodeIfPresent(String.self, forKey: .verificationId) ?? ""
        spoofScore = try container.decodeIfPresent(Double.self, forKey: .spoofScore)
    }
}
