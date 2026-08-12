import Foundation

/// Builds a `multipart/form-data` body byte for byte.
///
/// The layout, with CRLF spelled out because getting it wrong is where the bugs
/// in this file live:
///
/// ```text
/// per part:
///     "--" + boundary + CRLF
///     "Content-Disposition: form-data; name=\"<name>\"" [+ "; filename=\"<filename>\""] + CRLF
///     [ "Content-Type: image/jpeg" + CRLF ]     <- file parts only
///     CRLF                                      <- blank line separating headers from body
///     <raw value bytes>
///     CRLF                                      <- closes the part's body
/// close:
///     "--" + boundary + "--" + CRLF
/// ```
///
/// Mistakes each worth a test of its own: `\n` instead of `\r\n` (which is why
/// **no** part of this may be built from a Swift multi-line literal — those
/// produce `\n`); the blank line between headers and body; the CRLF after the
/// last part's payload and before the closing delimiter; the two trailing
/// hyphens on the close; a `filename` on a text part; a missing `filename` or
/// `Content-Type` on an image part; and running image bytes through `String`.
///
/// ``encode()`` is pure and deterministic given the boundary, which is what
/// makes a byte-exact golden test possible.
struct MultipartFormData: Sendable {

    let boundary: String

    private var parts: [Part] = []

    /// The header value that must accompany this body, byte-identical boundary
    /// included.
    var contentType: String {
        "multipart/form-data; boundary=\(boundary)"
    }

    init(boundary: String) {
        self.boundary = boundary
    }

    /// A text field. Never gets a `filename` and never gets a `Content-Type`.
    ///
    /// Werkzeug routes on the presence of a filename: a text field carrying one
    /// lands in `request.files` and vanishes from `request.form`, so the backend
    /// answers `MISSING_EMAIL` with the email sitting right there in the body.
    mutating func appendField(name: String, value: String) {
        parts.append(
            Part(
                name: name,
                filename: nil,
                contentType: nil,
                body: Data(value.utf8)
            )
        )
    }

    /// An image part. **Always** gets both a `filename` and a `Content-Type`.
    ///
    /// This is the most important comment in the file. `read_image_upload` in
    /// the backend treats any part without a filename as **absent**, and rejects
    /// with 415 any part whose declared type is not in its allow-list. An upload
    /// missing either one comes back as `MISSING_FILE` or
    /// `UNSUPPORTED_MEDIA_TYPE` with a perfectly valid image in the body.
    ///
    /// The filename is derived from the field name, so `selfie` becomes
    /// `selfie.jpg` and `ine` becomes `ine.jpg`.
    mutating func appendImage(name: String, bytes: Data) {
        parts.append(
            Part(
                name: name,
                filename: "\(name).jpg",
                contentType: "image/jpeg",
                body: bytes
            )
        )
    }

    /// Serialises the parts.
    ///
    /// Reserves the sum of the payload sizes plus header slack, so a 20 MB
    /// buffer is not grown by reallocation. Every string goes through
    /// `Data(_.utf8)`; ``crlf`` is a byte constant.
    ///
    /// `name` and `filename` are fixed ASCII in every current call, so no
    /// escaping or RFC 5987 encoding is implemented. If that ever changes, the
    /// Content-Disposition line is the one place to touch.
    func encode() -> Data {
        // Built once and reused for every part, so the delimiter in the body and
        // the one advertised in `contentType` cannot drift apart.
        let delimiter = Data("--\(boundary)".utf8)

        var body = Data()
        let payloadBytes = parts.reduce(0) { $0 + $1.body.count }
        body.reserveCapacity(
            payloadBytes
                + parts.count * (boundary.count + Self.headerSlackBytes)
                + boundary.count + Self.headerSlackBytes
        )

        for part in parts {
            body.append(delimiter)
            body.append(Self.crlf)

            // One header line: the filename is an attribute of the disposition,
            // not a header of its own. Both `name` and `filename` are quoted
            // because Werkzeug's parser reads the quoted form and a bare token
            // would end at the first special character if these ever stop being
            // fixed ASCII.
            var disposition = "Content-Disposition: form-data; name=\"\(part.name)\""
            if let filename = part.filename {
                disposition += "; filename=\"\(filename)\""
            }
            body.append(Data(disposition.utf8))
            body.append(Self.crlf)

            if let contentType = part.contentType {
                body.append(Data("Content-Type: \(contentType)".utf8))
                body.append(Self.crlf)
            }

            // The blank line. Without it the parser folds the headers into the
            // value and the field arrives as garbage rather than as an error.
            body.append(Self.crlf)

            // Raw, never through `String`: these are JPEG bytes and a round trip
            // through a String would corrupt anything that is not valid UTF-8.
            body.append(part.body)

            // Closes this part's body. Belongs to the delimiter that follows, so
            // it is emitted after the last part too — omitting it there is the
            // classic truncation bug.
            body.append(Self.crlf)
        }

        body.append(delimiter)
        body.append(Data("--".utf8))
        body.append(Self.crlf)
        return body
    }

    private struct Part: Sendable {
        let name: String
        let filename: String?
        let contentType: String?
        let body: Data
    }

    static let crlf = Data([0x0D, 0x0A])

    /// Rough per-part header cost, used only to size the reservation.
    static let headerSlackBytes = 200
}
