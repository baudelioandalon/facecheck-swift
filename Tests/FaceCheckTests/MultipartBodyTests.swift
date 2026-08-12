import Foundation
import XCTest

@testable import FaceCheck

/// Byte-exact tests for the multipart encoder.
///
/// The Kotlin SDK never had these: Ktor built the body, so the only assertions
/// possible were `assertContains` on the text of a request Ktor had already
/// serialised. This port writes the bytes itself, so the layout is testable
/// directly — and it has to be, because every bug in this file is invisible from
/// the client side and comes back from the backend as `MISSING_FILE` or
/// `MISSING_EMAIL` with a perfectly valid payload sitting in the body.
///
/// The expected bodies below are assembled from explicit `\r\n` constants. They
/// must never be written as Swift multi-line string literals, which produce `\n`.
final class MultipartBodyTests: XCTestCase {

    private let boundary = "----FaceCheckBoundaryTEST"

    private func line(_ text: String) -> Data {
        Data(text.utf8) + MultipartFormData.crlf
    }

    /// Concatenated from an array rather than with a chain of `+`: a chain this
    /// long defeats the type checker outright.
    private func joined(_ chunks: [Data]) -> Data {
        chunks.reduce(into: Data()) { $0.append($1) }
    }

    func testATextFieldGetsNeitherAFilenameNorAContentType() {
        // Werkzeug routes on the presence of a filename: a text field carrying
        // one lands in `request.files` and vanishes from `request.form`, so the
        // backend answers MISSING_EMAIL with the email right there in the body.
        var form = MultipartFormData(boundary: boundary)
        form.appendField(name: "email", value: "persona@ejemplo.com")

        let expected = joined([
            line("--\(boundary)"),
            line(#"Content-Disposition: form-data; name="email""#),
            MultipartFormData.crlf,
            line("persona@ejemplo.com"),
            line("--\(boundary)--"),
        ])

        XCTAssertEqual(form.encode(), expected)
    }

    func testAnImageFieldAlwaysGetsBothAFilenameAndAContentType() {
        // `read_image_upload` treats a part without a filename as absent, and
        // rejects with 415 any part whose declared type is not in its allow-list.
        var form = MultipartFormData(boundary: boundary)
        form.appendImage(name: "selfie", bytes: Data("fake-jpeg".utf8))

        let expected = joined([
            line("--\(boundary)"),
            line(#"Content-Disposition: form-data; name="selfie"; filename="selfie.jpg""#),
            line("Content-Type: image/jpeg"),
            MultipartFormData.crlf,
            line("fake-jpeg"),
            line("--\(boundary)--"),
        ])

        XCTAssertEqual(form.encode(), expected)
    }

    func testTheFullEnrollBodyIsByteExact() {
        var form = MultipartFormData(boundary: boundary)
        form.appendField(name: "email", value: "Persona@Ejemplo.com")
        form.appendField(name: "overwrite", value: "true")
        form.appendImage(name: "selfie", bytes: Data("selfie-bytes".utf8))
        form.appendImage(name: "ine", bytes: Data("ine-bytes".utf8))

        let expected = joined([
            line("--\(boundary)"),
            line(#"Content-Disposition: form-data; name="email""#),
            MultipartFormData.crlf,
            line("Persona@Ejemplo.com"),
            line("--\(boundary)"),
            line(#"Content-Disposition: form-data; name="overwrite""#),
            MultipartFormData.crlf,
            line("true"),
            line("--\(boundary)"),
            line(#"Content-Disposition: form-data; name="selfie"; filename="selfie.jpg""#),
            line("Content-Type: image/jpeg"),
            MultipartFormData.crlf,
            line("selfie-bytes"),
            line("--\(boundary)"),
            line(#"Content-Disposition: form-data; name="ine"; filename="ine.jpg""#),
            line("Content-Type: image/jpeg"),
            MultipartFormData.crlf,
            line("ine-bytes"),
            line("--\(boundary)--"),
        ])

        XCTAssertEqual(form.encode(), expected)
    }

    func testTheLastPartIsClosedBeforeTheFinalDelimiter() {
        // The classic truncation bug: omitting the CRLF that closes the final
        // part's body glues it to the closing delimiter and the parser drops it.
        var form = MultipartFormData(boundary: boundary)
        form.appendImage(name: "selfie", bytes: Data([0xFF, 0xD8, 0xFF]))

        let expectedTail = Array(
            joined([MultipartFormData.crlf, line("--\(boundary)--")])
        )
        XCTAssertEqual(Array(form.encode().suffix(expectedTail.count)), expectedTail)
    }

    func testNoLineIsSeparatedByABareNewline() {
        var form = MultipartFormData(boundary: boundary)
        form.appendField(name: "email", value: "persona@ejemplo.com")
        form.appendImage(name: "selfie", bytes: Data("x".utf8))

        // Every 0x0A in the body must be preceded by a 0x0D. A `\n` alone is
        // what a Swift multi-line literal would have produced.
        let bytes = Array(form.encode())
        for (index, byte) in bytes.enumerated() where byte == 0x0A {
            XCTAssertTrue(
                index > 0 && bytes[index - 1] == 0x0D,
                "bare LF at offset \(index)"
            )
        }
    }

    func testBinaryPayloadsSurviveUnchanged() {
        // A round trip through `String` would replace every byte that is not
        // valid UTF-8, and a JPEG is full of them.
        let jpeg = Data((0...255).map { UInt8($0) })
        var form = MultipartFormData(boundary: boundary)
        form.appendImage(name: "selfie", bytes: jpeg)

        let encoded = form.encode()
        XCTAssertTrue(
            encoded.range(of: jpeg) != nil,
            "the payload did not survive encoding intact"
        )
    }

    func testTheAdvertisedContentTypeCarriesTheSameBoundaryAsTheBody() {
        var form = MultipartFormData(boundary: boundary)
        form.appendField(name: "email", value: "persona@ejemplo.com")

        XCTAssertEqual(form.contentType, "multipart/form-data; boundary=\(boundary)")
        XCTAssertTrue(
            String(decoding: form.encode(), as: UTF8.self).contains("--\(boundary)\r\n")
        )
    }

    /// The boundary must not be able to occur inside a JPEG, so it is random —
    /// and it must stay inside RFC 2046's `bchars` and under 70 characters, or it
    /// would need quoting in the header and the two could drift apart.
    func testGeneratedBoundariesAreUniqueAndHeaderSafe() {
        let allowed = CharacterSet(
            charactersIn:
                "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'()+_,-./:=? "
        )
        var seen = Set<String>()
        for _ in 0..<100 {
            let generated = FaceCheckAPIClient.makeBoundary()
            XCTAssertTrue(seen.insert(generated).inserted, "boundary repeated: \(generated)")
            XCTAssertLessThanOrEqual(generated.count, 70)
            XCTAssertTrue(
                generated.unicodeScalars.allSatisfy(allowed.contains),
                "boundary is not bchars-safe: \(generated)"
            )
        }
    }
}
