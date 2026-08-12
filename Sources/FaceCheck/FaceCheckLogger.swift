import Foundation
import os

/// Severity, ordered so a **smaller** raw value is more severe.
///
/// The explicit 0...4 raw values freeze that order, so reordering the cases
/// cannot silently change what gets emitted. ``none`` sits at 0 and would
/// therefore rank as "more severe than error" by number alone, which is why the
/// level gate tests it for equality separately — that guard is what produces
/// total silence by default.
public enum FaceCheckLogLevel: Int, Sendable, Comparable, CaseIterable {
    case none = 0
    case error = 1
    case warn = 2
    case info = 3
    case debug = 4

    /// Upper-case, because the default sink's line format uses it and both
    /// platform SDKs must produce identical text.
    public var name: String {
        switch self {
        case .none: return "NONE"
        case .error: return "ERROR"
        case .warn: return "WARN"
        case .info: return "INFO"
        case .debug: return "DEBUG"
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Where log lines go. Implement to bridge into the host app's own logger.
///
/// A named struct rather than a closure typealias: the single-argument `init`
/// keeps the Kotlin call site (`FaceCheckLogSink { level, message in … }`)
/// compiling as a trailing closure, and unlike a typealias it can grow members
/// later without breaking source.
///
/// The closure is `@Sendable` because a sink crosses isolation domains — it is
/// installed at startup and invoked from the camera analysis queue.
///
/// The message it receives is **already redacted**. A sink cannot opt out.
public struct FaceCheckLogSink: Sendable {

    private let _write: @Sendable (FaceCheckLogLevel, String) -> Void

    public init(_ write: @escaping @Sendable (FaceCheckLogLevel, String) -> Void) {
        _write = write
    }

    public func write(_ level: FaceCheckLogLevel, _ message: String) {
        _write(level, message)
    }

    /// The default: Apple's unified log.
    ///
    /// Interpolated with `privacy: .public` because the message arrives already
    /// redacted, and os_log's default of `.private` would render `<private>` and
    /// make the diagnostics useless.
    ///
    /// The line format matches the Kotlin SDK exactly — `[FaceCheck/ERROR] mensaje`
    /// — so cross-platform logs read the same.
    public static let osLog = FaceCheckLogSink { level, message in
        let logger = Logger(subsystem: "com.borealnetwork.facecheck", category: "FaceCheck")
        let line = "[FaceCheck/\(level.name)] \(message)"
        switch level {
        case .error: logger.error("\(line, privacy: .public)")
        case .warn: logger.log(level: .default, "\(line, privacy: .public)")
        case .info: logger.info("\(line, privacy: .public)")
        case .debug: logger.debug("\(line, privacy: .public)")
        case .none: break
        }
    }

    /// Drops everything. Useful in tests that assert nothing is emitted.
    public static let silent = FaceCheckLogSink { _, _ in }
}

/// Opt-in diagnostics for integrators.
///
/// Off by default, and **structurally incapable of leaking the two things that
/// matter**: the API key and image bytes.
///
/// That is not a convention to be careful about, it is enforced by the shape of
/// the API. Every message goes through ``LogRedactor`` before it reaches a sink,
/// so a key pasted into a log line by accident — including one inside a URL, an
/// exception message, or a response body echoed back by a proxy — comes out
/// masked. And nothing here accepts `Data`: to mention a photo at all you have
/// to call ``describeBytes(_:)``, which reports a size and nothing else. A
/// biometric SDK that printed a selfie into the system log would be handing the
/// user's face to every other app that can read it.
///
/// A caseless `enum` rather than a class with a `shared`: it is a pure
/// namespace, and it cannot accidentally grow an instance API. Storage sits in a
/// lock rather than an actor so ``level`` and ``sink`` stay synchronous — they
/// are read from the camera analysis queue, and an actor hop per log line would
/// be absurd.
public enum FaceCheckLogger {

    /// Nothing less severe than this is emitted. ``FaceCheckLogLevel/none``
    /// silences everything.
    public static var level: FaceCheckLogLevel {
        get { settings.value.level }
        set { settings.withLock { $0.level = newValue } }
    }

    /// Where lines go. Defaults to ``FaceCheckLogSink/osLog``.
    public static var sink: FaceCheckLogSink {
        get { settings.value.sink }
        set { settings.withLock { $0.sink = newValue } }
    }

    public static func error(_ message: @autoclosure () -> String) {
        log(.error, message())
    }

    public static func warn(_ message: @autoclosure () -> String) {
        log(.warn, message())
    }

    public static func info(_ message: @autoclosure () -> String) {
        log(.info, message())
    }

    public static func debug(_ message: @autoclosure () -> String) {
        log(.debug, message())
    }

    /// The only way to mention image data in a log line.
    ///
    /// Returns a size, never content, and plainly: no thousands separators, no
    /// locale formatting. Deliberately the sole function that touches a byte
    /// count, so "log the selfie" is not something a caller can express. **Do not
    /// add an overload taking `Data`** — that would destroy exactly this property.
    public static func describeBytes(_ size: Int) -> String {
        "<\(size) bytes>"
    }

    /// The gate, and the single choke point where redaction happens.
    ///
    /// Emits if and only if `level != .none && at <= level`, which is Kotlin's
    /// `at.ordinal > level.ordinal || level == NONE` inverted. With `.warn` set,
    /// exactly `.error` and `.warn` come out.
    ///
    /// **A suppressed message is never built.** The parameter is a non-escaping
    /// `@autoclosure` and the level gate runs *before* it is invoked, so
    /// assembling a debug string costs nothing in production; there is a test
    /// that counts invocations and expects zero. It is not marked `@Sendable`:
    /// it is evaluated synchronously in the same isolation domain, and requiring
    /// Sendable would break interpolating non-Sendable values.
    ///
    /// One snapshot of settings per call, so a concurrent sink change cannot
    /// send a line to the old sink under the new level.
    private static func log(_ at: FaceCheckLogLevel, _ message: @autoclosure () -> String) {
        let current = settings.value
        // `.none` sits at raw value 0 and would therefore pass an `at <= level`
        // test against `.error`; the explicit equality check is what makes the
        // default total silence rather than errors-only.
        guard current.level != .none, at <= current.level else { return }
        current.sink.write(at, LogRedactor.redact(message()))
    }

    private struct Settings: Sendable {
        var level: FaceCheckLogLevel
        var sink: FaceCheckLogSink
    }

    private static let settings = LockedBox(Settings(level: .none, sink: .osLog))
}

/// Masks API keys and email local parts anywhere in a string.
///
/// Applied to **every** line at the one choke point inside
/// ``FaceCheckLogger``, never at call sites, because the leak that actually
/// happens is the one nobody wrote on purpose: a server error echoed verbatim,
/// an exception whose message contains the request URL, a header dump added
/// during a debugging session and never removed.
///
/// ### The rules, which tests depend on
///
/// Changing any of them is a security regression, not a refactor.
///
/// **Order: keys first, then emails. Not interchangeable.** For
/// `"lk_test_abc@gmail.com"`, keys-first gives `"lk_test_***@gmail.com"` (the key
/// pattern stops at `@`, and the email pattern then fails to match because `*` is
/// not in the local-part class). Emails-first would give `"l***@gmail.com"`,
/// which hides the fact that there was a key there at all.
///
/// 1. **Keys** — `lk_(test|live)_[A-Za-z0-9_\-]+`, replaced with
///    `"lk_" + group 1 + "_***"`. Keeps the marker and the mode, eats the whole
///    secret tail; the `+` is greedy, so `lk_live_abc123XYZ_-456` goes entirely.
///    A bare `"lk_test_"` does not match, and there is nothing to leak there.
///    Expected: `"keys: lk_test_*** and lk_live_***"`.
/// 2. **Emails** — everything up to an `@` and everything after it, both
///    delimited by what an address *cannot* contain, replaced with the **first
///    character** of group 1, then `"***"`, then `"@"` and the whole of group 2.
///    The domain is kept because it helps support; the identity goes.
///    `persona.ejemplo@gmail.com` → `p***@gmail.com`. Both classes are greedy
///    within their own limits, so in `"foo bar baz@x.com"` only `baz` is masked.
///
///    The classes are **negated, not allow-lists**, and that is the whole point:
///    the Kotlin original allow-listed `[A-Za-z0-9._%+\-]`, which in this SDK's
///    own market masks almost nothing — `maría@hotmail.com` came out as
///    `maría***@hotmail.com` (the class matched only the last ASCII character
///    before the `@`) and `josé.garcía@gmail.com` survived whole. The domain is
///    likewise no longer required to carry a dotted TLD, so `usuario@localhost`
///    is masked too. This is a deliberate **divergence from the Kotlin SDK**,
///    which has the same hole and should get the same patch; parity is not worth
///    logging users' addresses in clear.
///
///    `*` is excluded from the local-part class, and that exclusion is what
///    keeps rule 1 ahead of rule 2: without it the already-masked
///    `lk_test_***@gmail.com` would match as an address and collapse to
///    `l***@gmail.com`, destroying the evidence that a key was there.
/// 3. The mask is the constant `"***"` in both cases.
///
/// ### Implementation notes
///
/// `NSRegularExpression`, because Swift's `Regex` is iOS 16 and the floor is 15.
/// The key case can use the template `"lk_$1_***"`; the email case **cannot**,
/// since no template can take the first character of a group — so walk
/// `matches(in:)` in **reverse** order and substitute each range, keeping the
/// later ranges valid while the string mutates. Convert ranges with
/// `NSRange(text.startIndex..., in: text)` and `Range(match.range(at:), in: text)`
/// rather than integer arithmetic, or one emoji in the message shifts every index.
enum LogRedactor {

    static func redact(_ raw: String) -> String {
        maskEmails(maskAPIKeys(raw))
    }

    /// A template suffices here: the replacement keeps group 1 whole.
    private static func maskAPIKeys(_ text: String) -> String {
        apiKeyPattern.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: "lk_$1_" + mask
        )
    }

    /// A template cannot express "the first character of group 1", so the
    /// substitution is done by hand.
    ///
    /// Walked in **reverse** so each replacement only ever touches text that
    /// comes after the ranges still to be used, which keeps their UTF-16 offsets
    /// valid. Every offset is converted with `Range(_:in:)` against the string
    /// being mutated rather than by integer arithmetic — one emoji earlier in the
    /// line would otherwise shift the mask onto the wrong characters.
    private static func maskEmails(_ text: String) -> String {
        var result = text
        let matches = emailPattern.matches(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        )
        for match in matches.reversed() {
            guard let whole = Range(match.range, in: result),
                  let localRange = Range(match.range(at: 1), in: result),
                  let domainRange = Range(match.range(at: 2), in: result),
                  let initial = result[localRange].first
            else { continue }
            // Built before the mutation: reading `result` inside the argument of
            // a mutating call on `result` is an overlapping access.
            let replacement = "\(initial)\(mask)@\(result[domainRange])"
            result.replaceSubrange(whole, with: replacement)
        }
        return result
    }

    /// `lk_test_…` / `lk_live_…` — the two prefixes the backend accepts.
    /// Compiled once; `NSRegularExpression` is immutable and thread-safe.
    static let apiKeyPattern = try! NSRegularExpression(
        pattern: #"lk_(test|live)_[A-Za-z0-9_\-]+"#
    )

    /// Keeps the domain, which is useful for support, and drops the identity.
    ///
    /// Defined by what an address cannot contain rather than by what it can, so
    /// `maría`, `nuñez.peña` and any other non-ASCII local part are masked in
    /// full. `*` is the one printable exclusion: it is what makes an
    /// already-masked API key fail to match here. See the type's doc comment.
    static let emailPattern = try! NSRegularExpression(
        pattern: #"([^\s@,;:<>()\[\]\\"*]+)@([^\s@,;:<>()\[\]\\"*]+)"#
    )

    static let mask = "***"
}
