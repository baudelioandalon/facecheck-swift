import XCTest

@testable import FaceCheck

let testKey = "lk_test_a1b2c3d4e5f6g7h8"
let liveKey = "lk_live_a1b2c3d4e5f6g7h8"
let baseUrl = "https://facecheck.example.com"

/// Port of the Kotlin `FaceCheckConfigTest`.
final class FaceCheckConfigTests: XCTestCase {

    func testDerivesTheModeFromTheKeyPrefix() throws {
        XCTAssertEqual(try FaceCheckConfig(apiKey: testKey, baseUrl: baseUrl).mode, .test)
        XCTAssertEqual(try FaceCheckConfig(apiKey: liveKey, baseUrl: baseUrl).mode, .live)
    }

    func testRejectsAKeyWithoutARecognisedPrefix() {
        let failure = assertThrowsFaceCheckError(
            try FaceCheckConfig(apiKey: "sk_live_a1b2c3d4e5f6g7h8", baseUrl: baseUrl),
            code: .invalidConfig
        )
        // The prefix is checked before the length, because Kotlin evaluates the
        // `mode` property initialiser before its `init` block. A key that is
        // wrong in both ways must report the prefix, not the length.
        XCTAssertTrue(
            failure?.message.contains("debe empezar con") == true,
            "expected the prefix message, got \(failure?.message ?? "nothing")"
        )
    }

    func testRejectsATruncatedKeyOrOneWithWhitespace() {
        // Valid prefix, eight characters: this one does report the length.
        let short = assertThrowsFaceCheckError(
            try FaceCheckConfig(apiKey: "lk_test_", baseUrl: baseUrl),
            code: .invalidConfig
        )
        XCTAssertEqual(short?.message, "La llave de API está incompleta.")

        let spaced = assertThrowsFaceCheckError(
            try FaceCheckConfig(apiKey: "lk_test_a1b2 c3d4e5f6g7", baseUrl: baseUrl),
            code: .invalidConfig
        )
        XCTAssertEqual(spaced?.message, "La llave de API contiene espacios.")
    }

    func testRefusesALiveKeyOverCleartextHTTP() throws {
        // A production key on http would put a selfie and an email on the wire in
        // the clear. Refused rather than warned about: a warning gets ignored.
        assertThrowsFaceCheckError(
            try FaceCheckConfig(apiKey: liveKey, baseUrl: "http://facecheck.example.com"),
            code: .invalidConfig
        )

        // A test key against a local emulator is exactly what http is for.
        XCTAssertEqual(
            try FaceCheckConfig(apiKey: testKey, baseUrl: "http://127.0.0.1:5001").mode,
            .test
        )
    }

    func testRejectsABaseUrlThatIsNotHTTP() {
        assertThrowsFaceCheckError(
            try FaceCheckConfig(apiKey: testKey, baseUrl: "facecheck.example.com"),
            code: .invalidConfig
        )
    }

    func testBuildsEndpointsWithoutDoublingSlashes() throws {
        let config = try FaceCheckConfig(apiKey: testKey, baseUrl: "\(baseUrl)/")
        XCTAssertEqual(config.endpoint("enroll"), "\(baseUrl)/enroll")
        XCTAssertEqual(config.endpoint("/verify"), "\(baseUrl)/verify")
    }

    func testRejectsAChallengeCountOutsideTheSupportedRange() {
        assertThrowsFaceCheckError(
            try FaceCheckConfig(apiKey: testKey, baseUrl: baseUrl, challengeCount: 0),
            code: .invalidConfig
        )
        assertThrowsFaceCheckError(
            try FaceCheckConfig(apiKey: testKey, baseUrl: baseUrl, challengeCount: 99),
            code: .invalidConfig
        )
    }

    func testDescriptionNeverCarriesTheWholeKey() throws {
        // A config ends up in crash reports and bug tickets; the default struct
        // rendering would take the API key along with it.
        let config = try FaceCheckConfig(apiKey: liveKey, baseUrl: baseUrl)
        for rendered in [
            config.description,
            config.debugDescription,
            String(describing: config),
            String(reflecting: config),
            "\(config)",
        ] {
            XCTAssertFalse(rendered.contains(liveKey), "leaked the key: \(rendered)")
            XCTAssertTrue(
                rendered.contains("lk_live_a1b2"),
                "expected the portal's preview form, got \(rendered)"
            )
        }
    }

    /// `dump()` walks the mirror rather than `description`, so the redaction has
    /// to be installed there too or the debugger route stays wide open.
    func testTheMirrorIsRedactedAsWell() throws {
        let config = try FaceCheckConfig(apiKey: liveKey, baseUrl: baseUrl)
        var dumped = ""
        dump(config, to: &dumped)
        XCTAssertFalse(dumped.contains(liveKey), "dump() leaked the key: \(dumped)")
    }
}

/// Port of the Kotlin `FaceCheckInitializeTest`.
///
/// ``FaceCheck`` is process-global, so every case brackets itself with
/// `shutdown()` exactly as the Kotlin `@BeforeTest`/`@AfterTest` pair does.
final class FaceCheckInitializeTests: XCTestCase {

    override func setUp() {
        super.setUp()
        FaceCheck.shutdown()
    }

    override func tearDown() {
        FaceCheck.shutdown()
        FaceCheckLogger.level = .none
        super.tearDown()
    }

    func testInitializeIsIdempotentForAnIdenticalConfig() throws {
        let config = try FaceCheckConfig(apiKey: testKey, baseUrl: baseUrl)
        try FaceCheck.initialize(config)
        // A struct is copied by assignment, so this is Kotlin's `config.copy()`.
        let duplicate = config
        try FaceCheck.initialize(duplicate)

        XCTAssertTrue(FaceCheck.isInitialized)
        XCTAssertEqual(FaceCheck.config, config)
    }

    func testInitializeRefusesToBeRePointedAtADifferentConfig() throws {
        // Two configs in one process means two keys, and therefore two tenants or
        // two modes: whichever call ran last would silently decide whose data an
        // enrollment landed in.
        try FaceCheck.initialize(FaceCheckConfig(apiKey: testKey, baseUrl: baseUrl))

        assertThrowsFaceCheckError(
            try FaceCheck.initialize(FaceCheckConfig(apiKey: liveKey, baseUrl: baseUrl)),
            code: .invalidConfig
        )
        XCTAssertEqual(FaceCheck.config?.mode, .test)
    }

    func testBuildingAMachineBeforeInitializeReportsNotInitialized() {
        assertThrowsFaceCheckError(try FaceCheck.makeChallengeMachine(), code: .notInitialized)
    }

    func testTheMachineItBuildsMatchesTheConfiguredChallengeCount() throws {
        try FaceCheck.initialize(
            FaceCheckConfig(apiKey: testKey, baseUrl: baseUrl, challengeCount: 3)
        )
        XCTAssertEqual(try FaceCheck.makeChallengeMachine().challenges.count, 3)
    }

    func testShutdownAllowsAFreshConfiguration() throws {
        try FaceCheck.initialize(FaceCheckConfig(apiKey: testKey, baseUrl: baseUrl))
        FaceCheck.shutdown()
        XCTAssertFalse(FaceCheck.isInitialized)

        try FaceCheck.initialize(FaceCheckConfig(apiKey: liveKey, baseUrl: baseUrl))
        XCTAssertEqual(FaceCheck.config?.mode, .live)
    }

    /// The Kotlin SDK raises the log level before emitting its first line, or the
    /// line is filtered by the *old* level and the SDK looks silent at startup.
    func testInitializeAppliesTheConfiguredLogLevelBeforeItsFirstLine() throws {
        let collector = LogCollector()
        FaceCheckLogger.sink = FaceCheckLogSink { _, message in collector.append(message) }
        defer { FaceCheckLogger.sink = .osLog }

        try FaceCheck.initialize(
            FaceCheckConfig(apiKey: testKey, baseUrl: baseUrl, logLevel: .info)
        )

        XCTAssertEqual(FaceCheckLogger.level, .info)
        XCTAssertTrue(
            collector.lines.contains { $0.hasPrefix("FaceCheck initialized") },
            "expected the startup line, got \(collector.lines)"
        )
        // And it went out redacted, like everything else.
        XCTAssertFalse(collector.lines.contains { $0.contains(testKey) })
    }
}

/// `CameraOptions` used to `precondition` on its two numeric bounds, on the
/// stated theory that this "traps in debug". It does not — `precondition` is
/// live in `-O` as well — so a host reading a remote config crashed its users
/// from inside a public SDK initialiser. It clamps and logs instead.
final class CameraOptionsTests: XCTestCase {

    private let collector = LogCollector()

    override func setUp() {
        super.setUp()
        collector.clear()
        FaceCheckLogger.level = .warn
        FaceCheckLogger.sink = FaceCheckLogSink { [collector] _, message in
            collector.append(message)
        }
    }

    override func tearDown() {
        FaceCheckLogger.level = .none
        FaceCheckLogger.sink = .osLog
        super.tearDown()
    }

    func testTheDefaultsAreLeftAloneAndSaidNothing() {
        let options = CameraOptions()

        XCTAssertEqual(options.targetStillSize, 1_080)
        XCTAssertEqual(options.jpegQuality, 92)
        XCTAssertTrue(collector.lines.isEmpty, "expected silence, got \(collector.lines)")
    }

    func testAStillTooSmallToMatchAgainstIsRaisedToTheFloorInsteadOfTrapping() {
        let options = CameraOptions(targetStillSize: 320)

        XCTAssertEqual(options.targetStillSize, CameraOptions.minStillSize)
        XCTAssertEqual(collector.lines.count, 1)
        XCTAssertTrue(collector.lines[0].contains("320"), collector.lines[0])
    }

    func testAnOutOfRangeQualityIsClampedAtBothEnds() {
        XCTAssertEqual(CameraOptions(jpegQuality: 0).jpegQuality, 1)
        XCTAssertEqual(CameraOptions(jpegQuality: 250).jpegQuality, 100)
        XCTAssertEqual(collector.lines.count, 2)
    }
}
