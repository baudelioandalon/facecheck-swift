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
}
