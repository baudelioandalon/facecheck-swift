import CryptoKit
import Foundation
import Security

/// Validates and generates opaque IDs for biometric records.
public enum FaceCheckSubjectId {

    private static let validPattern = try! NSRegularExpression(
        pattern: "^[A-Za-z][A-Za-z0-9_-]{7,127}$"
    )
    private static let base32Alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)

    /// Generates an opaque subject ID scoped by a non-secret fingerprint of the
    /// API key and 128 bits from the system cryptographic random source.
    public static func generate(apiKey: String) throws -> String {
        let fingerprint = String(base32(Array(SHA256.hash(data: Data(apiKey.utf8)))).prefix(10))
        let randomByteCount = 16
        var random = [UInt8](repeating: 0, count: randomByteCount)
        let status = random.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, randomByteCount, $0.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw FaceCheckError(
                code: .unknown,
                message: "No se pudo generar un ID de persona seguro. Intenta de nuevo."
            )
        }
        let suffix = Data(random)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "sub_\(fingerprint)_\(suffix)"
    }

    static func validate(_ subjectId: String) throws {
        guard !subjectId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FaceCheckError(code: .missingSubjectId)
        }
        let range = NSRange(subjectId.startIndex..., in: subjectId)
        guard validPattern.firstMatch(in: subjectId, range: range) != nil else {
            throw FaceCheckError(code: .invalidSubjectId)
        }
    }

    private static func base32(_ bytes: [UInt8]) -> String {
        var encoded = ""
        encoded.reserveCapacity((bytes.count * 8 + 4) / 5)
        var buffer = 0
        var availableBits = 0

        for byte in bytes {
            buffer = (buffer << 8) | Int(byte)
            availableBits += 8
            while availableBits >= 5 {
                availableBits -= 5
                encoded.unicodeScalars.append(
                    UnicodeScalar(base32Alphabet[(buffer >> availableBits) & 0x1F])
                )
            }
        }
        if availableBits > 0 {
            encoded.unicodeScalars.append(UnicodeScalar(base32Alphabet[(buffer << (5 - availableBits)) & 0x1F]))
        }
        return encoded
    }
}
