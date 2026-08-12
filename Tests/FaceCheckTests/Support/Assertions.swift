import XCTest

@testable import FaceCheck

/// Kotlin's `assertFailsWith<FaceCheckException> { … }`, which returns the
/// exception so the test can go on to assert on its `code`.
///
/// Returns nil after failing the test rather than throwing, so a caller can write
/// `guard let failure = … else { return }` without a second layer of `try`.
@discardableResult
func assertThrowsFaceCheckError<T>(
    _ expression: @autoclosure () throws -> T,
    code expected: FaceCheckErrorCode? = nil,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) -> FaceCheckError? {
    do {
        let value = try expression()
        XCTFail(
            "expected a FaceCheckError, got \(value). \(message())",
            file: file,
            line: line
        )
        return nil
    } catch let error as FaceCheckError {
        if let expected {
            XCTAssertEqual(error.code, expected, message(), file: file, line: line)
        }
        return error
    } catch {
        XCTFail("expected a FaceCheckError, got \(error). \(message())", file: file, line: line)
        return nil
    }
}

/// The `async` twin. Separate rather than overloaded, because an `@autoclosure`
/// cannot be `async` and overload resolution on the closure's effects is exactly
/// the kind of ambiguity that produces an unreadable diagnostic.
@discardableResult
func assertThrowsFaceCheckError<T>(
    code expected: FaceCheckErrorCode? = nil,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ expression: () async throws -> T
) async -> FaceCheckError? {
    do {
        let value = try await expression()
        XCTFail(
            "expected a FaceCheckError, got \(value). \(message())",
            file: file,
            line: line
        )
        return nil
    } catch let error as FaceCheckError {
        if let expected {
            XCTAssertEqual(error.code, expected, message(), file: file, line: line)
        }
        return error
    } catch {
        XCTFail("expected a FaceCheckError, got \(error). \(message())", file: file, line: line)
        return nil
    }
}
