import Foundation
import XCTest

@testable import FaceCheck

/// Stands in for Ktor's `MockEngine`: a scripted ``HTTPTransport`` that records
/// every request and the exact bytes that went with it.
///
/// The body arrives as its own parameter rather than inside the `URLRequest`,
/// which is the whole reason the seam is a bespoke protocol instead of
/// `URLProtocol` — four of these tests assert on the real multipart payload.
private final class MockTransport: HTTPTransport, @unchecked Sendable {

    typealias Handler = @Sendable (URLRequest, Data, Int) throws -> (Data, HTTPURLResponse)

    private let lock = NSLock()
    private let handler: Handler
    private var recorded: [(request: URLRequest, body: Data)] = []
    private var closes = 0

    init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    var attempts: Int { lock.lock(); defer { lock.unlock() }; return recorded.count }
    var closeCount: Int { lock.lock(); defer { lock.unlock() }; return closes }
    var lastRequest: URLRequest? { lock.lock(); defer { lock.unlock() }; return recorded.last?.request }

    /// The multipart payload as text. Every fixture here is ASCII, so this is
    /// lossless for what the assertions look at.
    var lastBodyText: String {
        lock.lock()
        defer { lock.unlock() }
        return recorded.last.map { String(decoding: $0.body, as: UTF8.self) } ?? ""
    }

    func send(_ request: URLRequest, body: Data) async throws -> (Data, HTTPURLResponse) {
        try handler(request, body, record(request, body: body))
    }

    /// Split out of `send` because taking an `NSLock` directly inside an `async`
    /// function is an error in the Swift 6 language mode: a suspension while
    /// holding it would block whichever thread the continuation resumes on.
    /// Nothing here suspends, so a synchronous helper is the whole fix.
    ///
    /// - Returns: this request's 1-based attempt number.
    private func record(_ request: URLRequest, body: Data) -> Int {
        lock.lock()
        defer { lock.unlock() }
        recorded.append((request, body))
        return recorded.count
    }

    func close() {
        lock.lock()
        closes += 1
        lock.unlock()
    }
}

private let selfieBytes = Data("fake-jpeg-selfie".utf8)
private let ineBytes = Data("fake-jpeg-ine".utf8)

/// A free function rather than a method on the test case: the handlers below are
/// `@Sendable`, and capturing `self` from one would drag a non-`Sendable`
/// `XCTestCase` across an isolation boundary.
private func respondJSON(_ body: String, status: Int = 200) -> (Data, HTTPURLResponse) {
    let response = HTTPURLResponse(
        url: URL(string: "\(baseUrl)/enroll")!,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]
    )!
    return (Data(body.utf8), response)
}

private let enrollBody = """
{
  "enrolled": true,
  "overwritten": false,
  "subjectId": "test_9f86d081",
  "mode": "test",
  "spoofScore": null,
  "faceQuality": {
    "imageWidth": 1080, "imageHeight": 1440,
    "faceWidth": 430, "faceHeight": 520,
    "faceRatio": 0.398, "detectorScore": 0.999,
    "sharpness": 180.5, "brightness": 131.2, "aligned": true
  },
  "ineEnrolled": false,
  "ineQuality": null,
  "modelVersion": "w600k_mbf-1"
}
"""

private let verifyBody = """
{
  "verified": false,
  "reason": "FACE_MISMATCH",
  "message": "El rostro no coincide con el registrado.",
  "compareWith": "both",
  "checks": {
    "faceMatch": false, "ineMatch": true,
    "liveness": null, "livenessEnforced": false
  },
  "spoofScore": null,
  "faceQuality": null,
  "verificationId": "vrf_123"
}
"""

/// Port of the Kotlin `FaceCheckApiTest`.
final class FaceCheckAPITests: XCTestCase {

    private func makeConfig(maxRetries: Int = 2) throws -> FaceCheckConfig {
        try FaceCheckConfig(apiKey: testKey, baseUrl: baseUrl, maxRetries: maxRetries)
    }

    /// A client whose retries never actually sleep, whose boundary is fixed and
    /// whose jitter is the low end of the range — deterministic, and it checks
    /// the range on the way past.
    private func makeClient(
        maxRetries: Int = 2,
        transport: MockTransport
    ) throws -> FaceCheckAPIClient {
        try FaceCheckAPIClient(
            config: makeConfig(maxRetries: maxRetries),
            transport: transport,
            boundaryFactory: { "----FaceCheckBoundaryTEST" },
            jitter: { $0.lowerBound },
            sleep: { _ in }
        )
    }

    // MARK: Happy paths

    func testEnrollParsesTheSuccessEnvelope() async throws {
        let transport = MockTransport { _, _, _ in respondJSON(enrollBody) }
        let api = try makeClient(transport: transport)

        let result = try await api.enroll(email: "persona@ejemplo.com", selfie: selfieBytes)

        XCTAssertTrue(result.enrolled)
        XCTAssertEqual(result.subjectId, "test_9f86d081")
        XCTAssertFalse(result.overwritten)
        XCTAssertEqual(result.faceQuality?.faceRatio, 0.398)
        XCTAssertEqual(result.modelVersion, "w600k_mbf-1")
        XCTAssertNil(result.spoofScore)
    }

    func testVerifyParsesANegativeVerdictAsAResultNotAnError() async throws {
        // A face that does not match is an answer, not a failure. Throwing here
        // would force every integrator into a do/catch for the normal case.
        let transport = MockTransport { _, _, _ in respondJSON(verifyBody) }
        let api = try makeClient(transport: transport)

        let result = try await api.verify(
            email: "persona@ejemplo.com",
            selfie: selfieBytes,
            compareWith: .both
        )

        XCTAssertFalse(result.verified)
        XCTAssertEqual(result.reason, "FACE_MISMATCH")
        XCTAssertEqual(result.checks.faceMatch, false)
        XCTAssertEqual(result.checks.ineMatch, true)
        // Tri-state: nil is "the comparison never ran", not "it failed".
        XCTAssertNil(result.checks.liveness)
        XCTAssertEqual(result.compareWith, .both)
        XCTAssertEqual(result.messageEs, "El rostro no coincide con el registrado.")
    }

    func testAnUnknownFieldInTheResponseDoesNotBreakAShippedApp() async throws {
        // There is no update path for an SDK already on someone's phone.
        let transport = MockTransport { _, _, _ in
            respondJSON(#"{"enrolled":true,"subjectId":"s1","brandNewField":42}"#)
        }
        let api = try makeClient(transport: transport)

        let result = try await api.enroll(email: "persona@ejemplo.com", selfie: selfieBytes)
        XCTAssertTrue(result.enrolled)
        // Absent optional fields fall back rather than throwing.
        XCTAssertEqual(result.mode, "")
        XCTAssertNil(result.faceQuality)
    }

    // MARK: The request on the wire

    func testEveryRequestCarriesTheAPIKeyHeaderAndTheRightURL() async throws {
        let transport = MockTransport { _, _, _ in respondJSON(enrollBody) }
        let api = try makeClient(transport: transport)

        _ = try await api.enroll(email: "persona@ejemplo.com", selfie: selfieBytes)

        let request = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "\(baseUrl)/enroll")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Key"), testKey)
        XCTAssertTrue(
            request.value(forHTTPHeaderField: "Content-Type")?
                .contains("multipart/form-data") == true
        )
        // The body travels through `upload(for:from:)`; leaving it in `httpBody`
        // as well would send it twice on some paths and confuse Content-Length.
        XCTAssertNil(request.httpBody)
    }

    func testEnrollSendsTheFieldsAndFilesTheBackendRequires() async throws {
        let transport = MockTransport { _, _, _ in respondJSON(enrollBody) }
        let api = try makeClient(transport: transport)

        _ = try await api.enroll(
            email: "Persona@Ejemplo.com",
            selfie: selfieBytes,
            ine: ineBytes,
            overwrite: true
        )

        let body = transport.lastBodyText
        // Sent exactly as given: normalising an email is the backend's job, and
        // doing it in two places is how the two stop agreeing.
        XCTAssertTrue(body.contains("Persona@Ejemplo.com"), body)
        XCTAssertTrue(body.contains(#"name="overwrite""#), body)
        // `parse_bool_flag` accepts only true/1/yes/false/0/no, so never "True".
        XCTAssertTrue(body.contains("\r\n\r\ntrue\r\n"), body)
        // Both the filename and the content type are mandatory: the backend
        // treats a part with neither as absent and answers MISSING_FILE with a
        // perfectly valid image sitting in the body.
        XCTAssertTrue(body.contains(#"filename="selfie.jpg""#), body)
        XCTAssertTrue(body.contains(#"filename="ine.jpg""#), body)
        XCTAssertTrue(body.contains("Content-Type: image/jpeg"), body)
        XCTAssertTrue(body.contains("fake-jpeg-selfie"), body)
        XCTAssertTrue(body.contains("fake-jpeg-ine"), body)
    }

    func testEnrollOmitsTheOverwriteFlagUnlessItWasAskedFor() async throws {
        let transport = MockTransport { _, _, _ in respondJSON(enrollBody) }
        let api = try makeClient(transport: transport)

        _ = try await api.enroll(email: "persona@ejemplo.com", selfie: selfieBytes)

        let body = transport.lastBodyText
        XCTAssertFalse(body.contains("overwrite"), "unexpected overwrite part: \(body)")
        XCTAssertFalse(body.contains(#"filename="ine.jpg""#), "unexpected ine part: \(body)")
        XCTAssertFalse(body.contains(#"name="grant""#), "unexpected grant part: \(body)")
    }

    /// The SDK never signs a grant: it forwards one its integrator's backend
    /// signed. All this checks is that the opaque string is passed through as a
    /// plain text field.
    func testAGrantIsForwardedVerbatimAsATextField() async throws {
        let transport = MockTransport { _, _, _ in respondJSON(enrollBody) }
        let api = try makeClient(transport: transport)

        _ = try await api.enroll(
            email: "persona@ejemplo.com",
            selfie: selfieBytes,
            grant: "grant.abc.123"
        )

        let body = transport.lastBodyText
        XCTAssertTrue(body.contains(#"name="grant""#), body)
        XCTAssertTrue(body.contains("\r\n\r\ngrant.abc.123\r\n"), body)
    }

    func testVerifySendsTheRequestedComparison() async throws {
        let transport = MockTransport { _, _, _ in respondJSON(verifyBody) }
        let api = try makeClient(transport: transport)

        _ = try await api.verify(
            email: "persona@ejemplo.com",
            selfie: selfieBytes,
            compareWith: .both
        )

        let body = transport.lastBodyText
        XCTAssertTrue(body.contains(#"name="compareWith""#), body)
        XCTAssertTrue(body.contains("\r\n\r\nboth\r\n"), body)
        XCTAssertEqual(transport.lastRequest?.url?.absoluteString, "\(baseUrl)/verify")
    }

    // MARK: Errors

    func testTheErrorEnvelopeBecomesATypedError() async throws {
        let transport = MockTransport { _, _, _ in
            respondJSON(
                #"{"error":{"code":"NOT_ENROLLED","message":"Este correo no tiene un registro facial.","details":{"mode":"test"}}}"#,
                status: 404
            )
        }
        let api = try makeClient(transport: transport)

        let failure = await assertThrowsFaceCheckError(code: .notEnrolled) {
            try await api.verify(email: "desconocido@ejemplo.com", selfie: selfieBytes)
        }

        XCTAssertEqual(failure?.httpStatus, 404)
        XCTAssertEqual(failure?.message, "Este correo no tiene un registro facial.")
        XCTAssertEqual(failure?.details["mode"], "test")
        XCTAssertEqual(failure?.isRetryable, false)
    }

    func testARateLimitExposesItsRetryHint() async throws {
        let transport = MockTransport { _, _, _ in
            respondJSON(
                #"{"error":{"code":"RATE_LIMITED","message":"Demasiados intentos.","details":{"retryAfterSeconds":42,"lockedUntil":"2026-08-10T18:30:00Z"}}}"#,
                status: 429
            )
        }
        let api = try makeClient(transport: transport)

        let failure = await assertThrowsFaceCheckError(code: .rateLimited) {
            try await api.verify(email: "persona@ejemplo.com", selfie: selfieBytes)
        }

        // 42 must decode as an integer, not a double: `Int("42.0")` is nil and
        // the caller would silently lose the backoff hint on a 429.
        XCTAssertEqual(failure?.retryAfterSeconds, 42)
        XCTAssertEqual(
            failure?.lockedUntil,
            ISO8601DateFormatter().date(from: "2026-08-10T18:30:00Z")
        )
    }

    func testAnUnrecognisedCodeDegradesInsteadOfCrashing() async throws {
        let transport = MockTransport { _, _, _ in
            respondJSON(
                #"{"error":{"code":"SOMETHING_ADDED_LATER","message":"Algo pasó."}}"#,
                status: 400
            )
        }
        let api = try makeClient(transport: transport)

        let failure = await assertThrowsFaceCheckError(code: .unknown) {
            try await api.enroll(email: "persona@ejemplo.com", selfie: selfieBytes)
        }
        XCTAssertEqual(failure?.message, "Algo pasó.")
    }

    /// A malformed body must not replace the error the caller needs to see: the
    /// status and a generic message survive an empty payload, a load balancer's
    /// HTML, or truncated JSON.
    func testAMalformedErrorBodyStillYieldsTheRealStatus() {
        for raw in ["", "<html>502 Bad Gateway</html>", #"{"error":"#, "{}"] {
            let error = FaceCheckAPIClient.faceCheckError(
                from: Data(raw.utf8),
                httpStatus: 502
            )
            XCTAssertEqual(error.code, .unknown, raw)
            XCTAssertEqual(error.httpStatus, 502, raw)
            XCTAssertEqual(error.message, FaceCheckErrorCode.unknown.messageEs, raw)
        }
    }

    /// A blank message loses to the enum's own prose. Note the deliberate
    /// asymmetry with `VerifyResult.messageEs`, which only tests for nil.
    func testABlankBackendMessageFallsBackToTheCodesOwnProse() {
        let error = FaceCheckAPIClient.faceCheckError(
            from: Data(#"{"error":{"code":"NOT_ENROLLED","message":"   "}}"#.utf8),
            httpStatus: 404
        )
        XCTAssertEqual(error.message, FaceCheckErrorCode.notEnrolled.messageEs)
    }

    func testAnUnparseableSuccessBodyIsReportedAsAnInvalidResponse() async throws {
        let transport = MockTransport { _, _, _ in respondJSON("not json at all") }
        let api = try makeClient(transport: transport)

        await assertThrowsFaceCheckError(code: .invalidResponse) {
            try await api.enroll(email: "persona@ejemplo.com", selfie: selfieBytes)
        }
        // A 2xx with an undecodable body is never retried: the work was done and
        // billed already, even though `invalidResponse` reports itself retryable.
        XCTAssertEqual(transport.attempts, 1)
    }

    // MARK: Retries

    func testA4xxIsNeverRetried() async throws {
        // /verify bills the tenant and counts against the subject's lockout
        // streak on every attempt: retrying a 403 would spend three of a user's
        // five allowed failures on one tap and lock them out of their own account.
        let transport = MockTransport { _, _, _ in
            respondJSON(
                #"{"error":{"code":"REENROLLMENT_FACE_MISMATCH","message":"No coincide."}}"#,
                status: 403
            )
        }
        let api = try makeClient(transport: transport)

        await assertThrowsFaceCheckError(code: .reenrollmentFaceMismatch) {
            try await api.enroll(
                email: "persona@ejemplo.com",
                selfie: selfieBytes,
                overwrite: true
            )
        }
        XCTAssertEqual(transport.attempts, 1)
    }

    func testA5xxIsRetriedUpToTheConfiguredLimitAndThenSucceeds() async throws {
        let transport = MockTransport { _, _, attempt in
            attempt <= 2
                ? respondJSON(
                    #"{"error":{"code":"INTERNAL","message":"boom"}}"#,
                    status: 500
                )
                : respondJSON(enrollBody)
        }
        let api = try makeClient(transport: transport)

        let result = try await api.enroll(email: "persona@ejemplo.com", selfie: selfieBytes)
        XCTAssertTrue(result.enrolled)
        XCTAssertEqual(transport.attempts, 3)
    }

    func testA5xxThatNeverClearsSurfacesTheBackendError() async throws {
        let transport = MockTransport { _, _, _ in
            respondJSON(
                #"{"error":{"code":"KEY_SERVICE_UNAVAILABLE","message":"No disponible."}}"#,
                status: 503
            )
        }
        let api = try makeClient(transport: transport)

        let failure = await assertThrowsFaceCheckError(code: .keyServiceUnavailable) {
            try await api.enroll(email: "persona@ejemplo.com", selfie: selfieBytes)
        }
        XCTAssertEqual(failure?.isRetryable, true)
        XCTAssertEqual(transport.attempts, 3, "expected the original attempt plus two retries")
    }

    func testATransportFailureIsRetriedAndThenReportedAsANetworkError() async throws {
        let transport = MockTransport { _, _, _ in
            throw URLError(.networkConnectionLost)
        }
        let api = try makeClient(maxRetries: 1, transport: transport)

        await assertThrowsFaceCheckError(code: .networkError) {
            try await api.verify(email: "persona@ejemplo.com", selfie: selfieBytes)
        }
        XCTAssertEqual(transport.attempts, 2)
    }

    /// `URLError.Code` is exact, so the Kotlin SDK's heuristic of matching on the
    /// exception class name is gone. A timeout must not be flattened into a
    /// generic network error: only one of the two is worth telling the user to
    /// check their connection over.
    func testATimeoutKeepsItsOwnCode() async throws {
        let transport = MockTransport { _, _, _ in throw URLError(.timedOut) }
        let api = try makeClient(maxRetries: 0, transport: transport)

        await assertThrowsFaceCheckError(code: .timeout) {
            try await api.enroll(email: "persona@ejemplo.com", selfie: selfieBytes)
        }
    }

    func testRetriesCanBeSwitchedOffEntirely() async throws {
        let transport = MockTransport { _, _, _ in
            respondJSON(
                #"{"error":{"code":"INTERNAL","message":"boom"}}"#,
                status: 500
            )
        }
        let api = try makeClient(maxRetries: 0, transport: transport)

        await assertThrowsFaceCheckError(code: .internalError) {
            try await api.enroll(email: "persona@ejemplo.com", selfie: selfieBytes)
        }
        XCTAssertEqual(transport.attempts, 1)
    }

    /// Kotlin's `Double.toLong()` saturates; Swift's `Int64(someDouble)` **traps**,
    /// so the cap has to be applied in `Double` space. A high `maxRetries` would
    /// otherwise kill the app instead of waiting a long time.
    func testBackoffIsCappedBeforeItLeavesDoubleSpace() throws {
        let transport = MockTransport { _, _, _ in respondJSON(enrollBody) }
        let api = try makeClient(transport: transport)

        XCTAssertEqual(api.backoffMilliseconds(attempt: 0), 500)
        XCTAssertEqual(api.backoffMilliseconds(attempt: 1), 500)
        // The jitter stub returns the low end, so what these prove is that the
        // range is well formed at all: an inverted or overflowing one traps.
        XCTAssertEqual(api.backoffMilliseconds(attempt: 5), 500)
        XCTAssertEqual(api.backoffMilliseconds(attempt: 10_000), 500)

        // And the high end is the cap, never `2^10000 * 500`.
        let ceilings = try FaceCheckAPIClient(
            config: makeConfig(),
            transport: transport,
            jitter: { $0.upperBound },
            sleep: { _ in }
        )
        XCTAssertEqual(ceilings.backoffMilliseconds(attempt: 0), 500)
        XCTAssertEqual(ceilings.backoffMilliseconds(attempt: 1), 1_000)
        XCTAssertEqual(ceilings.backoffMilliseconds(attempt: 5), 8_000)
        XCTAssertEqual(ceilings.backoffMilliseconds(attempt: 10_000), 8_000)
    }

    func testCloseInvalidatesTheTransport() throws {
        let transport = MockTransport { _, _, _ in respondJSON(enrollBody) }
        let api = try makeClient(transport: transport)

        api.close()

        XCTAssertEqual(transport.closeCount, 1)
    }
}

/// The wire enums have to degrade rather than throw: there is no update path for
/// an SDK that already lives on someone's phone.
final class WireEnumTests: XCTestCase {

    func testAnErrorCodeDegradesInsteadOfThrowing() {
        XCTAssertEqual(FaceCheckErrorCode.fromWire(" not_enrolled "), .notEnrolled)
        XCTAssertEqual(FaceCheckErrorCode.fromWire("SOMETHING_ADDED_LATER"), .unknown)
        XCTAssertEqual(FaceCheckErrorCode.fromWire(nil), .unknown)
        // `internal` is a Swift keyword, so the case was renamed; the raw value
        // is what every comparison actually uses and it must not have moved.
        XCTAssertEqual(FaceCheckErrorCode.internalError.rawValue, "INTERNAL")
        XCTAssertEqual(FaceCheckErrorCode.fromWire("INTERNAL"), .internalError)
    }

    func testCompareWithDegradesInsteadOfThrowing() {
        XCTAssertEqual(CompareWith.fromWire(nil), .enrollment)
        XCTAssertEqual(CompareWith.fromWire("  BOTH "), .both)
        XCTAssertEqual(CompareWith.fromWire("cualquier_cosa"), .enrollment)
        XCTAssertEqual(CompareWith.both.wire, "both")
    }

    /// Every reason a session can end has to carry Spanish prose and the right
    /// error code — a cancelled session is the user's own decision, not a
    /// liveness failure, and a host must not show "no pudimos verificarte" to
    /// someone who pressed back.
    func testEveryFailureReasonMapsToACodeAndSpanishProse() {
        for reason in FailureReason.allCases {
            XCTAssertFalse(reason.messageEs.isEmpty, "\(reason)")
            XCTAssertEqual(reason.logName, reason.logName.uppercased())
        }
        XCTAssertEqual(FailureReason.cancelled.errorCode, .cancelled)
        XCTAssertEqual(FailureReason.timeout.errorCode, .timeout)
        XCTAssertEqual(FailureReason.faceSwapped.errorCode, .livenessFailed)
        XCTAssertEqual(FailureReason.faceLost.errorCode, .livenessFailed)
        XCTAssertEqual(FailureReason.multipleFaces.errorCode, .livenessFailed)
    }

    func testEveryPositioningHintCarriesSpanishProse() {
        for hint in PositioningHint.allCases {
            XCTAssertFalse(hint.instructionEs.isEmpty, "\(hint)")
        }
    }
}
