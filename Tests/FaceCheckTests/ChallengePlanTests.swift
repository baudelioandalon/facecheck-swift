import XCTest

@testable import FaceCheck

/// Port of the Kotlin `ChallengePlanTest`.
final class ChallengePlanTests: XCTestCase {

    func testNeverRepeatsAChallengeBackToBack() throws {
        // A repeat would read as "do the same thing twice" and users stop early.
        for seed in 0..<200 {
            var generator = SeededGenerator(seed: UInt64(seed))
            let plan = try ChallengePlan.random(
                count: ChallengePlan.maxChallenges,
                using: &generator
            )
            for (a, b) in zip(plan, plan.dropFirst()) {
                XCTAssertNotEqual(a, b, "seed \(seed) produced \(plan)")
            }
        }
    }

    func testAlwaysOpensWithATurn() throws {
        // Center immediately after positioning is satisfied by the pose the user
        // already had to hold, so leading with it would ask for nothing.
        for seed in 0..<100 {
            var generator = SeededGenerator(seed: UInt64(seed))
            let first = try XCTUnwrap(
                ChallengePlan.random(count: 3, using: &generator).first
            )
            XCTAssertTrue(
                first == .turnLeft || first == .turnRight,
                "expected a turn first, got \(first)"
            )
        }
    }

    func testProducesExactlyTheRequestedNumber() throws {
        for count in ChallengePlan.minChallenges...ChallengePlan.maxChallenges {
            var generator = SeededGenerator(seed: UInt64(count))
            XCTAssertEqual(try ChallengePlan.random(count: count, using: &generator).count, count)
        }
    }

    func testRejectsCountsOutsideTheSupportedRange() {
        assertThrowsFaceCheckError(try ChallengePlan.random(count: 0), code: .invalidConfig)
        assertThrowsFaceCheckError(
            try ChallengePlan.random(count: ChallengePlan.maxChallenges + 1),
            code: .invalidConfig
        )
    }

    func testASeededPlanIsReproducible() throws {
        var first = SeededGenerator(seed: 42)
        var second = SeededGenerator(seed: 42)
        XCTAssertEqual(
            try ChallengePlan.random(count: 4, using: &first),
            try ChallengePlan.random(count: 4, using: &second)
        )
    }

    /// Two different seeds must be able to disagree, or the "random" plan is a
    /// constant and the whole type is decoration.
    func testDifferentSeedsCanProduceDifferentPlans() throws {
        var plans = Set<[Challenge]>()
        for seed in 0..<50 {
            var generator = SeededGenerator(seed: UInt64(seed))
            plans.insert(try ChallengePlan.random(count: 4, using: &generator))
        }
        XCTAssertGreaterThan(plans.count, 1, "every seed produced the same plan")
    }

    func testEveryChallengeCarriesASpanishInstructionAndAStableID() {
        for challenge in Challenge.allCases {
            XCTAssertFalse(challenge.instructionEs.trimmingCharacters(in: .whitespaces).isEmpty)
            XCTAssertFalse(challenge.id.isEmpty)
            // Kotlin's `Challenge.fromId(_:)` is `Challenge(rawValue:)` here.
            XCTAssertEqual(Challenge(rawValue: challenge.id), challenge)
        }
        // The declared order is load bearing: `ChallengePlan` draws from a
        // filtered view of `allCases`, so reordering the cases changes which plan
        // a given generator produces.
        XCTAssertEqual(Challenge.allCases, [.turnLeft, .turnRight, .center])
    }

    func testChallengeInstructionsAreInSpanish() {
        XCTAssertEqual(Challenge.turnLeft.instructionEs, "Gira la cabeza a la izquierda")
        XCTAssertEqual(Challenge.turnRight.instructionEs, "Gira la cabeza a la derecha")
        XCTAssertEqual(Challenge.center.instructionEs, "Mira de frente a la cámara")
    }
}

/// Port of the Kotlin `LivenessConfigTest`.
///
/// Kotlin used `require`, whose `IllegalArgumentException` the tests assert on. A
/// Swift `precondition` would trap and no XCTest could catch it, so the port
/// throws ``FaceCheckError`` instead and these assert on that.
final class LivenessConfigTests: XCTestCase {

    func testRejectsATurnThresholdInsideTheCenterTolerance() {
        // Otherwise "turned" and "facing forward" are the same pose and every
        // challenge completes itself on the first frame.
        assertThrowsFaceCheckError(
            try LivenessConfig(turnThresholdDeg: 8, centerToleranceDeg: 10),
            code: .invalidConfig
        )
    }

    func testRejectsAFaceRatioWindowThatCannotBeSatisfied() {
        assertThrowsFaceCheckError(
            try LivenessConfig(minFaceRatio: 0.6, maxFaceRatio: 0.5),
            code: .invalidConfig
        )
    }

    func testRejectsAPositioningTimeoutShorterThanItsOwnHold() {
        assertThrowsFaceCheckError(
            try LivenessConfig(positioningHoldMs: 5_000, positioningTimeoutMs: 1_000),
            code: .invalidConfig
        )
    }

    /// ``LivenessConfig/default`` skips validation by construction, so something
    /// has to prove those literals actually satisfy the invariants.
    func testTheShippedDefaultsSatisfyEveryInvariant() throws {
        let validated = try LivenessConfig()
        XCTAssertEqual(validated, LivenessConfig.default)
    }
}
