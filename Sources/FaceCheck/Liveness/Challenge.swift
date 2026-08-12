import Foundation

/// One action the user is asked to perform during a liveness session.
///
/// The set is deliberately tiny. Every extra challenge type is another way for a
/// real user to fail, and none of them are a security control on their own — see
/// the type documentation on ``ChallengeMachine``.
///
/// ``instructionEs`` is shown to the end user verbatim. The raw value is the
/// stable id used in logs and analytics and is never localised, which also makes
/// Kotlin's `Challenge.fromId(_:)` fall out as `Challenge(rawValue:)`.
public enum Challenge: String, CaseIterable, Sendable, Hashable {

    /// Turn the head to the user's own left, which is a **negative** yaw.
    ///
    /// See ``FaceFrame/yaw`` for the sign convention — getting it backwards is
    /// the single easiest way to ship an SDK that tells everyone to turn the
    /// wrong way and then fails them for complying.
    case turnLeft = "turn_left"

    /// Turn the head to the user's own right, which is a **positive** yaw.
    case turnRight = "turn_right"

    /// Hold a frontal pose. Used to bookend a sequence of turns.
    case center = "center"

    /// Stable identifier for logs and analytics. Never localised.
    public var id: String { rawValue }

    /// The instruction as the end user reads it. Spanish, imperative, short.
    public var instructionEs: String {
        switch self {
        case .turnLeft: return "Gira la cabeza a la izquierda"
        case .turnRight: return "Gira la cabeza a la derecha"
        case .center: return "Mira de frente a la cámara"
        }
    }

    // `allCases` replaces Kotlin's `Challenge.all`, and its order is load
    // bearing: ChallengePlan picks from a filtered view of this list, so
    // reordering the cases changes which plan a given generator produces.
    // The declared order is [turnLeft, turnRight, center].
}

/// Builds the sequence of challenges for one session.
///
/// Randomising the order raises the cost of a pre-recorded video only slightly —
/// an attacker who controls the device can read the plan out of memory before the
/// first frame is drawn. It is worth doing anyway because it defeats the lazy
/// attack (one recording replayed forever) at zero cost to the honest user, but
/// it must not be mistaken for the reason the system is safe.
public enum ChallengePlan {

    /// Bounds enforced on ``random(count:using:)``; also the range
    /// ``FaceCheckConfig`` accepts for `challengeCount`.
    public static let minChallenges = 1
    public static let maxChallenges = 5

    /// A plan of `count` challenges with no two identical in a row.
    ///
    /// The first challenge is always a turn: ``Challenge/center`` immediately
    /// after positioning is already satisfied by the pose the user had to hold
    /// to get there, so leading with it would ask for nothing.
    ///
    /// The generator is injected so tests get a fixed plan without reaching into
    /// internals. Swift's `RandomNumberGenerator` mutates, hence `inout`.
    ///
    /// - Throws: ``FaceCheckError`` with ``FaceCheckErrorCode/invalidConfig``
    ///   when `count` is outside ``minChallenges``...``maxChallenges``.
    public static func random(
        count: Int,
        using generator: inout some RandomNumberGenerator
    ) throws -> [Challenge] {
        guard (minChallenges...maxChallenges).contains(count) else {
            throw FaceCheckError(
                code: .invalidConfig,
                message: "count debe estar entre \(minChallenges) y \(maxChallenges), "
                    + "era \(count)."
            )
        }

        let turns: [Challenge] = [.turnLeft, .turnRight]
        var plan: [Challenge] = []
        plan.reserveCapacity(count)
        plan.append(turns[Int.random(in: 0..<turns.count, using: &generator)])

        // Excluding the previous entry is what guarantees no two identical
        // challenges in a row: a repeat reads as "do the same thing again" and
        // users stop early. With three challenges total there are always exactly
        // two candidates, so the draw can never run out.
        while plan.count < count {
            let previous = plan[plan.count - 1]
            let candidates = Challenge.allCases.filter { $0 != previous }
            plan.append(candidates[Int.random(in: 0..<candidates.count, using: &generator)])
        }
        return plan
    }

    /// A plan drawn from the system generator.
    public static func random(count: Int) throws -> [Challenge] {
        var generator = SystemRandomNumberGenerator()
        return try random(count: count, using: &generator)
    }
}
