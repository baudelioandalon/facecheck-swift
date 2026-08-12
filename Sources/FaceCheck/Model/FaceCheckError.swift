import Foundation

/// Wire codes from the backend's `{"error":{"code","message"}}` envelope, plus
/// the codes the SDK raises on its own before a request is ever sent.
///
/// Keep in sync with the backend's error table, published at
/// <https://facecheck.borealnetwork.org/docs/errores>. ``unknown`` exists so a
/// code added to the backend after an app shipped degrades to a generic message
/// instead of crashing the parse — there is no update path for an SDK that
/// already lives on someone's phone.
///
/// This conforms to `Error` so trivial internal paths can throw a bare code, but
/// the **public surface always throws ``FaceCheckError``**. The integrator idiom
/// is `catch let error as FaceCheckError` and then `switch error.code`; do not
/// write a catch clause for this enum.
///
/// Deliberately **not** `Codable`: the `Decodable` synthesised for a
/// `RawRepresentable` throws on an unrecognised value, which destroys the whole
/// point of ``unknown``. Decode through ``fromWire(_:)`` instead.
public enum FaceCheckErrorCode: String, Error, Sendable, CaseIterable, Hashable {

    // MARK: Authentication and tenancy

    case missingApiKey = "MISSING_API_KEY"
    case invalidApiKey = "INVALID_API_KEY"
    case appDisabled = "APP_DISABLED"
    case keyServiceUnavailable = "KEY_SERVICE_UNAVAILABLE"

    // MARK: Request shape

    case missingEmail = "MISSING_EMAIL"
    case invalidEmail = "INVALID_EMAIL"
    case missingFile = "MISSING_FILE"
    case emptyFile = "EMPTY_FILE"
    case invalidImage = "INVALID_IMAGE"
    case imageTooLarge = "IMAGE_TOO_LARGE"
    case requestTooLarge = "REQUEST_TOO_LARGE"
    case unsupportedMediaType = "UNSUPPORTED_MEDIA_TYPE"
    case invalidCompareWith = "INVALID_COMPARE_WITH"
    case invalidFlag = "INVALID_FLAG"
    case methodNotAllowed = "METHOD_NOT_ALLOWED"

    // MARK: Face pipeline

    case noFace = "NO_FACE"
    case noFaceInIne = "NO_FACE_IN_INE"

    // MARK: Subject lifecycle

    case notEnrolled = "NOT_ENROLLED"
    case subjectAlreadyEnrolled = "SUBJECT_ALREADY_ENROLLED"
    case reenrollmentFaceMismatch = "REENROLLMENT_FACE_MISMATCH"

    // MARK: Enrollment grants

    case enrollmentGrantRequired = "ENROLLMENT_GRANT_REQUIRED"
    case enrollmentGrantInvalid = "ENROLLMENT_GRANT_INVALID"
    case modelVersionMismatch = "MODEL_VERSION_MISMATCH"
    case enrollmentIncomplete = "ENROLLMENT_INCOMPLETE"
    case ineNotEnrolled = "INE_NOT_ENROLLED"

    // MARK: Limits

    case quotaExceeded = "QUOTA_EXCEEDED"
    case rateLimited = "RATE_LIMITED"

    // MARK: Server

    case encodeFailed = "ENCODE_FAILED"

    /// `INTERNAL` on the wire. Renamed because `internal` is a Swift keyword;
    /// the raw value is untouched, and that is what any comparison must use.
    case internalError = "INTERNAL"

    // MARK: Raised by the SDK, never by the backend

    case notInitialized = "NOT_INITIALIZED"
    case invalidConfig = "INVALID_CONFIG"
    case networkError = "NETWORK_ERROR"
    case timeout = "TIMEOUT"
    case invalidResponse = "INVALID_RESPONSE"
    case livenessFailed = "LIVENESS_FAILED"
    case cameraUnavailable = "CAMERA_UNAVAILABLE"
    case cancelled = "CANCELLED"
    case unknown = "UNKNOWN"

    /// Spanish prose safe to show the end user, used when the backend did not
    /// send a message of its own.
    ///
    /// Exhaustive with no `default:` on purpose, so a code added to the enum
    /// fails the build instead of silently degrading to a generic string.
    public var messageEs: String {
        switch self {
        case .missingApiKey:
            return "Falta la llave de API. Revisa la configuración del SDK."
        case .invalidApiKey:
            return "La llave de API no es válida o fue revocada. Genera una nueva en el portal."
        case .appDisabled:
            return "Esta aplicación está suspendida. Contacta al administrador de la cuenta."
        case .keyServiceUnavailable:
            return "El servicio de verificación de llaves no está disponible. Intenta de nuevo."
        case .missingEmail:
            return "Falta el correo electrónico."
        case .invalidEmail:
            return "El correo electrónico no tiene un formato válido."
        case .missingFile:
            return "No se envió la imagen requerida. Vuelve a intentarlo."
        case .emptyFile:
            return "La imagen llegó vacía. Vuelve a tomar la foto."
        case .invalidImage:
            return "No se pudo leer la imagen. Vuelve a tomar la foto."
        case .imageTooLarge:
            return "La imagen es demasiado grande. Reduce la resolución."
        case .requestTooLarge:
            return "La petición es demasiado grande."
        case .unsupportedMediaType:
            return "Formato de imagen no soportado. Usa JPEG, PNG o WebP."
        case .invalidCompareWith:
            return "El parámetro de comparación no es válido."
        case .invalidFlag:
            return "Un parámetro de la petición no es válido."
        case .methodNotAllowed:
            return "Método HTTP no permitido."
        case .noFace:
            return "No se detectó ningún rostro. Acércate a la cámara, con buena luz y sin nada "
                + "que te cubra la cara."
        case .noFaceInIne:
            return "No se detectó el rostro en la identificación. Tómala de frente, sin reflejos y "
                + "con la credencial completa."
        case .notEnrolled:
            return "Este correo no tiene un registro facial. Regístralo antes de verificar."
        case .subjectAlreadyEnrolled:
            return "Ese correo ya está enrolado. Para reemplazar la foto de referencia usa "
                + "overwrite = true con una selfie de la persona ya registrada."
        case .reenrollmentFaceMismatch:
            return "La selfie no coincide con el registro facial actual de ese correo."
        case .enrollmentGrantRequired:
            // Adapted from the Kotlin text, which cites `enroll(grant = ...)`.
            // This string is only ever shown when the backend sent no message of
            // its own, and its whole job is to point a developer at the call
            // they got wrong — so it names the Swift call, not the Kotlin one.
            return "Falta el grant de enrolamiento. Tu backend debe firmarlo y pasarlo a "
                + "enroll(grant:). Consulta https://facecheck.borealnetwork.org/docs/grants."
        case .enrollmentGrantInvalid:
            return "El grant de enrolamiento no es válido: revisa la firma, el correo, el "
                + "modo (test/live), su vigencia, y que no se haya usado antes."
        case .modelVersionMismatch:
            return "El registro facial se creó con una versión anterior del modelo. Vuelve a "
                + "registrar a esta persona."
        case .enrollmentIncomplete:
            return "El registro facial está incompleto. Vuelve a registrar a esta persona."
        case .ineNotEnrolled:
            return "Esta persona no tiene una identificación registrada."
        case .quotaExceeded:
            return "Se agotó la cuota mensual del plan. Actualízalo desde el portal."
        case .rateLimited:
            return "Demasiados intentos fallidos. Espera unos minutos e intenta de nuevo."
        case .encodeFailed:
            return "No se pudo procesar la imagen."
        case .internalError:
            return "Ocurrió un error inesperado. Intenta de nuevo."
        case .notInitialized:
            return "FaceCheck no está inicializado. Llama a FaceCheck.initialize() primero."
        case .invalidConfig:
            return "La configuración de FaceCheck no es válida."
        case .networkError:
            return "No hay conexión con el servidor. Revisa tu internet e intenta de nuevo."
        case .timeout:
            return "La operación tardó demasiado. Intenta de nuevo."
        case .invalidResponse:
            return "El servidor devolvió una respuesta que el SDK no pudo leer."
        case .livenessFailed:
            return "No se pudo completar la prueba de vida. Intenta de nuevo."
        case .cameraUnavailable:
            return "No se pudo usar la cámara. Revisa los permisos de la aplicación."
        case .cancelled:
            return "La verificación fue cancelada."
        case .unknown:
            return "Ocurrió un error inesperado. Intenta de nuevo."
        }
    }

    /// Whether retrying the exact same request could plausibly succeed.
    ///
    /// False for anything the caller has to fix first (a bad key, an unenrolled
    /// email, a face that does not match), true for transport failures and
    /// server faults. ``rateLimited`` is retryable, but only after
    /// ``FaceCheckError/retryAfterSeconds``.
    public var isRetryable: Bool {
        switch self {
        case .keyServiceUnavailable, .rateLimited, .encodeFailed, .internalError,
             .networkError, .timeout, .invalidResponse:
            return true
        default:
            return false
        }
    }

    private static let byWire: [String: FaceCheckErrorCode] =
        Dictionary(uniqueKeysWithValues: allCases.map { ($0.rawValue, $0) })

    /// Maps a backend `error.code` onto the enum, degrading to ``unknown``.
    ///
    /// Normalises with trim plus `uppercased()`, so `"not_enrolled"` and
    /// `" NOT_ENROLLED "` resolve the same. Never `localizedUppercase`: the
    /// Turkish dotless-i would turn `LIVENESS_FAILED` into a key that is not in
    /// the table. Never throws.
    public static func fromWire(_ wire: String?) -> FaceCheckErrorCode {
        guard let wire else { return .unknown }
        return byWire[wire.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()] ?? .unknown
    }
}

/// Every failure the SDK surfaces, from a rejected API key to a liveness session
/// the user abandoned.
///
/// ``code`` is the stable machine-readable identifier an integrator branches on;
/// ``message`` is Spanish prose that can be shown to the end user verbatim. When
/// the failure came from the backend the message is the backend's own — it knows
/// more about the specific rejection than the enum does — and falls back to
/// ``FaceCheckErrorCode/messageEs`` otherwise.
///
/// Conforms to `LocalizedError` so `localizedDescription` yields that Spanish
/// prose. Without it iOS substitutes "The operation couldn't be completed" and
/// the message the backend wrote for the end user is lost.
public struct FaceCheckError: Error, Sendable, Equatable, LocalizedError, CustomStringConvertible {

    public let code: FaceCheckErrorCode

    /// Spanish prose, ready to show the end user as-is.
    public let message: String

    /// The real HTTP status, or nil for failures the SDK raised before sending.
    public let httpStatus: Int?

    public let details: [String: String]

    /// The underlying failure, where there was one — Kotlin's `cause`.
    ///
    /// Excluded from `==`: two errors describing the same rejection are the same
    /// error regardless of which transport object happened to produce them.
    public let underlying: (any Error)?

    /// The `message` default lives here rather than on the property so it can
    /// fall back to `code.messageEs`, matching Kotlin's `message: String = code.messageEs`.
    public init(
        code: FaceCheckErrorCode,
        message: String? = nil,
        httpStatus: Int? = nil,
        details: [String: String] = [:],
        underlying: (any Error)? = nil
    ) {
        self.code = code
        self.message = message.flatMap { $0.isEmpty ? nil : $0 } ?? code.messageEs
        self.httpStatus = httpStatus
        self.details = details
        self.underlying = underlying
    }

    public var isRetryable: Bool { code.isRetryable }

    /// Seconds the backend asked the caller to wait, when it said so.
    public var retryAfterSeconds: Int? {
        details["retryAfterSeconds"].flatMap(Int.init)
    }

    /// When the subject's lockout expires, when the backend reported one.
    ///
    /// Parsed rather than passed through as a string so a caller can render a
    /// countdown without reimplementing ISO-8601. Returns nil on an unparseable
    /// value instead of throwing: a malformed timestamp in an error response
    /// must not replace the error the caller actually needs to see.
    ///
    /// `Date.ISO8601FormatStyle` is a Sendable value type, unlike
    /// `ISO8601DateFormatter`. Do not add `.iso8601.time(includingFractionalSeconds: true)`
    /// as a fallback — it returns nil for every format the backend emits.
    public var lockedUntil: Date? {
        details["lockedUntil"].flatMap { try? Date($0, strategy: .iso8601) }
    }

    /// Kotlin prints `FaceCheckException(NOT_ENROLLED): …`. Interpolating the
    /// case directly would print `notEnrolled`, so this uses the raw value,
    /// which is identical to the Kotlin enum's `name`.
    public var description: String {
        "FaceCheckError(\(code.rawValue)): \(message)"
    }

    public var errorDescription: String? { message }

    public static func == (lhs: FaceCheckError, rhs: FaceCheckError) -> Bool {
        lhs.code == rhs.code
            && lhs.message == rhs.message
            && lhs.httpStatus == rhs.httpStatus
            && lhs.details == rhs.details
    }
}
