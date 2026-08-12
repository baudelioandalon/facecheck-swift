import XCTest

@testable import FaceCheck

/// Port of the Kotlin `FaceCheckLoggerTest`.
///
/// ``FaceCheckLogger/level`` and ``FaceCheckLogger/sink`` are process-global, so
/// `tearDown` restores silence exactly as the Kotlin `@AfterTest` does. Without
/// it a later suite inherits a `.debug` level and a dead sink.
final class FaceCheckLoggerTests: XCTestCase {

    private let collector = LogCollector()

    private func capture(at level: FaceCheckLogLevel) {
        collector.clear()
        FaceCheckLogger.level = level
        FaceCheckLogger.sink = FaceCheckLogSink { [collector] _, message in
            collector.append(message)
        }
    }

    override func tearDown() {
        FaceCheckLogger.level = .none
        FaceCheckLogger.sink = .osLog
        super.tearDown()
    }

    func testAnAPIKeyNeverReachesTheSink() throws {
        // The leak that actually happens is the one nobody wrote on purpose: a
        // server error echoed verbatim, or a URL inside an exception message.
        capture(at: .debug)

        FaceCheckLogger.info("POST https://api/enroll key=lk_live_abc123XYZ_-456 failed")

        let line = try XCTUnwrap(collector.lines.first)
        XCTAssertEqual(collector.lines.count, 1)
        XCTAssertFalse(line.contains("abc123XYZ"), "the key survived redaction: \(line)")
        XCTAssertTrue(line.contains("lk_live_***"), line)
    }

    func testBothKeyPrefixesAreMasked() {
        capture(at: .debug)

        FaceCheckLogger.warn("keys: lk_test_aaaaaaaaaaaa and lk_live_bbbbbbbbbbbb")

        XCTAssertEqual(collector.lines, ["keys: lk_test_*** and lk_live_***"])
    }

    func testAnEmailKeepsOnlyItsDomain() throws {
        capture(at: .debug)

        FaceCheckLogger.info("verify for persona.ejemplo@gmail.com")

        let line = try XCTUnwrap(collector.lines.first)
        XCTAssertFalse(line.contains("ejemplo"), "the local part survived: \(line)")
        XCTAssertTrue(line.contains("p***@gmail.com"), line)
    }

    /// The addresses this SDK actually sees are Spanish-language ones, and an
    /// allow-listed ASCII local part masked almost nothing about them: the
    /// Kotlin pattern turned `maría@hotmail.com` into `maría***@hotmail.com`.
    func testAnAccentedLocalPartIsMaskedInFull() {
        capture(at: .debug)

        FaceCheckLogger.warn("INVALID_EMAIL: maría@hotmail.com")
        FaceCheckLogger.warn("INVALID_EMAIL: nuñez.peña@empresa.com.mx")
        FaceCheckLogger.warn("INVALID_EMAIL: Ángel.Muñoz@corp.mx")

        XCTAssertEqual(
            collector.lines,
            [
                "INVALID_EMAIL: m***@hotmail.com",
                "INVALID_EMAIL: n***@empresa.com.mx",
                "INVALID_EMAIL: Á***@corp.mx",
            ]
        )
    }

    /// A domain with no dotted TLD is still a domain, and the address in front of
    /// it is still an identity.
    func testADomainWithoutADottedTLDIsStillMasked() {
        capture(at: .debug)

        FaceCheckLogger.warn("usuario@localhost rejected")

        XCTAssertEqual(collector.lines, ["u***@localhost rejected"])
    }

    /// Keys are masked before emails, and the two orders are not interchangeable:
    /// keys-first keeps the evidence that a key was there at all.
    func testAKeyThatLooksLikeAnEmailLocalPartIsStillMaskedAsAKey() throws {
        capture(at: .debug)

        FaceCheckLogger.info("lk_test_abcdefghijkl@gmail.com")

        XCTAssertEqual(collector.lines, ["lk_test_***@gmail.com"])
    }

    func testImageDataCanOnlyBeDescribedBySize() {
        // There is no overload that takes `Data`, so "log the selfie" is not
        // something a caller can express in the first place.
        XCTAssertEqual(FaceCheckLogger.describeBytes(204_800), "<204800 bytes>")
    }

    func testNothingIsEmittedAtTheDefaultLevel() {
        capture(at: .none)

        FaceCheckLogger.error("boom")
        FaceCheckLogger.debug("chatter")

        XCTAssertTrue(collector.lines.isEmpty, "expected silence, got \(collector.lines)")
    }

    func testALevelAdmitsEverythingAtOrAboveItsSeverity() {
        capture(at: .warn)

        FaceCheckLogger.error("error")
        FaceCheckLogger.warn("warn")
        FaceCheckLogger.info("info")
        FaceCheckLogger.debug("debug")

        XCTAssertEqual(collector.lines, ["error", "warn"])
    }

    func testASuppressedMessageIsNeverEvenBuilt() {
        capture(at: .error)
        var built = 0

        func expensive() -> String {
            built += 1
            return "expensive"
        }

        // The parameter is a non-escaping `@autoclosure`, so this call site is
        // exactly Kotlin's `FaceCheckLogger.debug { built++; "expensive" }`.
        FaceCheckLogger.debug(expensive())

        XCTAssertEqual(built, 0, "the message was built despite the level being off")
    }
}
