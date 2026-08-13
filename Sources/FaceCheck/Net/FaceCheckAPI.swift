import Foundation

// MARK: - Transport seam

/// The test seam, and the one-to-one equivalent of the `HttpClientEngine` the
/// Kotlin SDK injects so its tests can use `MockEngine`.
///
/// A bespoke protocol rather than `URLProtocol`: `URLProtocol` is a global
/// registry, it forces the body to be read back out of `request.httpBodyStream`
/// (URLSession has already turned `httpBody` into a stream by the time a
/// `URLProtocol` sees it, and with `upload(for:from:)` the body is not in
/// `httpBody` at all), and it offers no way to assert on the exact bytes that
/// went out. Four Kotlin tests assert on the real multipart body; this makes
/// that trivial.
///
/// The body travels as a separate parameter rather than inside the `URLRequest`
/// for exactly that reason.
protocol HTTPTransport: Sendable {

    /// Returns `HTTPURLResponse` rather than `URLResponse` so the cast — and its
    /// failure — lives in the one place that knows about URLSession.
    func send(_ request: URLRequest, body: Data) async throws -> (Data, HTTPURLResponse)

    func close()
}

/// The real transport.
///
/// Session configuration, and why each line is there:
///
/// - `.ephemeral`, not `.default`: a biometric SDK must not leave a cache,
///   cookies or credentials on disk. That is the correct default here, not an
///   optimisation.
/// - `timeoutIntervalForRequest` ← `socketTimeoutMs` (inactivity).
/// - `timeoutIntervalForResource` ← `requestTimeoutMs` (whole-operation deadline).
/// - `connectTimeoutMs` **cannot be expressed**: URLSession has no connect-phase
///   deadline. It is documented and not faked with a task race, which would only
///   make the resource deadline unpredictable.
/// - `waitsForConnectivity = false`: with no network we want
///   `URLError.notConnectedToInternet` immediately, not a silent wait until the
///   resource timeout.
/// - `httpShouldSetCookies = false` and `httpCookieAcceptPolicy = .never`: the
///   API authenticates by header, and a proxy's `Set-Cookie` could only pollute
///   the shared jar.
/// - `requestCachePolicy = .reloadIgnoringLocalCacheData`, `urlCache = nil`: a
///   `/verify` response must never be served from cache, and a body derived from
///   a selfie must not touch the disk.
///
/// Timeouts are **per attempt**, like Ktor's `HttpTimeout`. With the defaults
/// (60 s, 2 retries) the worst case for one call is on the order of three
/// minutes.
final class URLSessionTransport: HTTPTransport, Sendable {

    private let session: URLSession
    private let redirectBlocker: RedirectBlocker

    init(config: FaceCheckConfig) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = config.socketTimeout
        configuration.timeoutIntervalForResource = config.requestTimeout
        configuration.waitsForConnectivity = false
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        // `config.connectTimeoutMs` has no home here on purpose; see the type's
        // doc comment.
        session = URLSession(configuration: configuration)
        redirectBlocker = RedirectBlocker()
    }

    /// Uses `upload(for:from:delegate:)`, never `data(for:)`, and leaves
    /// `httpBody` nil.
    ///
    /// Does **not** interpret the status: statuses are the SDK's business (a 404
    /// from `/verify` is `NOT_ENROLLED`, a result the caller handles rather than
    /// a crash). This is Ktor's `expectSuccess = false`.
    func send(_ request: URLRequest, body: Data) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.upload(
            for: request,
            from: body,
            delegate: redirectBlocker
        )
        guard let http = response as? HTTPURLResponse else {
            // Unreachable over http(s), but the cast has to exist somewhere and
            // this is the only file that knows URLSession at all.
            throw FaceCheckError(code: .invalidResponse)
        }
        return (data, http)
    }

    /// `finishTasksAndInvalidate()`. A hand-made `URLSession` that is never
    /// invalidated leaks, and once invalidated it cannot be reused — which is
    /// exactly the semantics ``FaceCheck/shutdown()`` wants.
    func close() {
        session.finishTasksAndInvalidate()
    }
}

/// Turns off automatic redirect following by returning nil.
///
/// Necessary, not cosmetic. URLSession follows 3xx on its own and, on 301/302/303,
/// converts the POST to a GET and throws the body away — so a redirected
/// `/enroll` would reach the backend as a GET and come back as a
/// `405 METHOD_NOT_ALLOWED` that is impossible to diagnose from the app. Ktor
/// does not have the problem because its redirect plugin only follows GET and HEAD.
///
/// Passed as a **per-task** delegate (the `delegate:` parameter of
/// `upload(for:from:delegate:)`, available since iOS 15) rather than as the
/// session delegate, to avoid the classic URLSession/delegate retain cycle.
///
/// With redirects unfollowed a 3xx is neither 2xx nor >= 500, so it surfaces as
/// ``FaceCheckErrorCode/unknown`` with its real `httpStatus` and no retry. That
/// is honest: the SDK cannot know whether the new destination is legitimate.
final class RedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

// MARK: - Error envelope

/// The backend's `{"error":{"code","message","details"}}` envelope.
struct ErrorEnvelope: Decodable, Sendable {
    let error: ErrorPayload?
}

struct ErrorPayload: Decodable, Sendable {
    let code: String?
    let message: String?
    let details: [String: JSONValue]?
}

/// One JSON value from `details`, decoded without going through `NSNumber`.
///
/// `JSONSerialization` is not used here for a concrete reason: it hands back
/// `NSNumber`, and interpolating the `NSNumber` for a JSON `false` yields `"0"`,
/// not `"false"`. That is a silent, real bug. This enum avoids it by construction.
///
/// **The decode order matters: `Int64` before `Double`.** Otherwise
/// `retryAfterSeconds: 42` renders as `"42.0"`, `Int("42.0")` is nil, and
/// ``FaceCheckError/retryAfterSeconds`` silently returns nil — the caller loses
/// the backoff hint on a 429 and nobody notices.
///
/// ``array`` and ``object`` decode as payload-free markers: they are never read,
/// and exist only so decoding does not fail and throw away the whole envelope
/// over a field that was going to be discarded anyway.
enum JSONValue: Decodable, Sendable {
    case string(String)
    case integer(Int64)
    case number(Double)
    case bool(Bool)
    case null
    case array
    case object

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if (try? container.decode([JSONValue].self)) != nil {
            self = .array
        } else if (try? container.decode([String: JSONValue].self)) != nil {
            self = .object
        } else {
            self = .null
        }
    }

    /// The Kotlin `JsonPrimitive.content` rule: primitives keep their literal
    /// token, nulls and nested structures are dropped.
    var plainString: String? {
        switch self {
        case let .string(value): return value
        case let .integer(value): return String(value)
        case let .number(value): return String(value)
        case let .bool(value): return value ? "true" : "false"
        case .null, .array, .object: return nil
        }
    }

    /// Flattens `details` to `[String: String]`, discarding whatever has no
    /// plain representation.
    static func flattened(_ raw: [String: JSONValue]?) -> [String: String] {
        guard let raw else { return [:] }
        return raw.compactMapValues(\.plainString)
    }
}

/// A `Sendable` wrapper for the decoding failure stored as a
/// ``FaceCheckError``'s `underlying`.
///
/// It exists for a concrete Swift 6 reason: `DecodingError` is **not** Sendable,
/// because its `Context` carries an `underlyingError: any Error`. The diagnostic
/// is rendered to text once, at the boundary where it is caught, and that text is
/// what reaches the log and the support ticket. It is diagnostic information, not
/// control flow: nobody branches on it.
struct ResponseDecodingFailure: Error, Sendable, CustomStringConvertible {

    let description: String

    init(_ error: any Error) {
        description = String(describing: error)
    }
}

// MARK: - Client

/// The HTTP client for `/enroll` and `/verify`.
///
/// One retry loop shared by both endpoints; the whole policy lives there.
///
/// ### What is retried, and what never is
///
/// Retried: transport failures, and responses with status >= 500.
///
/// **Never retried: any 4xx.** This is the heart of the class. `/verify` bills
/// the tenant and adds to the subject's lockout streak on *every* attempt
/// (`store.register_failed_attempt`), so retrying a 403 would burn three of a
/// user's five permitted failures on one tap and lock them out of their own
/// account. Also never retried: a 2xx with an undecodable body (the work was
/// done and billed already, even though ``FaceCheckErrorCode/invalidResponse``
/// reports itself retryable), a cancelled task, and 3xx.
///
/// ### Error mapping
///
/// There is **no HTTP-status-to-code table.** The code always comes from the
/// body. The status decides only two things: success (`200..<300`) or not, and
/// retryability (`>= 500`).
///
/// Transport failures map off `URLError.Code` exactly. The Kotlin SDK had to
/// guess from the *name* of the exception class (`name.contains("Timeout")`)
/// because Ktor puts its timeout types in platform source sets that common code
/// cannot name. That heuristic is gone, and this is the one place the port is
/// genuinely better than the original.
///
/// ### Accepted trade, inherited from Kotlin
///
/// Retrying a transport failure assumes the request may not have been processed.
/// If the server did process it and the response was lost, the retry bills again
/// and counts again against the subject's lockout streak. The narrow rule (5xx
/// and network errors, never 4xx) bounds the damage without eliminating it;
/// eliminating it would need a per-attempt idempotency key the backend does not
/// accept today.
///
/// `Sendable` without being an actor: there is no mutable state (everything is
/// `let`, and `URLSession` is thread-safe). An actor would serialise concurrent
/// requests for no reason.
final class FaceCheckAPIClient: Sendable {

    let config: FaceCheckConfig
    let transport: any HTTPTransport
    let boundaryFactory: @Sendable () -> String
    let jitter: @Sendable (ClosedRange<Int64>) -> Int64
    let sleep: @Sendable (_ milliseconds: Int64) async throws -> Void

    /// - Parameters:
    ///   - transport: nil selects ``URLSessionTransport``. It is not a default
    ///     argument expression because Swift will not let one refer to an
    ///     earlier parameter, and this one needs `config`.
    ///   - jitter: returns an already-drawn value rather than taking a
    ///     `RandomNumberGenerator`, whose `mutating` methods are mutable state
    ///     and would fight strict concurrency inside a Sendable type. Tests pass
    ///     `{ $0.lowerBound }`, which is deterministic and checks the range on
    ///     the way past.
    ///   - sleep: tests pass `{ _ in }`.
    init(
        config: FaceCheckConfig,
        transport: (any HTTPTransport)? = nil,
        boundaryFactory: @escaping @Sendable () -> String = FaceCheckAPIClient.makeBoundary,
        jitter: @escaping @Sendable (ClosedRange<Int64>) -> Int64 = { Int64.random(in: $0) },
        sleep: @escaping @Sendable (_ milliseconds: Int64) async throws -> Void
            = FaceCheckAPIClient.systemSleep
    ) {
        self.config = config
        self.transport = transport ?? URLSessionTransport(config: config)
        self.boundaryFactory = boundaryFactory
        self.jitter = jitter
        self.sleep = sleep
    }

    /// Registers a subject ID's reference face.
    ///
    /// Parts, in this order — the order does not matter to Werkzeug, but sending
    /// the text fields before the files lets a streaming parser reject a bad
    /// subject ID before spooling 10 MB, and keeps a wire diff against the Kotlin SDK
    /// empty:
    ///
    /// 1. `subjectId` — already canonicalised by ``FaceCheckSubjectId``.
    /// 2. `grant` — only when non-nil. Not filtered on emptiness, for parity.
    /// 3. `overwrite` — only when true, and then exactly the string `"true"`.
    ///    `parse_bool_flag` accepts only `true/1/yes/false/0/no`, so never
    ///    `"True"` and never an interpolated Swift `Bool`.
    /// 4. `selfie` — required.
    /// 5. `ine` — only when non-nil.
    func enroll(
        subjectId: String,
        selfie: Data,
        ine: Data? = nil,
        grant: String? = nil,
        overwrite: Bool = false
    ) async throws -> EnrollResult {
        try FaceCheckSubjectId.validate(subjectId)
        // The grant is reported as present/none and never printed: it is a bearer
        // credential good for one enrollment. Image bytes only ever reach a log
        // through `describeBytes`, which reports a size and nothing else.
        FaceCheckLogger.info(
            "enroll: selfie=\(FaceCheckLogger.describeBytes(selfie.count)) "
                + "ine=\(ine.map { FaceCheckLogger.describeBytes($0.count) } ?? "none") "
                + "grant=\(grant == nil ? "none" : "present") overwrite=\(overwrite)"
        )
        return try await post(Self.enrollPath) { form in
            form.appendField(name: "subjectId", value: subjectId)
            if let grant {
                form.appendField(name: "grant", value: grant)
            }
            if overwrite {
                form.appendField(name: "overwrite", value: "true")
            }
            form.appendImage(name: "selfie", bytes: selfie)
            if let ine {
                form.appendImage(name: "ine", bytes: ine)
            }
        }
    }

    /// Matches a fresh selfie against what is stored.
    ///
    /// Parts: `subjectId`, `compareWith` (**always** present, even at
    /// its default), then `selfie`.
    func verify(
        subjectId: String,
        selfie: Data,
        compareWith: CompareWith = .enrollment
    ) async throws -> VerifyResult {
        try FaceCheckSubjectId.validate(subjectId)
        FaceCheckLogger.info(
            "verify: selfie=\(FaceCheckLogger.describeBytes(selfie.count)) compareWith=\(compareWith.wire)"
        )
        return try await post(Self.verifyPath) { form in
            form.appendField(name: "subjectId", value: subjectId)
            form.appendField(name: "compareWith", value: compareWith.wire)
            form.appendImage(name: "selfie", bytes: selfie)
        }
    }

    /// Invalidates the transport. This is what ``FaceCheck/shutdown()`` calls.
    func close() {
        transport.close()
    }

    /// The shared retry loop.
    ///
    /// The URL is `config.endpoint(path)` built by **string concatenation**; a
    /// nil from `URL(string:)` becomes ``FaceCheckErrorCode/invalidConfig``. Do
    /// not switch to `appendingPathComponent` or `URLComponents` — both
    /// re-encode and can alter a `baseUrl` that carries a path prefix.
    ///
    /// `try Task.checkCancellation()` runs before every attempt and after every
    /// sleep. A `URLError(.cancelled)` is disambiguated the same way: check
    /// cancellation, and if the task was *not* cancelled the session was
    /// invalidated by ``close()``, so it maps to ``FaceCheckErrorCode/networkError``.
    private func post<T: Decodable & Sendable>(
        _ path: String,
        parts: (inout MultipartFormData) -> Void
    ) async throws -> T {
        let endpoint = config.endpoint(path)
        guard let url = URL(string: endpoint) else {
            throw FaceCheckError(
                code: .invalidConfig,
                message: "baseUrl no produce una URL válida: \(endpoint)"
            )
        }

        // Encoded once and reused across attempts: the bytes are identical every
        // time, and re-encoding a 20 MB body per retry would be pure waste.
        var form = MultipartFormData(boundary: boundaryFactory())
        parts(&form)
        let body = form.encode()

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // Per request rather than in `httpAdditionalHeaders`, so it is obvious at
        // the point of use who authenticates what.
        request.setValue(config.apiKey, forHTTPHeaderField: Self.apiKeyHeader)
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        // Harmless, and it keeps content-negotiating proxies from guessing.
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // `httpBody` stays nil: the body travels through `upload(for:from:)`, and
        // Content-Length is URLSession's to compute.

        var attempt = 0
        while true {
            try Task.checkCancellation()

            let data: Data
            let response: HTTPURLResponse
            do {
                (data, response) = try await transport.send(request, body: body)
            } catch let refusal as FaceCheckError {
                // The transport itself refused to produce a response (a
                // non-HTTP URLResponse). Not a transport failure and not
                // retryable: another attempt would refuse identically.
                throw refusal
            } catch {
                // Throws rather than returns when the task was cancelled, which
                // keeps structured concurrency intact and stops the retry loop
                // from treating a cancellation as an attempt.
                let mapped = try Self.transportFailure(error)
                if attempt < config.maxRetries {
                    FaceCheckLogger.warn(
                        "\(path) failed (\(mapped.code.rawValue)), retry \(attempt + 1) of "
                            + "\(config.maxRetries): \(Self.diagnostic(for: error))"
                    )
                    try await sleep(backoffMilliseconds(attempt: attempt))
                    try Task.checkCancellation()
                    attempt += 1
                    continue
                }
                throw mapped
            }

            let status = response.statusCode
            if (200..<300).contains(status) {
                return try decodeBody(data, status: status)
            }

            // Only 5xx is retried. A 4xx is the backend saying the request itself
            // is wrong, and re-sending it unchanged cannot make it right — but it
            // can do damage, because /verify bills and counts against the
            // subject's lockout streak on every attempt.
            if status >= Self.httpServerError, attempt < config.maxRetries {
                FaceCheckLogger.warn(
                    "\(path) returned \(status), retry \(attempt + 1) of \(config.maxRetries)"
                )
                try await sleep(backoffMilliseconds(attempt: attempt))
                try Task.checkCancellation()
                attempt += 1
                continue
            }

            let error = Self.faceCheckError(from: data, httpStatus: status)
            FaceCheckLogger.warn("\(path) rejected: \(error.code.rawValue) \(error.message)")
            throw error
        }
    }

    /// Classifies a transport-layer failure, and rethrows a real cancellation.
    ///
    /// `URLError.Code` is exact, so the Kotlin SDK's heuristic of matching on the
    /// exception class name is gone: Ktor puts its timeout types in platform
    /// source sets that common code cannot name, and Foundation has no such
    /// problem.
    ///
    /// `.cancelled` is ambiguous — URLSession reports both a cancelled `Task` and
    /// a session invalidated by ``close()`` that way — so it is disambiguated by
    /// asking the task itself. A cancelled task propagates `CancellationError`; an
    /// invalidated session is just another network failure.
    private static func transportFailure(_ error: any Error) throws -> FaceCheckError {
        if error is CancellationError {
            throw error
        }
        guard let urlError = error as? URLError else {
            return FaceCheckError(code: .networkError, underlying: error)
        }
        switch urlError.code {
        case .timedOut:
            return FaceCheckError(code: .timeout, underlying: urlError)
        case .cancelled:
            try Task.checkCancellation()
            return FaceCheckError(code: .networkError, underlying: urlError)
        default:
            return FaceCheckError(code: .networkError, underlying: urlError)
        }
    }

    /// What to write in a retry warning.
    ///
    /// Deliberately the numeric `NSURLError` constant and not
    /// `localizedDescription`, which comes out in the device's language and is
    /// useless in a support ticket. The value is stable and greppable.
    private static func diagnostic(for error: any Error) -> String {
        if let urlError = error as? URLError {
            return "URLError \(urlError.errorCode)"
        }
        return String(describing: type(of: error))
    }

    /// Decodes a 2xx body, or throws ``FaceCheckErrorCode/invalidResponse``
    /// carrying the real status. Called from inside ``post(_:parts:)`` and
    /// deliberately outside the retry loop.
    ///
    /// The decoder keeps `.useDefaultKeys`: every wire key is already camelCase.
    /// `.convertFromSnakeCase` breaks nothing visible today but leaves a trap armed.
    private func decodeBody<T: Decodable>(_ data: Data, status: Int) throws -> T {
        let decoder = JSONDecoder()
        // Explicit, not inherited: every wire key is already camelCase
        // (`subjectId`, `faceQuality`, `livenessEnforced`…). `.convertFromSnakeCase`
        // would break nothing visible today and leave a trap armed for the first
        // key that is not.
        decoder.keyDecodingStrategy = .useDefaultKeys
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            // The `DecodingError` is rendered to text here because it is not
            // Sendable and ``FaceCheckError`` must be.
            throw FaceCheckError(
                code: .invalidResponse,
                httpStatus: status,
                underlying: ResponseDecodingFailure(error)
            )
        }
    }

    /// Full-jitter exponential backoff over `[base, min(base * 2^attempt, 8000)]`.
    ///
    /// Jittered because the failure mode that matters is a hot instance dying
    /// under load: without jitter every client that failed together retries
    /// together and rebuilds the spike.
    ///
    /// **The `min` must be applied in `Double` space, before converting to
    /// `Int64`.** Kotlin's `Double.toLong()` saturates at `Long.MAX_VALUE`;
    /// Swift's `Int64(someDouble)` **traps**. With a high `maxRetries` and a base
    /// of 500 the double exceeds `Int64.max` and the app dies.
    func backoffMilliseconds(attempt: Int) -> Int64 {
        let base = Int64(config.retryBaseDelayMs)
        let scaled = Double(base) * pow(2, Double(attempt))
        // The cap is applied in Double space, before any conversion. Kotlin's
        // `Double.toLong()` saturates; `Int64(someDouble)` traps, so a large
        // `maxRetries` would kill the app rather than wait a long time. The
        // finiteness check covers the `0 * infinity` corner, which is NaN and
        // would trap the same way.
        let capped = scaled.isFinite
            ? Swift.min(scaled, Double(Self.maxBackoffMs))
            : Double(Self.maxBackoffMs)
        // `max` keeps the range non-empty when a caller configures a base delay
        // above the cap; an inverted range would trap in `Int64.random(in:)`.
        let ceiling = Swift.max(Int64(capped), base)
        return jitter(base...ceiling)
    }

    /// Builds a ``FaceCheckError`` from an error response body.
    ///
    /// Pure over `(Data, Int)`, so it is tested without a network.
    ///
    /// - `code` → ``FaceCheckErrorCode/fromWire(_:)``, degrading to `.unknown`.
    /// - `message` → used when non-blank after trimming (Kotlin's `isNotBlank`),
    ///   otherwise `code.messageEs`. The backend's message wins because it knows
    ///   more about the specific refusal than the enum does.
    /// - `details` → flattened by ``JSONValue/flattened(_:)``.
    ///
    /// **Never throws.** An empty body, a load balancer's HTML, truncated JSON or
    /// a missing `error` key all end as `.unknown` plus the generic message and
    /// the real status: a malformed body must not replace the error the caller
    /// needs to see.
    static func faceCheckError(from data: Data, httpStatus: Int) -> FaceCheckError {
        let payload = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error

        // Blank-checked, and the untrimmed original is what gets used — Kotlin's
        // `takeIf { it.isNotBlank() }` keeps the value as it arrived. Note this is
        // deliberately stricter than `VerifyResult.messageEs`, which only tests
        // for nil; if that asymmetry is ever fixed it has to be fixed on both
        // sides and in the backend, not silently here.
        let message = payload?.message.flatMap { raw in
            raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : raw
        }

        return FaceCheckError(
            code: FaceCheckErrorCode.fromWire(payload?.code),
            message: message,
            httpStatus: httpStatus,
            details: JSONValue.flattened(payload?.details)
        )
    }

    /// `"----FaceCheckBoundary" + a UUID with the hyphens stripped` — 53
    /// characters, all inside RFC 2046's `bchars` and well under the 70-character
    /// maximum, so it never needs quoting in the header and header and body
    /// cannot diverge.
    ///
    /// Random rather than constant because the boundary must not occur inside the
    /// payload. With arbitrary binary (a JPEG) a short constant is a collision
    /// waiting to happen; 128 random bits make it impossible in practice. Ktor
    /// generated this, so the Kotlin SDK never had to think about it.
    @Sendable
    static func makeBoundary() -> String {
        "----FaceCheckBoundary" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    /// `Task.sleep(nanoseconds:)`. Not `Task.sleep(for:)`/`Duration`, which are iOS 16.
    ///
    /// Its `CancellationError` must be allowed to propagate, never swallowed.
    @Sendable
    static func systemSleep(milliseconds: Int64) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, milliseconds)) * 1_000_000)
    }

    static let apiKeyHeader = "X-Api-Key"
    static let enrollPath = "enroll"
    static let verifyPath = "verify"
    static let httpServerError = 500
    static let maxBackoffMs: Int64 = 8_000
}
