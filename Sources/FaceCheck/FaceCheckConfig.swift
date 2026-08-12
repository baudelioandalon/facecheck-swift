import Foundation

/// Which universe of data a key reaches: sandbox or production.
public enum FaceCheckMode: String, Sendable, CaseIterable {

    /// `lk_test_…`. Free, metered, capped, and isolated from live subjects.
    case test = "test"

    /// `lk_live_…`. Billable, and the only mode that touches real enrollments.
    case live = "live"

    /// The literal that appears on the wire and in ``FaceCheckConfig/description``.
    ///
    /// Kept as a named property so call sites read the same as the Kotlin SDK's
    /// `mode.wire`.
    public var wire: String { rawValue }
}

/// Everything the SDK needs to talk to a FaceCheck deployment.
///
/// ### The API key is not a secret
///
/// It ships inside an app anyone can unzip. The backend is built on that
/// assumption — which is why replacing an enrollment needs a matching face
/// rather than just a valid key, and why `/verify` returns no similarity score.
/// Do not add controls here that assume the key is confidential; put them in the
/// backend, where they hold.
///
/// ### Thresholds are not here
///
/// Match thresholds live in the tenant's Firestore config and are never sent to
/// the device. A threshold on the client is a threshold the client can change.
///
/// ### Why every property is `let`
///
/// Kotlin's `copy()` re-runs the `init` block and therefore re-validates. Swift
/// has no such guarantee: `var c = config; c.challengeCount = 99` would validate
/// nothing. So the only way to build one is the throwing initialiser, and if a
/// `copy()`-like helper is ever wanted it must funnel through that same
/// initialiser and be `throws`.
///
/// Deliberately **not** `Codable`: that would serialise the API key to wherever
/// the config gets persisted.
public struct FaceCheckConfig: Sendable, Equatable, Hashable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {

    /// `lk_test_…` or `lk_live_…`, from the portal.
    public let apiKey: String

    /// Base URL of the inference deployment, with or without a trailing slash.
    public let baseUrl: String

    /// How many challenges a session asks for.
    ///
    /// Two is the default because it is the point where the session stops being
    /// defeatable by a printed photo and has not yet become long enough that
    /// real users abandon it. More challenges do not make the SDK meaningfully
    /// harder to defeat — see ``ChallengeMachine`` — they just cost completion rate.
    public let challengeCount: Int

    /// TCP connect deadline.
    ///
    /// Kept for API parity with the Android SDK, but **URLSession has no
    /// connect-phase deadline**, so this value is not applied on iOS. It is not
    /// simulated with a task race, which would only make the resource deadline
    /// unpredictable for no gain.
    public let connectTimeoutMs: Int

    /// Whole-request deadline.
    ///
    /// Generous because the backend runs MTCNN plus ArcFace on a cold instance
    /// in the worst case, and a client that gives up early still gets billed for
    /// the inference it abandoned.
    public let requestTimeoutMs: Int

    /// Socket read deadline.
    public let socketTimeoutMs: Int

    /// Retries after the first attempt, for 5xx and network errors only.
    public let maxRetries: Int

    /// First backoff step; doubles per attempt, with jitter.
    public let retryBaseDelayMs: Int

    /// Deadline for the whole on-device liveness session, all challenges included.
    public let livenessTimeoutMs: Int

    /// Per-step thresholds and deadlines for the liveness session.
    public let liveness: LivenessConfig

    /// Diagnostics. Off by default; never prints keys or image bytes.
    public let logLevel: FaceCheckLogLevel

    /// Read off the key prefix, never chosen by the caller.
    ///
    /// The backend decides mode from the key it validates, so a config field
    /// saying otherwise would only ever be a lie the SDK told itself.
    public let mode: FaceCheckMode

    /// ``baseUrl`` trimmed of whitespace and then of **all** trailing slashes,
    /// in that order, so path joins never double up.
    public let normalizedBaseUrl: String

    /// Validates in an order that is **not** cosmetic.
    ///
    /// Kotlin runs property initialisers before the `init` block, so the key
    /// prefix is checked *first*: `"sk_live_a1b2c3d4e5f6g7h8"` reports "must
    /// start with…" rather than the length message, while `"lk_test_"` (valid
    /// prefix, 8 characters) does report the length one. Swift has to reproduce
    /// that sequence by hand, and there are tests that tell the two messages apart.
    ///
    /// Every failure is ``FaceCheckError`` with ``FaceCheckErrorCode/invalidConfig``:
    /// 1. key prefix → ``mode``, else "La llave de API debe empezar con 'lk_test_' o 'lk_live_'."
    /// 2. ``normalizedBaseUrl``
    /// 3. key length >= 16 → "La llave de API está incompleta."
    /// 4. no whitespace in the key → "La llave de API contiene espacios."
    /// 5. `http://` or `https://` prefix → "baseUrl debe ser una URL http(s) completa."
    /// 6. ``FaceCheckMode/live`` over `http://` → "Una llave 'lk_live_' exige HTTPS."
    ///    Refused outright rather than warned about, because a production key
    ///    against a cleartext endpoint puts a selfie and an email on the wire in
    ///    the clear and the SDK will not get a second chance to be noticed. A
    ///    test key against `http://127.0.0.1:5001` is accepted; that is what
    ///    plain http is for.
    /// 7. `challengeCount` in 1...5 → "challengeCount debe estar entre 1 y 5."
    /// 8. connect/request/socket > 0 → "Los timeouts deben ser mayores a cero."
    /// 9. `maxRetries >= 0` → "maxRetries no puede ser negativo."
    /// 10. `retryBaseDelayMs > 0` → "retryBaseDelayMs debe ser mayor a cero."
    /// 11. `livenessTimeoutMs > 0` → "livenessTimeoutMs debe ser mayor a cero."
    public init(
        apiKey: String,
        baseUrl: String,
        challengeCount: Int = 2,
        connectTimeoutMs: Int = 15_000,
        requestTimeoutMs: Int = 60_000,
        socketTimeoutMs: Int = 60_000,
        maxRetries: Int = 2,
        retryBaseDelayMs: Int = 500,
        livenessTimeoutMs: Int = 90_000,
        liveness: LivenessConfig = .default,
        logLevel: FaceCheckLogLevel = .none
    ) throws {
        // Step 1 before step 3 is the whole point of writing this by hand: Kotlin
        // evaluates the `mode` property initialiser before the `init` block, so a
        // key with a wrong prefix reports the prefix message even when it is also
        // too short. Reordering these two checks silently changes which message a
        // developer sees, and two tests tell them apart.
        let derivedMode: FaceCheckMode
        if apiKey.hasPrefix(Self.testPrefix) {
            derivedMode = .test
        } else if apiKey.hasPrefix(Self.livePrefix) {
            derivedMode = .live
        } else {
            throw Self.invalid(
                "La llave de API debe empezar con '\(Self.testPrefix)' o '\(Self.livePrefix)'."
            )
        }

        // Whitespace first, then *every* trailing slash — in that order, so a
        // pasted `"https://host/ "` still joins cleanly.
        var normalized = baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        while normalized.hasSuffix("/") { normalized.removeLast() }

        if apiKey.count < Self.minKeyLength {
            throw Self.invalid("La llave de API está incompleta.")
        }
        // Unicode-aware, matching Kotlin's `Char.isWhitespace`: a key copied out of
        // a wrapped terminal line can carry a non-breaking space, and the request
        // would fail at the backend with a much less obvious message.
        if apiKey.contains(where: \.isWhitespace) {
            throw Self.invalid("La llave de API contiene espacios.")
        }
        if !normalized.hasPrefix("http://") && !normalized.hasPrefix("https://") {
            throw Self.invalid("baseUrl debe ser una URL http(s) completa.")
        }
        // A production key against a cleartext endpoint would put a selfie and an
        // email on the wire in the clear. Refused outright rather than warned
        // about, because the SDK will not get a second chance to be noticed.
        if derivedMode == .live && normalized.hasPrefix("http://") {
            throw Self.invalid("Una llave 'lk_live_' exige HTTPS.")
        }
        if !(ChallengePlan.minChallenges...ChallengePlan.maxChallenges).contains(challengeCount) {
            throw Self.invalid(
                "challengeCount debe estar entre \(ChallengePlan.minChallenges) y "
                    + "\(ChallengePlan.maxChallenges)."
            )
        }
        if connectTimeoutMs <= 0 || requestTimeoutMs <= 0 || socketTimeoutMs <= 0 {
            throw Self.invalid("Los timeouts deben ser mayores a cero.")
        }
        if maxRetries < 0 {
            throw Self.invalid("maxRetries no puede ser negativo.")
        }
        if retryBaseDelayMs <= 0 {
            throw Self.invalid("retryBaseDelayMs debe ser mayor a cero.")
        }
        if livenessTimeoutMs <= 0 {
            throw Self.invalid("livenessTimeoutMs debe ser mayor a cero.")
        }

        self.apiKey = apiKey
        self.baseUrl = baseUrl
        self.challengeCount = challengeCount
        self.connectTimeoutMs = connectTimeoutMs
        self.requestTimeoutMs = requestTimeoutMs
        self.socketTimeoutMs = socketTimeoutMs
        self.maxRetries = maxRetries
        self.retryBaseDelayMs = retryBaseDelayMs
        self.livenessTimeoutMs = livenessTimeoutMs
        self.liveness = liveness
        self.logLevel = logLevel
        self.mode = derivedMode
        self.normalizedBaseUrl = normalized
    }

    /// Static because an instance method is unreachable from an initialiser that
    /// has not finished assigning its stored properties yet.
    private static func invalid(_ message: String) -> FaceCheckError {
        FaceCheckError(code: .invalidConfig, message: message)
    }

    /// Absolute URL for an endpoint path.
    ///
    /// `endpoint("enroll")` and `endpoint("/verify")` produce the same shape, and
    /// a `baseUrl` with a trailing slash doubles nothing.
    func endpoint(_ path: String) -> String {
        // `drop(while:)` rather than a single `hasPrefix` strip, so `"//verify"`
        // collapses too; the backend routes on an exact path and a doubled slash
        // is a 404 that reads like a deployment problem.
        "\(normalizedBaseUrl)/\(path.drop(while: { $0 == "/" }))"
    }

    /// Redacted on purpose, in this exact shape:
    /// `FaceCheckConfig(mode=test, baseUrl=https://…, challengeCount=2, apiKey=lk_live_a1b2…)`
    /// — a 12-character prefix plus U+2026, which is the same preview the portal
    /// shows.
    ///
    /// A config lands in crash reports and bug tickets, and the default rendering
    /// would carry the API key into both.
    public var description: String {
        "FaceCheckConfig(mode=\(mode.wire), baseUrl=\(normalizedBaseUrl), "
            + "challengeCount=\(challengeCount), apiKey=\(keyPreview))"
    }

    /// The portal's own preview form: 12 characters and an ellipsis.
    private var keyPreview: String {
        "\(apiKey.prefix(Self.keyPrefixShown))…"
    }

    /// `CustomStringConvertible` alone is not enough: `String(reflecting:)`,
    /// `dump()`, `po` in the debugger and interpolating this struct inside
    /// another type's synthesised description all take different routes.
    public var debugDescription: String { description }

    /// A redacted mirror, so `dump()` and the debugger cannot reach the key either.
    public var customMirror: Mirror {
        // Exactly the four fields `description` shows, and the key only in its
        // preview form. Anything omitted here is a field `dump()` cannot reach,
        // which is the point: the timeouts are not worth a second route to the key.
        Mirror(
            self,
            children: [
                "mode": mode.wire,
                "baseUrl": normalizedBaseUrl,
                "challengeCount": challengeCount,
                "apiKey": keyPreview,
            ],
            displayStyle: .struct
        )
    }

    var connectTimeout: TimeInterval { Double(connectTimeoutMs) / 1000 }
    var requestTimeout: TimeInterval { Double(requestTimeoutMs) / 1000 }
    var socketTimeout: TimeInterval { Double(socketTimeoutMs) / 1000 }

    public static let testPrefix = "lk_test_"
    public static let livePrefix = "lk_live_"

    /// Prefix plus enough random characters to not be a placeholder.
    static let minKeyLength = 16

    /// Matches the portal's own key preview: `lk_live_a1b2…`.
    static let keyPrefixShown = 12
}
