import Foundation

/// Which stored template a verification is matched against.
///
/// This is a request, not a guarantee. The backend raises it to the strictest
/// comparison the tenant's config allows and never lowers it: a tenant with
/// `requireIneMatch` on resolves every request to ``both``, and a bare ``ine``
/// request is widened to ``both`` as well. See `effective_compare_with` in
/// `functions-python/facecheck/decision.py` — the field is attacker-chosen
/// whenever the API key is, so it may only ever add a check.
public enum CompareWith: String, Sendable, CaseIterable, Hashable {

    /// Selfie against the enrolled reference photo. The default.
    case enrollment = "enrollment"

    /// Selfie against the portrait on the enrolled ID document.
    ///
    /// Always widened to ``both`` by the backend; asking for it alone would
    /// decide the verification on the looser ID threshold by itself.
    case ine = "ine"

    /// Both the reference photo and the ID portrait must match.
    case both = "both"

    /// The literal sent in the `compareWith` multipart field.
    ///
    /// Kept as a named property so call sites read the same as the Kotlin SDK's
    /// `compareWith.wire`, and so the wire contract has one obvious home if the
    /// raw values ever have to diverge from the case names.
    public var wire: String { rawValue }

    /// Resolves a backend-supplied string, degrading to ``enrollment``.
    ///
    /// Never fails. An unrecognised, empty or absent value is not an error worth
    /// crashing a shipped app over: there is no update path for an SDK that
    /// already lives on someone's phone, so a value the backend started sending
    /// after release has to degrade rather than break the parse. This is also
    /// why ``VerifyResult`` stores the raw string and resolves through here
    /// instead of decoding straight into this enum.
    public static func fromWire(_ wire: String?) -> CompareWith {
        guard
            let raw = wire?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            let match = CompareWith(rawValue: raw)
        else {
            return .enrollment
        }
        return match
    }
}
