import AVFoundation
import Dispatch
import Foundation

protocol CameraOperating: Actor {
    var events: AsyncStream<CameraEvent> { get }
    var frames: FrameProcessor { get }
    func start() async throws
    func stop() async
    func capture(_ request: CaptureRequest) async throws -> PhotoPayload
    func apply(_ controls: CameraControls) async throws
    func selectLens(_ id: String) async throws
    func focus(at point: CGPoint) async throws
    func recordMovie(fourK: Bool, fps: Int, location: GeoTag?, onStarted: @escaping @Sendable () -> Void) async throws -> URL
    func finishMovie() async
    func setPreview(_ options: PreviewOptions) async
    /// Pays the AVCaptureSession reconfiguration cost (preset change, mic input, movie output)
    /// up front, e.g. when the user switches to the Video tab, instead of at record-tap time.
    func prewarmVideo(fourK: Bool, fps: Int) async
    /// Reverts a prewarmed video session back to the photo-optimized preset. Safe to call anytime;
    /// a no-op unless video mode was actually prewarmed.
    func prewarmPhoto() async
}

/// All session/device mutations execute on one serial executor, separate from MainActor.
actor CameraService: CameraOperating {
    private let queue: DispatchSerialQueue
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
    nonisolated let frames: FrameProcessor
    nonisolated let events: AsyncStream<CameraEvent>
    private let continuation: AsyncStream<CameraEvent>.Continuation
    private let session: AVCaptureSession
    private let photos: AVCapturePhotoOutput
    private let videoFrames: AVCaptureVideoDataOutput
    private let movies: AVCaptureMovieFileOutput
    private let frameQueue: DispatchQueue
    private var device: AVCaptureDevice?
    private var videoInput: AVCaptureDeviceInput?
    private var capabilities = CameraCapabilities()
    private var controls = CameraControls()
    private var photoDelegate: PhotoDelegate?
    private var movieDelegate: MovieDelegate?
    private var notifications: [NSObjectProtocol] = []
    private var wantsRunning = false
    private var configured = false
    private var recording = false
    private var deviceObservations: [NSKeyValueObservation] = []
    private var videoModeConfigured = false
    private var videoFourK = false
    private var videoFPS = 30

    init() {
        // app.init.cameraService measured ~460-470ms, but the four AVFoundation object inits
        // below only ever accounted for ~75ms of it — moving every remaining stored property out
        // of its inline default and into this timed sequence to find the rest, or rule out
        // everything app-code-visible and conclude it's the actor's custom-executor bootstrap.
        queue = Diagnostics.time("service.init.dispatchQueue") { DispatchSerialQueue(label: "com.fexer.camera", qos: .userInitiated) }
        frames = Diagnostics.time("service.init.frameProcessor") { FrameProcessor() }
        frameQueue = Diagnostics.time("service.init.frameDispatchQueue") { DispatchQueue(label: "com.fexer.frames", qos: .userInitiated) }
        let stream = Diagnostics.time("service.init.eventStream") { AsyncStream.makeStream(of: CameraEvent.self, bufferingPolicy: .bufferingNewest(12)) }
        events = stream.stream
        continuation = stream.continuation
        session = Diagnostics.time("service.init.captureSession") { AVCaptureSession() }
        photos = Diagnostics.time("service.init.photoOutput") { AVCapturePhotoOutput() }
        videoFrames = Diagnostics.time("service.init.videoDataOutput") { AVCaptureVideoDataOutput() }
        movies = Diagnostics.time("service.init.movieFileOutput") { AVCaptureMovieFileOutput() }
    }

    func start() async throws {
        guard !wantsRunning else { return }
        wantsRunning = true
        continuation.yield(.phase(.starting))
        var status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .notDetermined {
            let allowed = await AVCaptureDevice.requestAccess(for: .video)
            status = allowed ? .authorized : .denied
        }
        guard wantsRunning else { return }
        guard status == .authorized else {
            wantsRunning = false
            continuation.yield(.phase(.denied))
            throw AppIssue.cameraDenied
        }
        do {
            if !configured { try Diagnostics.time("service.configure") { try configure() } }
            observeSession()
            observeDevice()
            Diagnostics.time("service.sessionStartRunning") { session.startRunning() }
            guard session.isRunning else { throw AppIssue.cameraUnavailable }
            continuation.yield(.phase(.ready))
            #if DEBUG
            Diagnostics.camera.debug("Capture session started")
            #endif
        } catch {
            wantsRunning = false
            continuation.yield(.phase(.failed(error.localizedDescription)))
            throw error
        }
    }

    func stop() {
        wantsRunning = false
        deviceObservations.forEach { $0.invalidate() }
        deviceObservations.removeAll()
        if movies.isRecording { movies.stopRecording() }
        if let device, device.hasTorch {
            do { try device.lockForConfiguration(); device.torchMode = .off; device.unlockForConfiguration() }
            catch { Diagnostics.report(error, operation: "Turn off torch") }
        }
        session.stopRunning()
        notifications.forEach { NotificationCenter.default.removeObserver($0) }
        notifications.removeAll()
        frames.clear()
        continuation.yield(.phase(.idle))
    }

    private func configure() throws {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw AppIssue.cameraUnavailable
        }
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo
        guard session.canAddInput(input), session.canAddOutput(photos), session.canAddOutput(videoFrames) else { throw AppIssue.cameraUnavailable }
        session.addInput(input)
        session.addOutput(photos)
        session.addOutput(videoFrames)
        videoFrames.alwaysDiscardsLateVideoFrames = true
        videoFrames.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoFrames.setSampleBufferDelegate(frames, queue: frameQueue)
        photos.maxPhotoQualityPrioritization = .quality
        self.device = device
        videoInput = input
        configured = true
        configureConnections()
        updateCapabilities()
    }

    func selectLens(_ id: String) throws {
        guard photoDelegate == nil, !recording else { throw AppIssue.busy }
        // Discovery was previously done twice — once here to find the target, again inside
        // updateCapabilities() — an AVCaptureDevice.DiscoverySession enumeration isn't free.
        // Reuse this same list for both.
        let devices = Diagnostics.time("service.selectLens.discoverDevices") { Self.devices() }
        guard let target = devices.first(where: { $0.uniqueID == id }), target != device else { return }
        let replacement = try AVCaptureDeviceInput(device: target)
        try Diagnostics.time("service.selectLens.commitConfiguration") {
            session.beginConfiguration()
            if let videoInput { session.removeInput(videoInput) }
            guard session.canAddInput(replacement) else {
                if let videoInput, session.canAddInput(videoInput) { session.addInput(videoInput) }
                session.commitConfiguration()
                throw AppIssue.cameraUnavailable
            }
            session.addInput(replacement)
            videoInput = replacement
            device = target
            session.commitConfiguration()
        }
        controls = CameraControls()
        Diagnostics.time("service.selectLens.configureConnections") { configureConnections() }
        Diagnostics.time("service.selectLens.updateCapabilities") { updateCapabilities(using: devices) }
        if wantsRunning { Diagnostics.time("service.selectLens.observeDevice") { observeDevice() } }
        try Diagnostics.time("service.selectLens.apply") { try apply(controls) }
    }

    func capture(_ request: CaptureRequest) async throws -> PhotoPayload {
        guard session.isRunning, photoDelegate == nil, !recording else { throw AppIssue.busy }
        guard request.format != .raw || capabilities.supportsRAW else {
            throw AppIssue("RAW unavailable", "Choose HEIF or JPEG for this camera.")
        }
        let settings: AVCapturePhotoSettings
        if request.proRAW, photos.isAppleProRAWSupported { photos.isAppleProRAWEnabled = true }
        if request.format == .raw {
            let rawTypes = photos.availableRawPhotoPixelFormatTypes
            let selected = request.proRAW ? rawTypes.first(where: AVCapturePhotoOutput.isAppleProRAWPixelFormat) : rawTypes.first
            guard let type = selected else { throw AppIssue.captureFailed }
            settings = AVCapturePhotoSettings(rawPixelFormatType: type, processedFormat: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        } else {
            let codec: AVVideoCodecType = request.format == .heif && photos.availablePhotoCodecTypes.contains(.hevc) ? .hevc : .jpeg
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: codec])
            // .quality lets the ISP run its full Deep Fusion/Smart HDR pipeline, which measured
            // ~600ms of the ~850ms didCapture→didFinishProcessing gap on a real device — the
            // single biggest chunk of "capture feels slow". .balanced keeps multi-frame fusion in
            // good light but caps how long the ISP is allowed to spend on it.
            settings.photoQualityPrioritization = .balanced
        }
        let flash: AVCaptureDevice.FlashMode = request.flash == .on ? .on : request.flash == .auto ? .auto : .off
        settings.flashMode = photos.supportedFlashModes.contains(flash) ? flash : .off
        var liveURL: URL?
        if request.livePhoto, photos.isLivePhotoCaptureSupported, request.format != .raw {
            photos.isLivePhotoCaptureEnabled = true
            liveURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
            settings.livePhotoMovieFileURL = liveURL
        }
        if let connection = photos.connection(with: .video), connection.isVideoRotationAngleSupported(request.rotation) {
            connection.videoRotationAngle = request.rotation
            if connection.isVideoMirroringSupported { connection.isVideoMirrored = capabilities.isFront }
        }
        defer { photoDelegate = nil }
        do {
            return try await Diagnostics.time("service.capturePhoto (AVFoundation end-to-end)") {
                try await withCheckedThrowingContinuation { completion in
                    let delegate = PhotoDelegate { result in completion.resume(with: result) }
                    photoDelegate = delegate
                    photos.capturePhoto(with: settings, delegate: delegate)
                }
            }
        } catch {
            if let liveURL { try? FileManager.default.removeItem(at: liveURL) }
            throw error
        }
    }

    func apply(_ value: CameraControls) throws {
        guard let device else { return }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        controls = value
        if value.manualExposure, device.isExposureModeSupported(.custom) {
            device.setExposureModeCustom(duration: CMTime(seconds: value.shutter.bounded(capabilities.shutterRange), preferredTimescale: 1_000_000_000),
                                         iso: Float(value.iso.bounded(capabilities.isoRange)))
        } else if value.exposureLocked, device.isExposureModeSupported(.locked) {
            device.exposureMode = .locked
        } else if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        device.setExposureTargetBias(Float(value.exposureBias.bounded(capabilities.exposureRange)))
        if value.manualFocus, device.isLockingFocusWithCustomLensPositionSupported {
            device.setFocusModeLocked(lensPosition: Float(value.focus.bounded(0...1)))
        } else if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        if value.manualWhiteBalance, device.isWhiteBalanceModeSupported(.locked) {
            var gains = device.deviceWhiteBalanceGains(for: .init(temperature: Float(value.temperature.bounded(2500...10000)), tint: Float(value.tint.bounded(-150...150))))
            gains.redGain = min(max(gains.redGain, 1), device.maxWhiteBalanceGain)
            gains.greenGain = min(max(gains.greenGain, 1), device.maxWhiteBalanceGain)
            gains.blueGain = min(max(gains.blueGain, 1), device.maxWhiteBalanceGain)
            device.setWhiteBalanceModeLocked(with: gains)
        } else if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
        device.videoZoomFactor = value.zoom.bounded(capabilities.zoomRange)
        if device.hasTorch, device.isTorchAvailable { device.torchMode = value.torch ? .on : .off }
    }

    func focus(at point: CGPoint) throws {
        guard let device else { return }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        if !controls.manualFocus, device.isFocusPointOfInterestSupported {
            device.focusPointOfInterest = point
            if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
        }
        if !controls.manualExposure, !controls.exposureLocked, device.isExposurePointOfInterestSupported {
            device.exposurePointOfInterest = point
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        }
    }

    func recordMovie(fourK: Bool, fps: Int, location: GeoTag?, onStarted: @escaping @Sendable () -> Void) async throws -> URL {
        guard session.isRunning, !recording, photoDelegate == nil else { throw AppIssue.busy }
        recording = true
        defer { recording = false; movieDelegate = nil }
        // No-op if the Video tab already warmed this up; only pays the reconfiguration cost here
        // as a fallback (e.g. mic permission wasn't yet decided, or prewarm lost a race). Either
        // way, `onStarted` (not this call) is the accurate "recording is actually rolling" signal.
        await prewarmVideo(fourK: fourK, fps: fps)
        guard videoModeConfigured else {
            if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
                throw AppIssue("Microphone access needed", "Allow Microphone in Settings to record video with sound.")
            }
            throw AppIssue("Video unavailable", "This camera cannot record video with the current configuration.")
        }
        guard wantsRunning else { throw CancellationError() }
        // Embedded directly in the .mov's own QuickTime metadata — not just applied to the
        // PHAsset after export — so the file itself carries an accurate geotag wherever it goes.
        movies.metadata = location.map { [Self.locationMetadataItem(for: $0)] } ?? []
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        return try await withCheckedThrowingContinuation { completion in
            let delegate = MovieDelegate(onStarted: onStarted) { completion.resume(with: $0) }
            movieDelegate = delegate
            movies.startRecording(to: url, recordingDelegate: delegate)
        }
    }

    func finishMovie() {
        if movies.isRecording { movies.stopRecording() }
    }

    func prewarmVideo(fourK: Bool, fps: Int) async {
        guard wantsRunning, !recording else { return }
        guard !videoModeConfigured || videoFourK != fourK || videoFPS != fps else { return }
        // beginConfiguration()/property sets just enqueue; AVCaptureSession does the actual
        // reconfiguration work atomically inside commitConfiguration(), so that's the only call
        // worth isolating a timing around — measuring the whole begin...commit span would have
        // just attributed everything to "session reconfigure" without showing whether requesting
        // mic access (a system permission check, near-instant once decided) is instead the culprit.
        let allowed = await Diagnostics.time("service.requestMicAccess") { await AVCaptureDevice.requestAccess(for: .audio) }
        guard allowed, wantsRunning, !recording else { return }
        // Field logs isolated the ~4.7s cost to attachOutputsInputs, not the preset change (which
        // measured 276ms — fine). The app never explicitly configures AVAudioSession anywhere, so
        // adding the mic AVCaptureDeviceInput was the FIRST audio activity of the process, forcing
        // iOS to implicitly negotiate and activate an audio session on the spot — a well-known slow
        // path. Doing that negotiation explicitly and up front (still only when entering Video mode,
        // never for photo-only users, so we don't silently pause someone's music just for opening
        // the camera) should convert that stall into a one-time, earlier cost.
        Diagnostics.time("service.prewarmVideo.audioSessionActivate") {
            do {
                try AVAudioSession.sharedInstance().setCategory(.playAndRecord, options: [.allowBluetoothHFP, .defaultToSpeaker])
                try AVAudioSession.sharedInstance().setActive(true)
            } catch { Diagnostics.report(error, operation: "Activate audio session for video") }
        }
        let preset: AVCaptureSession.Preset = fourK ? .hd4K3840x2160 : .hd1920x1080
        if session.sessionPreset != preset {
            Diagnostics.time("service.prewarmVideo.presetChange (\(preset.rawValue))") {
                session.beginConfiguration()
                session.sessionPreset = session.canSetSessionPreset(preset) ? preset : .high
                session.commitConfiguration()
            }
        }
        Diagnostics.time("service.prewarmVideo.attachOutputsInputs") {
            session.beginConfiguration()
            if !session.outputs.contains(movies), session.canAddOutput(movies) { session.addOutput(movies) }
            if !session.inputs.contains(where: { ($0 as? AVCaptureDeviceInput)?.device.hasMediaType(.audio) == true }),
               let microphone = AVCaptureDevice.default(for: .audio),
               let input = try? AVCaptureDeviceInput(device: microphone), session.canAddInput(input) {
                session.addInput(input)
            }
            session.commitConfiguration()
        }
        guard session.outputs.contains(movies) else { return }
        if let device, device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= Double(fps) && $0.maxFrameRate >= Double(fps) }) {
            try? device.lockForConfiguration()
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: Int32(fps))
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: Int32(fps))
            device.unlockForConfiguration()
        }
        if let connection = movies.connection(with: .video), connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
        configureConnections()
        updateCapabilities()
        videoModeConfigured = true
        videoFourK = fourK
        videoFPS = fps
    }

    func prewarmPhoto() {
        guard videoModeConfigured, !recording else { return }
        Diagnostics.time("service.prewarmPhoto (session reconfigure)") {
            session.beginConfiguration()
            session.removeOutput(movies)
            for input in session.inputs where (input as? AVCaptureDeviceInput)?.device.hasMediaType(.audio) == true { session.removeInput(input) }
            session.sessionPreset = .photo
            session.commitConfiguration()
        }
        // Release the recording-capable audio session so a paused Music/podcast app resumes —
        // the cost of renegotiating it is paid again next time the user enters Video mode.
        do { try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        catch { Diagnostics.report(error, operation: "Deactivate audio session after video") }
        configureConnections()
        updateCapabilities()
        videoModeConfigured = false
    }

    func setPreview(_ options: PreviewOptions) { frames.setOptions(options) }

    private func configureConnections() {
        if let connection = videoFrames.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            if connection.isVideoMirroringSupported { connection.isVideoMirrored = device?.position == .front }
        }
    }

    private static func locationMetadataItem(for location: GeoTag) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = .quickTimeMetadataLocationISO6709
        var iso6709 = String(format: "%+.6f%+.6f", location.latitude, location.longitude)
        if let altitude = location.altitude { iso6709 += String(format: "%+.6f", altitude) }
        item.value = (iso6709 + "/") as NSString
        return item
    }

    private static func devices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera],
                                         mediaType: .video, position: .unspecified).devices
    }

    private func updateCapabilities(using knownDevices: [AVCaptureDevice]? = nil) {
        guard let device else { return }
        let devices = knownDevices ?? Self.devices()
        capabilities = CameraCapabilities(
            lenses: devices.map { camera in
                let name: String
                let label: String
                switch camera.deviceType {
                case .builtInUltraWideCamera: name = "Ultra wide"; label = "0.5×"
                case .builtInTelephotoCamera: name = "Telephoto"; label = "Tele"
                default: name = camera.position == .front ? "Front" : "Wide"; label = camera.position == .front ? "Front" : "1×"
                }
                return CameraLens(id: camera.uniqueID, name: name, label: label, isFront: camera.position == .front)
            }, activeLensID: device.uniqueID,
            supportsRAW: !photos.availableRawPhotoPixelFormatTypes.isEmpty,
            supportsProRAW: photos.isAppleProRAWSupported, supportsLivePhoto: photos.isLivePhotoCaptureSupported,
            supportsFlash: device.hasFlash, supportsTorch: device.hasTorch,
            supportsManualExposure: device.isExposureModeSupported(.custom),
            supportsManualFocus: device.isLockingFocusWithCustomLensPositionSupported,
            isoRange: Double(device.activeFormat.minISO)...Double(device.activeFormat.maxISO),
            shutterRange: device.activeFormat.minExposureDuration.seconds...device.activeFormat.maxExposureDuration.seconds,
            zoomRange: Double(device.minAvailableVideoZoomFactor)...min(Double(device.maxAvailableVideoZoomFactor), 15),
            exposureRange: Double(device.minExposureTargetBias)...Double(device.maxExposureTargetBias)
        )
        continuation.yield(.capabilities(capabilities))
    }

    private func publishReading() {
        guard let device else { return }
        let white = device.temperatureAndTintValues(for: device.deviceWhiteBalanceGains)
        continuation.yield(.reading(CameraReading(iso: Double(device.iso), shutter: device.exposureDuration.seconds,
                                                  temperature: Double(white.temperature), focus: Double(device.lensPosition),
                                                  exposureOffset: Double(device.exposureTargetOffset), zoom: Double(device.videoZoomFactor))))
    }

    /// KVO instead of a fixed-interval poll: the top bar reflects the true device state the
    /// instant AVFoundation's 3A loop actually changes it, not up to 250ms late, and the actor
    /// stays idle whenever nothing is actually changing.
    private func observeDevice() {
        deviceObservations.forEach { $0.invalidate() }
        guard let device else { deviceObservations = []; return }
        // Closure literals passed directly as arguments are inferred @Sendable; a shared nested
        // function would instead inherit this actor's isolation and be rejected by KVO's API.
        deviceObservations = [
            device.observe(\.iso, options: [.initial, .new]) { [weak self] _, _ in Task { await self?.publishReading() } },
            device.observe(\.exposureDuration, options: .new) { [weak self] _, _ in Task { await self?.publishReading() } },
            device.observe(\.lensPosition, options: .new) { [weak self] _, _ in Task { await self?.publishReading() } },
            device.observe(\.videoZoomFactor, options: .new) { [weak self] _, _ in Task { await self?.publishReading() } },
            device.observe(\.deviceWhiteBalanceGains, options: .new) { [weak self] _, _ in Task { await self?.publishReading() } },
        ]
    }

    private func observeSession() {
        guard notifications.isEmpty else { return }
        notifications = [
            NotificationCenter.default.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] _ in
                Task { await self?.interrupted() }
            },
            NotificationCenter.default.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { [weak self] _ in
                Task { await self?.recover() }
            },
            NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] _ in
                Task { await self?.runtimeError() }
            }
        ]
    }
    private func interrupted() {
        continuation.yield(.phase(.interrupted))
        if movies.isRecording { movies.stopRecording() }
    }
    private func runtimeError() {
        Diagnostics.camera.error("Capture session runtime error")
        continuation.yield(.phase(.failed("The camera stopped. Tap Try again to restart it.")))
        wantsRunning = false
    }
    private func recover() {
        guard wantsRunning else { return }
        if !session.isRunning { session.startRunning() }
        continuation.yield(.phase(session.isRunning ? .ready : .failed("The camera couldn’t restart.")))
    }
}
