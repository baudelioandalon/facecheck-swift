import XCTest

@testable import FaceCheck

final class SubjectIdTests: XCTestCase {

    func testGeneratorProducesContractShapeAndUniqueValues() throws {
        let first = try FaceCheckSubjectId.generate(apiKey: "lk_test_example")
        let second = try FaceCheckSubjectId.generate(apiKey: "lk_test_example")

        XCTAssertNotEqual(first, second)
        XCTAssertTrue(
            first.range(
                of: "^sub_[A-Z2-7]{10}_[A-Za-z0-9_-]{22}$",
                options: .regularExpression
            ) != nil
        )
    }

    func testValidatorRejectsSubjectIdWithTerminalLineFeed() {
        assertInvalidSubjectId("person_01\n")
    }

    func testValidatorRejectsSubjectIdWithTerminalCRLF() {
        assertInvalidSubjectId("person_01\r\n")
    }

    private func assertInvalidSubjectId(
        _ subjectId: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try FaceCheckSubjectId.validate(subjectId),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                (error as? FaceCheckError)?.code,
                .invalidSubjectId,
                file: file,
                line: line
            )
        }
    }
}
