import AVFoundation
import CoreMedia
import Foundation

#if canImport(UIKit)
import UIKit

/// The SDK's own ``CameraController``: one `AVCaptureSession`, two outputs.
///
/// ### Why two outputs
///
/// They answer different questions.
///
/// - `AVCaptureVideoDataOutput` drives the analysis stream, with
///   `alwaysDiscardsLateVideoFrames = true`.
/// - `AVCapturePhotoOutput` takes the single still that gets uploaded. What it
///   buys is the **still-image pipeline** — its own exposure and noise
///   reduction, and no rolling-shutter smear from a buffer that was optimised
///   for being thrown away thirty times a second. The accuracy of the entire
///   system rests on that one image. The video path stays as the **fallback**
///   for hosts (and simulators) with no usable photo output.
///
/// What the second output does **not** buy is resolution. `sessionPreset`
/// governs every output, not just the video one, so with `.hd1280x720` the photo
/// comes back at 1280x720 as well. That is deliberate and stays: the preset is
/// what keeps a thirty-second session inside its thermal and battery budget, and
/// ``LivenessConfig/minFaceRatio``/``LivenessConfig/maxFaceRatio`` are tuned
/// against a 16:9 720p frame in the shipping Kotlin SDK — moving to `.photo`
/// would change the analysis frame's aspect ratio and silently retune both.
/// Raising it is a decision to make against real devices and real users, not a
/// tidy-up. `targetStillSize` (1080 by default) is still the binding constraint
/// on the long edge, so the upload is unaffected either way.
///
/// ### Portrait
///
/// Both connections are pinned to portrait, so buffers arrive upright and the
/// detector is handed ``FrameOrientation/up``. That is a deliberate limitation,
/// not an oversight: a liveness UI is portrait, and pinning it here means
/// neither the pose maths nor the still encoding has to follow device rotation.
/// It removes a whole class of "works in portrait, finds no face in landscape"
/// bugs that only ever appear on somebody else's device.
///
/// **`automaticallyAdjustsVideoMirroring` must be set to false *before*
/// `isVideoMirrored` is written**, on every connection. The other order lets
/// AVFoundation reimpose the front camera's default mirroring and the assignment
/// is lost with no error.
///
/// ### Threading
///
/// Everything that touches the session runs on one private serial queue.
/// Configuring an `AVCaptureSession` on the main thread blocks it long enough to
/// drop the host's own UI frames, and `startRunning()` in particular can take
/// hundreds of milliseconds. Only preview-layer work goes to main.
///
/// `@unchecked Sendable` splits as follows, and this list is the whole
/// justification for it: session state is confined to `sessionQueue`,
/// `pendingFailure` and `previewTicket` are guarded by their own locks, and
/// `previewLayer`, `previewAttached` plus `appliedPreviewTicket` belong to the
/// main actor.
///
/// ### Info.plist
///
/// `NSCameraUsageDescription` is **required in the host app**. An SPM package
/// cannot supply it, and without it iOS kills the process on first camera access.
public final class AVCameraController: CameraController, @unchecked Sendable {

    /// The layer to lay out. Built eagerly in `init`, before the session is
    /// configured and long before it runs, because the host has to position it.
    ///
    /// A `CALayer` takes no part in Auto Layout, so its frame has to be reset
    /// from the view controller's `viewDidLayoutSubviews`; a layer the host
    /// cannot reach is a layer that is the wrong size on every device but the
    /// one it was written on.
    @MainActor public let previewLayer: AVCaptureVideoPreviewLayer

    /// - Parameters:
    ///   - viewController: presents the liveness UI. The preview layer is
    ///     inserted into its view and follows its lifecycle.
    ///   - options: capture parameters.
    ///   - detector: the face detector. Construction is cheap — it opens no
    ///     camera, requests no permission and starts nothing; all of that
    ///     happens in ``start()``.
    @MainActor
    public init(
        viewController: UIViewController,
        options: CameraOptions,
        detector: any FaceDetectorBridge
    ) {
        self.options = options
        self.detector = detector
        // Built empty and given the session a line later: Swift forbids reading
        // `self.session` until every stored property has a value, and this is one
        // of the properties still missing one.
        self.previewLayer = AVCaptureVideoPreviewLayer()
        self.hostViewController = viewController

        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspectFill
        // Retained here because `setSampleBufferDelegate(_:queue:)` holds it
        // weakly; see SampleBufferDelegate.
        sampleDelegate = SampleBufferDelegate(controller: self)
    }

    public var frames: AsyncThrowingStream<FaceFrame, any Error> {
        AsyncThrowingStream(FaceFrame.self, bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            // Registering on `sessionQueue` — the same queue `fail(_:)` runs on —
            // is what closes the race between a failure and a subscriber that
            // arrives just after it: either this sees the recorded failure, or
            // `fail(_:)` sees this continuation. Neither order loses the error.
            self.sessionQueue.async { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                if let failure = self.recordedFailure() {
                    continuation.finish(throwing: failure)
                    return
                }
                self.subscribers[id] = continuation
            }
            // Weak, so a stream the host stopped consuming cannot keep the
            // controller — and therefore the camera — alive.
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.sessionQueue.async { self.subscribers[id] = nil }
            }
        }
    }

    /// Tries the photo output first, then the analysis stream, then gives up
    /// with ``FaceCheckErrorCode/cameraUnavailable`` and
    /// "No se pudo tomar la foto. Revisa los permisos de cámara e intenta de nuevo."
    public func captureStill() async throws -> Data {
        if let photo = await capturePhoto() { return photo }
        FaceCheckLogger.warn("photo output unavailable; falling back to the analysis stream")
        if let frame = await captureFromStream() { return frame }
        throw FaceCheckError(code: .cameraUnavailable, message: Self.stillFailedMessage)
    }

    /// Opens the camera, asking for permission if it has not been asked yet.
    ///
    /// Clears ``pendingFailure`` **synchronously**, before dispatching anything.
    /// That is the port of Kotlin's `resetReplayCache()` and it has to stay
    /// synchronous: a failure from the previous attempt is replayed to every new
    /// consumer, and the session runner subscribes the instant this returns, so
    /// clearing it inside the queue would leave a window where the retry that
    /// was about to work dies with the old error. The common case is the user
    /// granting permission in Settings and coming back.
    ///
    /// Asking for permission here rather than refusing outright is deliberate: a
    /// host that has not prompted yet still works, it just starts a moment
    /// later. A host that wants the prompt at a sensible point in its own flow
    /// should request it before calling this.
    ///
    /// Failures are never thrown from here — they are delivered on ``frames``.
    /// See ``CameraController/frames`` for why.
    public nonisolated func start() {
        failureLock.lock()
        pendingFailure = nil
        failureLock.unlock()

        // Taken here, synchronously, and not where the layer is actually
        // inserted: see `applyPreview(attached:ticket:)` for why the intent has
        // to be numbered at the call rather than at the hop.
        let ticket = nextPreviewTicket()

        sessionQueue.async { [self] in
            if running {
                // Already running, so nothing below will re-attach the preview —
                // do it here, for a host that restarts an already-open camera.
                Task { @MainActor in applyPreview(attached: true, ticket: ticket) }
                return
            }
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                startConfigured(previewTicket: ticket)
            case .notDetermined:
                // The callback form rather than the async one: this is already
                // running on the capture queue, and awaiting here would mean
                // making `start()` async, which it cannot be — `stop()` is called
                // from a `defer`. The project's no-completion-handler rule is
                // about the SDK's public API, and this is neither.
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    self.sessionQueue.async {
                        guard granted else {
                            FaceCheckLogger.error("camera permission denied by the user")
                            self.fail(Self.cameraUnavailable(Self.permissionMessage))
                            return
                        }
                        self.startConfigured(previewTicket: ticket)
                    }
                }
            default:
                FaceCheckLogger.error(
                    "camera permission is denied or restricted; check NSCameraUsageDescription"
                )
                fail(Self.cameraUnavailable(Self.permissionMessage))
            }
        }
    }

    /// Configures on first use, then runs. On `sessionQueue`.
    ///
    /// The preview is attached **here, on every start**, not in ``configure()``.
    /// It used to be attached there, which is a place that runs exactly once:
    /// ``stop()`` removes the layer from the host's view, `configured` stays
    /// true, and the second `start()` therefore never put it back. The camera
    /// ran, the detector emitted frames, the session advanced — and the user
    /// watched a black rectangle. That is the retry path ``stop()`` documents as
    /// supported, so it is the common case, not an edge one.
    private func startConfigured(previewTicket ticket: Int) {
        if !configured {
            if let failure = configure() {
                fail(failure)
                return
            }
            configured = true
        }
        if !running {
            session.startRunning()
            running = true
        }
        Task { @MainActor in applyPreview(attached: true, ticket: ticket) }
    }

    /// Stops the session, closes the detector, settles any capture still waiting
    /// on a result that is no longer coming, and detaches the preview. Idempotent.
    public nonisolated func stop() {
        let ticket = nextPreviewTicket()
        sessionQueue.async { [self] in
            if running {
                session.stopRunning()
                running = false
            }
            detector.close()
            // Settle both capture paths rather than leaving the caller suspended
            // until the session-wide timeout fires. The photo path matters most:
            // its delegate callback is exactly what a teardown mid-capture stops
            // delivering.
            if let pending = stillFromStream {
                stillFromStream = nil
                pending(nil)
            }
            if let pending = pendingPhoto {
                pendingPhoto = nil
                pending(nil)
            }
            photoDelegate = nil
            // Subscribers are deliberately left open, matching the Kotlin
            // SharedFlow: a stopped camera is not an error, the session runner
            // cancels its own pump in a `defer`, and finishing here would race a
            // restart — a user who fails a session and retries goes through
            // stop() then start() on the same controller.
            //
            // The notification observers are left registered for the same
            // reason: `configure()` runs once, so unregistering here would leave
            // a restarted session deaf to interruptions. They go in `deinit`.
        }
        Task { @MainActor in applyPreview(attached: false, ticket: ticket) }
    }

    /// A controller can be dropped without ``stop()`` ever being called — a host
    /// that starts the camera to show a preview and then dismisses the screen,
    /// or cancels before the session begins.
    ///
    /// Nothing else releases the camera on that path. The preview layer is
    /// retained by the host's view hierarchy and it retains the session, so the
    /// capture graph — and the camera light — can outlive this object.
    deinit {
        for observer in sessionObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        detector.close()
        // `stopRunning()` blocks, and `deinit` runs wherever the last reference
        // was dropped — possibly on `sessionQueue` itself, from the release of a
        // block that captured `self`. So the teardown is handed to the queue
        // every other session call already uses. It cannot capture `self`, and an
        // `AVCaptureSession` is not `Sendable` on its own, hence the box.
        let teardown = SessionTeardown(session: session)
        sessionQueue.async { teardown.run() }
    }

    /// Builds the session, or returns the error to publish on ``frames``.
    ///
    /// Returns the error rather than a `Bool` on purpose: a `false` meant "logged
    /// something and gave up", and every new early return was one more way for
    /// the session to die by timeout instead of by a message the user can act on.
    ///
    /// Notable choices: `.builtInWideAngleCamera` via a discovery session; the
    /// `.hd1280x720` preset guarded by `canSetSessionPreset`, because the
    /// analysis path resamples to a fraction of that anyway and a 4K stream
    /// spends battery and thermal headroom a thirty-second session cannot pay
    /// for; and **no `videoOutput.videoSettings`**, which is deliberate — the
    /// iOS default is bi-planar YUV, exactly what the planar branch of
    /// ``pixelStats(_:face:orientation:)`` assumes, and forcing BGRA there would
    /// drop the luma path to the green channel for nothing.
    private func configure() -> FaceCheckError? {
        guard let device = preferredCamera() else {
            // The simulator has no camera at all, and this is the message a
            // developer sees first when they run the demo there.
            FaceCheckLogger.error("no front camera on this device")
            return Self.cameraUnavailable(Self.noCameraMessage)
        }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            FaceCheckLogger.error("cannot open the camera: \(error.localizedDescription)")
            return Self.cameraUnavailable(Self.cannotOpenMessage)
        }

        session.beginConfiguration()
        // The preset governs **every** output, the photo one included, so this
        // line also decides the still's resolution. See the type's doc comment
        // for why it stays at 720p regardless.
        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        }
        if session.canAddInput(input) { session.addInput(input) }

        videoOutput.alwaysDiscardsLateVideoFrames = true
        // `videoSettings` is deliberately left alone: the iOS default is
        // bi-planar YUV, which is exactly what the planar branch of pixelStats
        // wants. Forcing BGRA here would drop the luma path to the green channel
        // for nothing. Not setting a property is invisible in review, hence this.
        videoOutput.setSampleBufferDelegate(sampleDelegate, queue: sessionQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        session.commitConfiguration()

        // Connections only exist once the outputs are attached, so this cannot
        // move above `commitConfiguration()`.
        pinToPortrait(videoOutput.connection(with: .video))
        pinToPortrait(photoOutput.connection(with: .video))
        observeSessionInterruptions()
        return nil
    }

    /// Subscribes to the three notifications that mean "the camera is no longer
    /// yours": a runtime error, an interruption, and its end.
    ///
    /// Without them, the system taking the camera away is completely silent. The
    /// video output stops delivering, so ``frames`` neither yields nor throws,
    /// the machine stays exactly where it was, and the user watches black until
    /// the 90-second global deadline tells them the verification "took too long".
    /// Every other way the camera can fail reaches the user through the failure
    /// channel; this was the one that did not.
    ///
    /// An interruption fails the session rather than waiting it out, even though
    /// every reason iOS reports is in principle recoverable. A liveness session
    /// is a thirty-second interaction with a user actively holding the phone: by
    /// the time the call ends or the other app gives the camera back, the session
    /// is over anyway, and "la cámara se interrumpió" is a message they can act
    /// on where a frozen screen is not. The `interruptionEnded` restart is still
    /// worth having — it is what leaves the *controller* usable for the retry.
    private func observeSessionInterruptions() {
        let center = NotificationCenter.default
        // Each block reads what it needs out of the notification and lets only
        // that value cross to the capture queue: `Notification` is not `Sendable`,
        // and its `userInfo` least of all.
        sessionObservers = [
            center.addObserver(
                forName: .AVCaptureSessionRuntimeError,
                object: session,
                queue: nil
            // The `self.` on every member below is not noise and not style:
            // Swift 6.0 (Xcode 16.4) still requires it inside an escaping
            // closure even after `guard let self`. Swift 6.3 relaxed the rule,
            // so dropping it compiles on a recent Mac and breaks the build for
            // anyone on Xcode 16 — which is a supported toolchain here.
            ) { [weak self] note in
                let reason = (note.userInfo?[AVCaptureSessionErrorKey] as? NSError)?
                    .localizedDescription ?? "unknown"
                self?.sessionQueue.async { [weak self] in
                    guard let self else { return }
                    FaceCheckLogger.error("capture session runtime error: \(reason)")
                    self.fail(Self.cameraUnavailable(Self.cameraLostMessage))
                }
            },
            center.addObserver(
                forName: .AVCaptureSessionWasInterrupted,
                object: session,
                queue: nil
            ) { [weak self] note in
                let reason = (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int) ?? -1
                self?.sessionQueue.async { [weak self] in
                    guard let self else { return }
                    FaceCheckLogger.warn("capture session interrupted, reason \(reason)")
                    self.fail(Self.cameraUnavailable(Self.cameraLostMessage))
                }
            },
            center.addObserver(
                forName: .AVCaptureSessionInterruptionEnded,
                object: session,
                queue: nil
            ) { [weak self] _ in
                self?.sessionQueue.async { [weak self] in
                    guard let self, self.running, !self.session.isRunning else { return }
                    FaceCheckLogger.info("capture session interruption ended; resuming")
                    self.session.startRunning()
                }
            }
        ]
    }

    /// The camera named by ``CameraOptions/useFrontCamera``.
    ///
    /// The discovery session has already filtered by position; the second check
    /// is belt and braces, and the fallback covers a device reporting an
    /// unspecified position rather than leaving the user with a black screen.
    private func preferredCamera() -> AVCaptureDevice? {
        let wanted: AVCaptureDevice.Position = options.useFrontCamera ? .front : .back
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: wanted
        )
        return discovery.devices.first { $0.position == wanted } ?? discovery.devices.first
    }

    /// Pins a connection to portrait and turns mirroring **off**.
    ///
    /// `videoOrientation` is deprecated in iOS 17, so this prefers
    /// `videoRotationAngle = 90` under an availability check. The Kotlin SDK
    /// stayed on the deprecated call only because calling the new one on an old
    /// OS is an unrecognised-selector crash in Kotlin/Native; in Swift the check
    /// is one line, so it is done properly here.
    private func pinToPortrait(_ connection: AVCaptureConnection?) {
        pinToPortrait(connection, mirrored: false)
    }

    /// The preview needs the same portrait pinning with mirroring left **on**, so
    /// the mirroring decision is a parameter rather than a second copy of the
    /// rotation dance. Only ``attachPreview()`` ever passes true.
    private func pinToPortrait(_ connection: AVCaptureConnection?, mirrored: Bool) {
        guard let connection else { return }

        if #available(iOS 17.0, *), connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        } else if connection.isVideoOrientationSupported {
            // Deprecated in iOS 17 and still the only option below it. The
            // warning is accepted rather than worked around: the alternative is
            // a `respondsToSelector` dance around two lines the deprecated API
            // performs correctly.
            connection.videoOrientation = .portrait
        }

        if connection.isVideoMirroringSupported {
            // Order is not negotiable: AVFoundation reimposes the front camera's
            // default mirroring unless automatic adjustment is off *first*, and
            // the assignment below is then lost with no error at all.
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirrored
        }
    }

    /// Applies the newest attach/detach intent and ignores stale ones.
    ///
    /// ``start()`` and ``stop()`` both hand their intent to the main actor, and
    /// two `Task { @MainActor }` bodies are **not** guaranteed to run in the
    /// order they were created — priority alone can reorder them. A host that
    /// retries in one turn (`stop(); start()`) would then have the detach land
    /// after the re-attach and get the black screen back, with a live camera
    /// behind it. The ticket is taken synchronously inside `start()`/`stop()`,
    /// so whatever the host asked for last is what the user ends up seeing.
    @MainActor
    private func applyPreview(attached: Bool, ticket: Int) {
        guard ticket > appliedPreviewTicket else { return }
        appliedPreviewTicket = ticket
        if attached {
            attachPreview()
        } else {
            previewLayer.removeFromSuperlayer()
            previewAttached = false
        }
    }

    private nonisolated func nextPreviewTicket() -> Int {
        previewTicket.withLock { $0 += 1; return $0 }
    }

    /// Inserts ``previewLayer`` into the host view controller's view.
    ///
    /// Reading `.view` is what forces the controller to load it, so this is safe
    /// even when ``start()`` runs before the controller is on screen. The preview
    /// connection is the **only** one that gets ``CameraOptions/mirrorPreview``.
    ///
    /// Idempotent through `previewAttached`, which is what lets every ``start()``
    /// call it unconditionally.
    @MainActor
    private func attachPreview() {
        if previewAttached { return }
        guard let view = hostViewController?.view else { return }
        previewLayer.frame = view.bounds
        // The one connection that gets mirrored. A user watching an un-mirrored
        // preview turns their head the wrong way when told to turn left, and
        // reads that as the SDK being broken.
        pinToPortrait(previewLayer.connection, mirrored: options.mirrorPreview)
        view.layer.insertSublayer(previewLayer, at: 0)
        previewAttached = true
    }

    /// Called on `sessionQueue`, one buffer at a time.
    ///
    /// Guards `presentationTimeStamp.seconds` with `isFinite` before converting.
    /// `CMTime.seconds` is NaN for an invalid time, Kotlin's `toLong()` returned
    /// 0 for that, and Swift's `Int64(nan)` **traps and kills the process**.
    ///
    /// Passes ``FrameOrientation/up`` because the connections are pinned to
    /// portrait: AVFoundation has already rotated the buffer.
    func onSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Presentation timestamps come from the capture clock and are monotonic
        // across the session, which is exactly what ChallengeMachine needs: a
        // wall clock would let a system time change end a session mid-turn.
        let seconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        // `CMTime.seconds` is NaN for an invalid time. Kotlin's `toLong()`
        // answered 0; `Int64(_:)` **traps and kills the process**, so the
        // conversion is guarded and the frame is dropped instead.
        guard seconds.isFinite,
              let timestampMs = Int64(exactly: (seconds * 1000).rounded(.towardZero))
        else { return }

        // FrameOrientation.up because the connections are pinned to portrait:
        // AVFoundation has already rotated the buffer.
        if let frame = detector.analyze(
            sampleBuffer: sampleBuffer,
            orientation: .up,
            timestampMs: timestampMs
        ) {
            // `yield` on a bufferingNewest(1) stream never blocks, so the capture
            // queue never waits on a consumer.
            for continuation in subscribers.values {
                continuation.yield(frame)
            }
        }

        if let resume = stillFromStream {
            stillFromStream = nil
            resume(
                JPEGEncoding.encode(
                    pixelBuffer: buffer,
                    orientation: .up,
                    mirrored: false,
                    maxEdge: options.targetStillSize,
                    quality: options.jpegQuality
                )
            )
        }
    }

    /// Records the failure and finishes every subscriber's stream throwing it. A
    /// consumer that subscribes afterwards gets it immediately, which is the
    /// `replay = 1` of the Kotlin failure channel.
    private func fail(_ error: FaceCheckError) {
        // Recorded under the lock rather than queue-confined because `start()`
        // clears it synchronously from whatever thread called it. Everything else
        // here runs on `sessionQueue`, which is what makes the hand-off to a
        // subscriber registering at the same instant safe.
        failureLock.lock()
        pendingFailure = error
        failureLock.unlock()

        let waiting = subscribers
        subscribers.removeAll()
        for continuation in waiting.values {
            continuation.finish(throwing: error)
        }
    }

    /// The failure a *new* subscriber has to be told about. On `sessionQueue`.
    private func recordedFailure() -> FaceCheckError? {
        failureLock.lock()
        defer { failureLock.unlock() }
        return pendingFailure
    }

    private static func cameraUnavailable(_ message: String) -> FaceCheckError {
        FaceCheckError(code: .cameraUnavailable, message: message)
    }

    /// Takes the still from the photo output, or nil when it cannot run.
    ///
    /// **Bounded**, exactly like ``captureFromStream()``, and the reason is
    /// sharper here. Kotlin suspended in `suspendCancellableCoroutine`, so the
    /// session's `withTimeout` could unwind a capture that never called back. A
    /// `withCheckedContinuation` cannot be resumed by cancellation, and
    /// `withThrowingTaskGroup` waits for its children before it propagates the
    /// timeout — so an `AVCapturePhotoOutput` that never calls its delegate
    /// (session interrupted by an incoming call, app sent to the background,
    /// teardown mid-capture) would hang `runLivenessSession` for good, and the
    /// `defer { camera.stop() }` that releases the camera would never run. A
    /// biometric SDK leaving the camera light on forever is the one failure this
    /// file exists to prevent.
    ///
    /// Every settle path lands on `sessionQueue` — the delegate's own callback,
    /// the deadline, and ``stop()`` — so a per-request latch guarantees exactly
    /// one resume. Resuming a checked continuation twice is a crash, not a
    /// warning.
    private func capturePhoto() async -> Data? {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [self] in
                // The session's own state, not this class's `running` flag. While
                // an `AVCaptureSession` is interrupted the flag is still true and
                // the connection still exists, but it is inactive — and
                // `capturePhoto(with:delegate:)` in that state raises
                // `NSInvalidArgumentException` ("No active and enabled video
                // connection"), which Swift cannot catch: a hard crash of the host
                // app. Returning nil falls back to the analysis stream instead.
                guard session.isRunning,
                      let connection = photoOutput.connection(with: .video),
                      connection.isActive, connection.isEnabled
                else {
                    continuation.resume(returning: nil)
                    return
                }

                let request = StillRequest()
                let settle: @Sendable (Data?) -> Void = { [self] data in
                    sessionQueue.async { [self] in
                        if request.settled { return }
                        request.settled = true
                        pendingPhoto = nil
                        photoDelegate = nil
                        continuation.resume(returning: data)
                    }
                }

                let settings = AVCapturePhotoSettings(
                    format: [AVVideoCodecKey: AVVideoCodecType.jpeg]
                )
                let delegate = PhotoCaptureDelegate { [self] data in
                    // Re-encoding on the delegate's own thread is deliberate: it
                    // is a one-shot at the end of the session, and doing it here
                    // keeps a multi-megapixel decode off the queue that is still
                    // feeding frames to the machine while the capture completes.
                    settle(
                        data.flatMap {
                            JPEGEncoding.reencode(
                                $0,
                                maxEdge: options.targetStillSize,
                                quality: options.jpegQuality
                            )
                        }
                    )
                }
                // Held strongly for the duration: AVCapturePhotoOutput does not
                // retain its delegate, and a deallocated one is a capture that
                // silently never calls back. Every settle path clears it, so the
                // self → delegate → closure → self cycle cannot outlive the
                // deadline below.
                photoDelegate = delegate
                pendingPhoto = settle
                sessionQueue.asyncAfter(
                    deadline: .now() + .milliseconds(Int(Self.photoStillTimeoutMs))
                ) {
                    settle(nil)
                }
                photoOutput.capturePhoto(with: settings, delegate: delegate)
            }
        }
    }

    /// Takes the still from the next analysis frame.
    ///
    /// Bounded by its own ``streamStillTimeoutMs`` because the alternative is
    /// worse than failing: with no camera there is no next frame, and the caller
    /// would hang until the whole session's deadline instead of getting a camera
    /// error it can show the user. Two seconds is several frames at any rate the
    /// SDK will ever see.
    private func captureFromStream() async -> Data? {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [self] in
                guard running else {
                    continuation.resume(returning: nil)
                    return
                }
                // Kotlin raced `withTimeoutOrNull` against the frame. Here both
                // the frame and the deadline land on `sessionQueue`, so a
                // per-request latch is enough to guarantee exactly one resume —
                // and resuming a checked continuation twice is a crash, not a
                // warning. A latch per request also means a deadline left over
                // from an earlier capture cannot settle a later one.
                let request = StillRequest()
                stillFromStream = { data in
                    if request.settled { return }
                    request.settled = true
                    continuation.resume(returning: data)
                }
                sessionQueue.asyncAfter(
                    deadline: .now() + .milliseconds(Int(Self.streamStillTimeoutMs))
                ) { [self] in
                    if request.settled { return }
                    request.settled = true
                    stillFromStream = nil
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(
        label: "com.borealnetwork.facecheck.capture",
        qos: .userInitiated
    )
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private let options: CameraOptions
    private let detector: any FaceDetectorBridge

    /// Weak so the SDK does not keep the host's view controller alive.
    private weak var hostViewController: UIViewController?

    /// Guarded by `sessionQueue`.
    private var subscribers: [UUID: AsyncThrowingStream<FaceFrame, any Error>.Continuation] = [:]

    /// The one piece of state that cannot be queue-confined; see ``start()``.
    private let failureLock = NSLock()
    private var pendingFailure: FaceCheckError?

    @MainActor private var previewAttached = false
    private var configured = false
    private var running = false

    /// Orders the preview intents of ``start()`` and ``stop()`` against each
    /// other; see ``applyPreview(attached:ticket:)``. Not queue-confined,
    /// because both of those are `nonisolated` and take their number before
    /// dispatching anything.
    private let previewTicket = LockedBox(0)
    @MainActor private var appliedPreviewTicket = 0

    /// Held strongly only while a capture is in flight, so the output can never
    /// outlive its delegate mid-capture.
    private var photoDelegate: PhotoCaptureDelegate?

    /// Settles the photo capture in flight, so ``stop()`` can end one whose
    /// delegate callback the teardown just cancelled. Guarded by `sessionQueue`.
    private var pendingPhoto: ((Data?) -> Void)?

    /// Set while a still is being taken from the analysis stream.
    private var stillFromStream: ((Data?) -> Void)?

    /// `setSampleBufferDelegate(_:queue:)` holds its delegate **weakly**, so
    /// something has to retain it. That is this property.
    private var sampleDelegate: SampleBufferDelegate!

    /// Tokens from ``observeSessionInterruptions()``, unregistered in `deinit`.
    private var sessionObservers: [any NSObjectProtocol] = []

    static let streamStillTimeoutMs: Int64 = 2_000

    /// Deadline for the photo output, in the same spirit as
    /// ``streamStillTimeoutMs`` but longer: a real capture with exposure
    /// bracketing takes well over a second on a slow device, and giving up on a
    /// photo that was about to arrive costs image quality. It has to leave room
    /// for the stream fallback inside ``LivenessConfig/captureTimeoutMs`` (8 s),
    /// which 3 000 + 2 000 does.
    static let photoStillTimeoutMs: Int64 = 3_000

    /// Spanish, verbatim from the Kotlin SDK, all reported as
    /// ``FaceCheckErrorCode/cameraUnavailable``.
    ///
    /// The permission text points at Settings instead of offering a retry
    /// because iOS only asks once: after the first refusal `requestAccess`
    /// returns false without showing anything, so a user tapping "try again"
    /// would see the same black screen forever.
    static let permissionMessage =
        "Necesitamos permiso para usar la cámara. Actívalo en Ajustes > Privacidad > Cámara "
            + "e intenta de nuevo."
    static let noCameraMessage =
        "Este dispositivo no tiene una cámara que podamos usar para la verificación."
    static let cannotOpenMessage =
        "No se pudo abrir la cámara. Ciérrala en otras apps e intenta de nuevo."
    static let stillFailedMessage =
        "No se pudo tomar la foto. Revisa los permisos de cámara e intenta de nuevo."

    /// The camera opened and was then taken away — a call came in, another app
    /// claimed it, the OS reported a runtime error. Distinct wording from
    /// ``cannotOpenMessage`` because "no se pudo abrir" reads as nonsense to
    /// someone who has been watching their own face for ten seconds. No Kotlin
    /// counterpart: the KMP SDK does not observe these notifications at all.
    static let cameraLostMessage =
        "Se interrumpió la cámara. Cierra las apps que la estén usando e intenta de nuevo."
}

/// Carries the capture session to `sessionQueue` from `deinit`, which cannot
/// capture `self`.
///
/// `@unchecked Sendable` because by the time this runs the object that owned the
/// session is gone, so the only thing that can touch it is this one closure, on
/// the queue every other session call already uses.
private struct SessionTeardown: @unchecked Sendable {

    let session: AVCaptureSession

    func run() {
        if session.isRunning { session.stopRunning() }
    }
}

/// Bridges the Objective-C sample-buffer callback back to the controller.
///
/// A separate object rather than making the controller its own delegate, and the
/// reason survives the port: `setSampleBufferDelegate(_:queue:)` stores the
/// delegate **weakly**, so somebody has to retain it. It also keeps the SDK's
/// public class out of the `NSObject` hierarchy.
///
/// Do not turn this into an actor and do not `await` here: the sample buffer
/// stops being valid the moment this method returns.
final class SampleBufferDelegate: NSObject,
    AVCaptureVideoDataOutputSampleBufferDelegate,
    @unchecked Sendable {

    /// Weak, not `unowned`, and not strong either.
    ///
    /// Strong would be the controller → delegate → controller cycle. `unowned`
    /// was a crash: `AVCaptureVideoDataOutput` holds this object weakly, so a
    /// callback already in flight keeps *the delegate* alive while the
    /// controller — dropped by a host that never called `stop()` — deallocates
    /// underneath it, and reading an unowned reference to a deallocated object
    /// traps. Weak costs nothing here, because a weak load returning non-nil
    /// pins the controller for the whole call.
    private weak var controller: AVCameraController?

    init(controller: AVCameraController) {
        self.controller = controller
        super.init()
    }

    /// Called on the queue given to `setSampleBufferDelegate(_:queue:)`, which
    /// is the controller's `sessionQueue`. Pure forwarding, no logic.
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let controller else { return }
        controller.onSampleBuffer(sampleBuffer)
    }
}

/// One capture's worth of "has this been answered yet".
///
/// `@unchecked Sendable` rests on the same invariant as the controller's own:
/// every closure that touches `settled` — the frame callback, the photo
/// delegate's hop, the deadline, and `stop()` — runs on the capture session's
/// serial queue, so the flag is never read and written concurrently. One latch
/// per request, so a deadline left over from an earlier capture cannot settle a
/// later one. See ``AVCameraController/captureFromStream()``.
private final class StillRequest: @unchecked Sendable {
    var settled = false
}

/// A single-shot photo delegate; `onResult` receives nil on any failure.
final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {

    private let onResult: @Sendable (Data?) -> Void

    /// Not paranoia, and it must be ported as-is: AVFoundation can call back
    /// **more than once** on some error paths, and resuming a continuation twice
    /// is a crash rather than a warning. No lock, because AVFoundation delivers
    /// one capture's callbacks serially.
    private var delivered = false

    init(onResult: @escaping @Sendable (Data?) -> Void) {
        self.onResult = onResult
        super.init()
    }

    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: (any Error)?
    ) {
        if delivered { return }
        delivered = true
        if let error {
            FaceCheckLogger.error("photo capture failed: \(error.localizedDescription)")
            onResult(nil)
            return
        }
        onResult(photo.fileDataRepresentation())
    }

    /// The terminal callback of a capture, and the reason it is implemented:
    /// `didFinishProcessingPhoto` is not guaranteed on every failure path, and
    /// without a second exit an error inside AVFoundation would leave the caller
    /// waiting out the whole deadline for an answer that already exists.
    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: (any Error)?
    ) {
        if delivered { return }
        delivered = true
        FaceCheckLogger.error(
            "photo capture ended with no photo: \(error?.localizedDescription ?? "unknown")"
        )
        onResult(nil)
    }
}

/// Builds the default pipeline: an ``AVCameraController`` driving a
/// ``VisionFaceDetector``.
///
/// `mirrored: false` is not an assumption — it is true because the controller
/// forces `isVideoMirrored = false` on its analysis connection. The two facts
/// travel together; changing one means changing the other.
///
/// `@MainActor` because it builds the preview layer and reads
/// `viewController.view`. Construction is cheap: no camera, no permission
/// prompt, nothing started until ``AVCameraController/start()``.
@MainActor
public func makeCameraController(
    viewController: UIViewController,
    options: CameraOptions = CameraOptions()
) -> any CameraController {
    AVCameraController(
        viewController: viewController,
        options: options,
        detector: VisionFaceDetector(mirrored: false)
    )
}

/// The escape hatch for a host that wants ML Kit (or anything else) without the
/// SDK linking it. See ``FaceDetectorBridge`` for what an implementation owes.
@MainActor
public func makeCameraController(
    viewController: UIViewController,
    detector: any FaceDetectorBridge,
    options: CameraOptions = CameraOptions()
) -> any CameraController {
    AVCameraController(viewController: viewController, options: options, detector: detector)
}
#endif
