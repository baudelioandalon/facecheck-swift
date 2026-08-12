import XCTest

@testable import FaceCheck

/// Port of the Kotlin `ChallengeMachineTest`.
///
/// The machine is pure and clock-free, so every one of these drives a full
/// session — twenty seconds of wall time, several times over — in microseconds.
final class ChallengeMachineTests: XCTestCase {

    private func machine(_ challenges: Challenge...) throws -> ChallengeMachine {
        try ChallengeMachine(challenges: challenges, config: testConfig)
    }

    // MARK: Happy paths

    func testCompletesATwoChallengeSession() throws {
        let machine = try machine(.turnLeft, .turnRight)

        let startedAt = machine.completePositioning()
        let afterLeft = machine.performTurn(from: startedAt, yawAtExtreme: -35)
        machine.performTurn(from: afterLeft, yawAtExtreme: 35)

        XCTAssertEqual(machine.state.value, .capturing)

        try machine.completeCapture()
        let evidence = try XCTUnwrap(machine.state.value.asDone)
        XCTAssertEqual(evidence.challenges.map(\.challenge), [.turnLeft, .turnRight])
    }

    func testIdleUntilTheFirstFrameThenPositioning() throws {
        let machine = try machine(.turnLeft)
        XCTAssertEqual(machine.state.value, .idle)

        machine.onFrame(frame(atMs: 0))

        let state = try XCTUnwrap(machine.state.value.asPositioning)
        XCTAssertEqual(state.hint, .ok)
    }

    func testPositioningRequiresThePoseToBeHeld() throws {
        let machine = try machine(.turnLeft)

        machine.onFrame(frame(atMs: 0))
        // One millisecond short of the hold, so nothing but time is missing.
        machine.onFrame(frame(atMs: testConfig.positioningHoldMs - 1))

        let state = try XCTUnwrap(machine.state.value.asPositioning)
        XCTAssertEqual(state.hint, .ok)
        XCTAssertGreaterThan(state.holdProgress, 0.9, "expected a near-complete hold")

        machine.onFrame(frame(atMs: testConfig.positioningHoldMs))
        XCTAssertNotNil(machine.state.value.asChallengeActive)
    }

    func testAHoldBrokenMidwayRestartsTheCountdown() throws {
        let machine = try machine(.turnLeft)

        machine.onFrame(frame(atMs: 0))
        // Looking away resets the run, so the original deadline no longer counts.
        machine.onFrame(frame(atMs: 400, yaw: 40))
        machine.onFrame(frame(atMs: 500))
        machine.onFrame(frame(atMs: 500 + testConfig.positioningHoldMs - 50))

        XCTAssertNotNil(machine.state.value.asPositioning)

        machine.onFrame(frame(atMs: 500 + testConfig.positioningHoldMs))
        XCTAssertNotNil(machine.state.value.asChallengeActive)
    }

    func testACenterChallengeNeedsASustainedFrontalHold() throws {
        let machine = try machine(.turnLeft, .center)
        let startedAt = machine.completePositioning()
        let afterLeft = machine.performTurn(from: startedAt, yawAtExtreme: -30)

        let active = try XCTUnwrap(machine.state.value.asChallengeActive)
        XCTAssertEqual(active.challenge, .center)

        machine.onFrame(frame(atMs: afterLeft + 100))
        machine.onFrame(frame(atMs: afterLeft + 100 + testConfig.centerHoldMs - 1))
        XCTAssertNotNil(machine.state.value.asChallengeActive)

        machine.onFrame(frame(atMs: afterLeft + 100 + testConfig.centerHoldMs))
        XCTAssertEqual(machine.state.value, .capturing)
    }

    // MARK: The turn is a movement, not a pose

    func testReachingTheAngleIsNotEnoughWithoutTheReturn() throws {
        let machine = try machine(.turnLeft)
        let startedAt = machine.completePositioning()

        machine.onFrame(frame(atMs: startedAt + 100, yaw: -40))
        var active = try XCTUnwrap(machine.state.value.asChallengeActive)
        XCTAssertEqual(active.phase, .returningToCenter)

        // Still turned: a photograph held at the right angle gets exactly this far.
        machine.onFrame(frame(atMs: startedAt + 200, yaw: -30))
        active = try XCTUnwrap(machine.state.value.asChallengeActive)
        XCTAssertEqual(active.phase, .returningToCenter)

        machine.onFrame(frame(atMs: startedAt + 300, yaw: -2))
        XCTAssertEqual(machine.state.value, .capturing)
    }

    func testATurnJustShortOfTheThresholdDoesNotCount() throws {
        let machine = try machine(.turnLeft)
        let startedAt = machine.completePositioning()

        machine.onFrame(
            frame(atMs: startedAt + 100, yaw: -(testConfig.turnThresholdDeg - 1))
        )

        let active = try XCTUnwrap(machine.state.value.asChallengeActive)
        XCTAssertEqual(active.phase, .awaitingAction)
    }

    func testTurningTheWrongWayNeitherCompletesNorPreCompletes() throws {
        let machine = try machine(.turnLeft, .turnRight)
        let startedAt = machine.completePositioning()

        // A full right turn while the left one was asked for.
        machine.onFrame(frame(atMs: startedAt + 100, yaw: 45))
        machine.onFrame(frame(atMs: startedAt + 200, yaw: 0))

        var active = try XCTUnwrap(machine.state.value.asChallengeActive)
        XCTAssertEqual(active.challenge, .turnLeft)
        XCTAssertEqual(active.index, 0)
        XCTAssertEqual(active.phase, .awaitingAction)

        // Now do the left turn properly. The right turn performed a moment ago
        // must not have been banked against the challenge that comes next.
        let afterLeft = machine.performTurn(from: startedAt + 200, yawAtExtreme: -35)
        active = try XCTUnwrap(machine.state.value.asChallengeActive)
        XCTAssertEqual(active.challenge, .turnRight)
        XCTAssertEqual(active.phase, .awaitingAction)

        machine.performTurn(from: afterLeft, yawAtExtreme: 35)
        XCTAssertEqual(machine.state.value, .capturing)
    }

    // MARK: Deadlines

    func testAChallengeThatIsNeverPerformedTimesOut() throws {
        let machine = try machine(.turnLeft)
        let startedAt = machine.completePositioning()

        // Frames keep arriving with a visible, centred face — the user simply is
        // not turning — so this can only be the challenge deadline, not face loss.
        var t = startedAt + 1_000
        while t <= startedAt + testConfig.challengeTimeoutMs + 1_000 {
            machine.onFrame(frame(atMs: t))
            t += 1_000
        }

        XCTAssertEqual(machine.state.value.asFailed, .timeout)
    }

    func testPositioningTimesOutOnItsOwnDeadline() throws {
        let machine = try machine(.turnLeft)
        machine.onFrame(frame(atMs: 0, faceRatio: 0.10))

        machine.onFrame(frame(atMs: testConfig.positioningTimeoutMs + 1, faceRatio: 0.10))

        XCTAssertEqual(machine.state.value.asFailed, .timeout)
    }

    func testOnTickExpiresASessionTheCameraStoppedFeeding() throws {
        let machine = try machine(.turnLeft)
        machine.onFrame(frame(atMs: 0))

        // No frames at all after this: without onTick the deadline would never be
        // observed, because the only clock is the frames that stopped arriving.
        machine.onTick(nowMs: testConfig.positioningTimeoutMs + 1)

        XCTAssertEqual(machine.state.value.asFailed, .timeout)
    }

    func testOnTickIsANoOpBeforeTheSessionStarts() throws {
        let machine = try machine(.turnLeft)

        machine.onTick(nowMs: 10_000_000)

        XCTAssertEqual(machine.state.value, .idle)
    }

    // MARK: The face itself

    func testAFaceThatDisappearsMidChallengeFailsTheSession() throws {
        let machine = try machine(.turnLeft)
        let startedAt = machine.completePositioning()

        machine.onFrame(frame(atMs: startedAt + 200, faceCount: 0))
        machine.onFrame(
            frame(atMs: startedAt + testConfig.faceLostGraceMs + 1, faceCount: 0)
        )

        XCTAssertEqual(machine.state.value.asFailed, .faceLost)
    }

    func testABriefDetectorDropoutIsSurvivable() throws {
        let machine = try machine(.turnLeft)
        let startedAt = machine.completePositioning()

        // Real detectors drop frames. A session that died on one would be unusable.
        machine.onFrame(frame(atMs: startedAt + 200, faceCount: 0))
        machine.onFrame(frame(atMs: startedAt + 400, faceCount: 0))
        let active = try XCTUnwrap(machine.state.value.asChallengeActive)
        XCTAssertEqual(active.hint, .noFace)

        machine.performTurn(from: startedAt + 400, yawAtExtreme: -35)
        XCTAssertEqual(machine.state.value, .capturing)
    }

    func testAMissingFaceWhilePositioningOnlyPrompts() throws {
        let machine = try machine(.turnLeft)

        machine.onFrame(frame(atMs: 0, faceCount: 0))
        machine.onFrame(frame(atMs: 5_000, faceCount: 0))

        // Nothing has been asked of the user yet, so there is nothing to fail.
        let state = try XCTUnwrap(machine.state.value.asPositioning)
        XCTAssertEqual(state.hint, .noFace)
    }

    func testAChangedTrackingIDFailsAsASwap() throws {
        let machine = try machine(.turnLeft)
        let startedAt = machine.completePositioning()

        // The person who positioned is not the person completing the challenge.
        machine.onFrame(frame(atMs: startedAt + 100, yaw: -35, trackingId: 2))

        XCTAssertEqual(machine.state.value.asFailed, .faceSwapped)
    }

    func testASwapDuringPositioningFailsJustAsHard() throws {
        let machine = try machine(.turnLeft)

        machine.onFrame(frame(atMs: 0, trackingId: 7))
        machine.onFrame(frame(atMs: 100, trackingId: 8))

        XCTAssertEqual(machine.state.value.asFailed, .faceSwapped)
    }

    func testFramesWithoutATrackingIDAreAccepted() throws {
        // Detectors in single-image mode report no identity, which is the case
        // for the shipped Vision bridge. Refusing to work there would be worse
        // than losing the swap check on those platforms.
        let machine = try machine(.turnLeft)

        machine.onFrame(frame(atMs: 0, trackingId: nil))
        machine.onFrame(frame(atMs: 800, trackingId: nil))
        machine.performTurn(from: 800, yawAtExtreme: -35, trackingId: nil)

        XCTAssertEqual(machine.state.value, .capturing)
    }

    func testASecondFaceEndsTheSessionImmediately() throws {
        let machine = try machine(.turnLeft)
        machine.completePositioning()

        machine.onFrame(frame(atMs: 1_000, faceCount: 2))

        XCTAssertEqual(machine.state.value.asFailed, .multipleFaces)
    }

    // MARK: Framing

    func testAFaceTooFarAwayCannotFinishPositioning() throws {
        let machine = try machine(.turnLeft)
        let tooSmall = testConfig.minFaceRatio - 0.05

        machine.onFrame(frame(atMs: 0, faceRatio: tooSmall))
        machine.onFrame(frame(atMs: 2_000, faceRatio: tooSmall))

        let state = try XCTUnwrap(machine.state.value.asPositioning)
        XCTAssertEqual(state.hint, .moveCloser)
        XCTAssertEqual(state.holdProgress, 0)
    }

    func testAFaceTooFarAwayCannotCompleteAChallenge() throws {
        let machine = try machine(.turnLeft)
        let startedAt = machine.completePositioning()
        let tooSmall = testConfig.minFaceRatio - 0.05

        // A textbook turn, measured on a face too small to measure reliably.
        machine.onFrame(frame(atMs: startedAt + 100, yaw: -40, faceRatio: tooSmall))
        machine.onFrame(frame(atMs: startedAt + 200, yaw: 0, faceRatio: tooSmall))

        let active = try XCTUnwrap(machine.state.value.asChallengeActive)
        XCTAssertEqual(active.phase, .awaitingAction)
        XCTAssertEqual(active.hint, .moveCloser)
    }

    func testAFaceFillingTheFrameIsToldToBackOff() throws {
        let machine = try machine(.turnLeft)

        machine.onFrame(frame(atMs: 0, faceRatio: testConfig.maxFaceRatio + 0.05))

        XCTAssertEqual(machine.state.value.asPositioning?.hint, .moveAway)
    }

    func testPositioningHintsNameTheThingActuallyWrong() throws {
        let machine = try machine(.turnLeft)

        machine.onFrame(frame(atMs: 0, brightness: testConfig.minBrightness - 10))
        XCTAssertEqual(machine.state.value.asPositioning?.hint, .tooDark)

        machine.onFrame(frame(atMs: 100, sharpness: testConfig.minSharpness - 5))
        XCTAssertEqual(machine.state.value.asPositioning?.hint, .lowQuality)

        machine.onFrame(frame(atMs: 200, roll: testConfig.maxRollDeg + 5))
        XCTAssertEqual(machine.state.value.asPositioning?.hint, .straightenHead)

        machine.onFrame(frame(atMs: 300, yaw: testConfig.centerToleranceDeg + 5))
        XCTAssertEqual(machine.state.value.asPositioning?.hint, .lookStraight)
    }

    // MARK: Frame selection

    func testThePrimaryFrameIsTheMostFrontalAndSharpest() throws {
        let machine = try machine(.turnLeft)

        let blurryButFrontal = frame(atMs: 0, yaw: 0, sharpness: 30)
        let sharpButAngled = frame(atMs: 200, yaw: 8, sharpness: 200)
        let best = frame(atMs: 400, yaw: 0, sharpness: 200)
        let mediocre = frame(atMs: 800, yaw: 6, sharpness: 100)

        // `FaceFrame` is a struct, so Kotlin's `assertSame` becomes value
        // equality — and the distinct timestamps are what keep these four
        // fixtures distinguishable by `==`.
        for candidate in [blurryButFrontal, sharpButAngled, best, mediocre] {
            machine.onFrame(candidate)
        }
        machine.performTurn(from: 800, yawAtExtreme: -35)
        try machine.completeCapture()

        let evidence = try XCTUnwrap(machine.state.value.asDone)
        XCTAssertEqual(evidence.primary, best)
    }

    func testEachChallengeKeepsTheFrameAtItsFurthestPoint() throws {
        let machine = try machine(.turnLeft)
        let startedAt = machine.completePositioning()

        machine.onFrame(frame(atMs: startedAt + 100, yaw: -26))
        let furthest = frame(atMs: startedAt + 200, yaw: -48)
        machine.onFrame(furthest)
        machine.onFrame(frame(atMs: startedAt + 300, yaw: -30))
        machine.onFrame(frame(atMs: startedAt + 400, yaw: 0))
        try machine.completeCapture()

        let evidence = try XCTUnwrap(machine.state.value.asDone)
        XCTAssertEqual(evidence.challenges.count, 1)
        XCTAssertEqual(evidence.challenges.first?.frame, furthest)
    }

    func testEvidenceListsThePrimaryFrameFirst() throws {
        let machine = try machine(.turnLeft, .turnRight)
        let startedAt = machine.completePositioning()
        let afterLeft = machine.performTurn(from: startedAt, yawAtExtreme: -35)
        machine.performTurn(from: afterLeft, yawAtExtreme: 35)
        try machine.completeCapture()

        let evidence = try XCTUnwrap(machine.state.value.asDone)
        XCTAssertEqual(evidence.frames.count, 3)
        XCTAssertEqual(evidence.frames.first, evidence.primary)
        XCTAssertGreaterThan(evidence.durationMs, 0)
    }

    // MARK: Lifecycle

    func testATerminalSessionIgnoresEverythingThatFollows() throws {
        let machine = try machine(.turnLeft)
        machine.completePositioning()
        machine.onFrame(frame(atMs: 1_000, faceCount: 2))
        let failed = machine.state.value
        XCTAssertNotNil(failed.asFailed)

        // A camera keeps delivering frames after the session ends; none of them
        // may resurrect it.
        machine.onFrame(frame(atMs: 1_100))
        machine.performTurn(from: 1_100, yawAtExtreme: -35)
        machine.onTick(nowMs: 2_000)

        XCTAssertEqual(machine.state.value, failed)
    }

    func testCancelEndsTheSessionAndIsIdempotent() throws {
        let machine = try machine(.turnLeft)
        machine.completePositioning()

        machine.cancel()
        let failed = machine.state.value
        XCTAssertEqual(failed.asFailed, .cancelled)

        machine.cancel()
        XCTAssertEqual(machine.state.value, failed)
    }

    func testResetMakesAUsedMachineReusable() throws {
        let machine = try machine(.turnLeft)
        machine.completePositioning()
        machine.onFrame(frame(atMs: 1_000, trackingId: 99))
        XCTAssertNotNil(machine.state.value.asFailed)

        machine.reset()
        XCTAssertEqual(machine.state.value, .idle)

        // The old tracking id and the old deadlines must both be gone.
        let startedAt = machine.completePositioning(startMs: 50_000)
        machine.performTurn(from: startedAt, yawAtExtreme: -35)
        XCTAssertEqual(machine.state.value, .capturing)
    }

    func testCompleteCaptureIsRejectedOutsideCapturing() throws {
        let machine = try machine(.turnLeft)

        // Kotlin raises IllegalStateException; there is no error code for "the
        // SDK was driven wrong", so the port reuses `invalidConfig`.
        assertThrowsFaceCheckError(try machine.completeCapture(), code: .invalidConfig)

        machine.completePositioning()
        assertThrowsFaceCheckError(try machine.completeCapture(), code: .invalidConfig)
    }

    /// Losing the face while the shutter is open is a runtime condition, not a
    /// caller mistake: the runner keeps pumping frames through the capture on
    /// purpose, so `faceLostGraceMs` is live the whole time. Reporting it as
    /// `invalidConfig` put a message written for the integrator in front of the
    /// end user and made a host switching on `code` see a build defect.
    func testCompleteCaptureReportsAFailureThatHappenedDuringTheCapture() throws {
        let machine = try machine(.turnLeft)
        let startedAt = machine.completePositioning()
        let capturingAt = machine.performTurn(from: startedAt, yawAtExtreme: -35)
        XCTAssertEqual(machine.state.value, .capturing)

        // The user lowers the phone at the sound of the shutter.
        machine.onFrame(
            frame(atMs: capturingAt + testConfig.faceLostGraceMs + 1, faceCount: 0)
        )
        XCTAssertEqual(machine.state.value.asFailed, .faceLost)

        let failure = assertThrowsFaceCheckError(
            try machine.completeCapture(),
            code: .livenessFailed
        )
        XCTAssertEqual(
            failure?.message,
            "Perdimos tu rostro. Mantente dentro del marco e intenta de nuevo."
        )
    }

    /// The other half of the same hole: the capture itself running past
    /// `captureTimeoutMs` must surface as `TIMEOUT`.
    func testCompleteCaptureReportsATimeoutThatExpiredDuringTheCapture() throws {
        let machine = try machine(.turnLeft)
        let startedAt = machine.completePositioning()
        let capturingAt = machine.performTurn(from: startedAt, yawAtExtreme: -35)
        XCTAssertEqual(machine.state.value, .capturing)

        machine.onTick(nowMs: capturingAt + testConfig.captureTimeoutMs + 1)
        XCTAssertEqual(machine.state.value.asFailed, .timeout)

        let failure = assertThrowsFaceCheckError(
            try machine.completeCapture(),
            code: .timeout
        )
        XCTAssertEqual(failure?.message, "Se acabó el tiempo. Vuelve a intentarlo.")
    }

    func testASessionNeedsAtLeastOneChallenge() {
        assertThrowsFaceCheckError(try ChallengeMachine(challenges: []), code: .invalidConfig)
    }

    func testTheStateCarriesProgressAndASpanishInstruction() throws {
        let machine = try machine(.turnLeft, .turnRight)
        let startedAt = machine.completePositioning()

        let first = try XCTUnwrap(machine.state.value.asChallengeActive)
        XCTAssertEqual(first.instructionEs, "Gira la cabeza a la izquierda")
        XCTAssertEqual(first.progress, 0)

        machine.onFrame(frame(atMs: startedAt + 100, yaw: -35))
        XCTAssertEqual(machine.state.value.instructionEs, "Regresa a ver de frente")

        machine.onFrame(frame(atMs: startedAt + 200, yaw: 0))
        let second = try XCTUnwrap(machine.state.value.asChallengeActive)
        XCTAssertEqual(second.instructionEs, "Gira la cabeza a la derecha")
        XCTAssertEqual(second.progress, 0.5)
        XCTAssertNil(second.hint)
    }

    // MARK: Publication

    /// `StateStream` replaces `MutableStateFlow`, and the Kotlin tests only ever
    /// read `state.value`. The subscription side is new in the port, so it needs
    /// its own coverage: a subscriber must see the current value immediately
    /// (the UI paints the first instruction before any frame arrives) and must
    /// not be told the same thing thirty times a second.
    func testASubscriberReplaysTheCurrentValueAndConflatesRepeats() async throws {
        let machine = try machine(.turnLeft)
        machine.completePositioning()

        var iterator = machine.state.values.makeAsyncIterator()
        let replayed = await iterator.next()
        XCTAssertNotNil(replayed?.asChallengeActive)

        // Identical states are dropped, so the next element delivered is the
        // failure, never a repeat of the challenge that is already on screen.
        machine.onFrame(frame(atMs: 900))
        machine.cancel()
        let next = await iterator.next()
        XCTAssertEqual(next?.asFailed, .cancelled)
    }
}
