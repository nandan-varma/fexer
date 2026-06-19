import AVFoundation
import CoreImage
import Observation
import OSLog
import Foundation
import UIKit
import Photos

    /// Owns the AVCaptureSession and all camera hardware configuration.
    /// @Observable properties are read from MainActor; all session mutations
    /// are dispatched to sessionQueue for thread safety.
    ///
    /// This class provides a high-level interface for camera configuration and capture,
    /// abstracting away the complexity of AVFoundation's session management and device
    /// configuration. All public methods are thread-safe and can be called from any
    /// context, though they execute on the sessionQueue for hardware operations.
    @Observable
    final class CameraManager: NSObject {
    // MARK: - Published state (MainActor)
    var isSessionRunning = false
    var currentISO: Float = 200
    var currentShutterSpeed: CMTime = CMTime(value: 1, timescale: 250)
    var currentWhiteBalance: Float = 5500
    var currentLensPosition: Float = 0.5
    var currentWhiteBalanceTint: Float = 0
    var currentZoomFactor: CGFloat = 1.0
    var availableLenses: [LensOption] = []
    var flashMode: AVCaptureDevice.FlashMode = .off
    var isCapturing = false
    var lastCapturedPhoto: CapturedPhoto?
    var previewImageSize: CGSize = .zero

    // Video recording state (MainActor)
    var isRecording = false
    var recordingDuration: TimeInterval = 0

    // Live Photo toggle (MainActor)
    var isLivePhotoEnabled = false

    // Hardware capability flags (set after session configuration)
    var isProRAWSupported: Bool = false
    var isDepthDataSupported: Bool = false

    // MARK: - Internal (sessionQueue only)
    let processor = CaptureProcessor()
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.fexer.session", qos: .userInteractive)
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var currentDevice: AVCaptureDevice?
    private var deviceObservations: [NSKeyValueObservation] = []

    // AVAssetWriter recording pipeline — accessed from sessionQueue AND nonisolated audio delegate,
    // so nonisolated(unsafe). All mutations are serialised through sessionQueue.
    private var assetWriter: AVAssetWriter?
    private var videoWriterInput: AVAssetWriterInput?
    private var audioWriterInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var isWaitingToRecord = false
    private let audioOutput = AVCaptureAudioDataOutput()

    // Timer runs on MainActor; kept here so we can invalidate from MainActor context
    private var recordingTimer: Timer?

    var captureSettings = CaptureSettings()

    // MARK: - Notification observation token

    private var sessionErrorObserver: NSObjectProtocol?

    // MARK: - Setup

    /// Starts the camera session and begins capturing video frames.
    ///
    /// This method initializes the AVCaptureSession, configures the camera device,
    /// and starts the video capture pipeline. It can be called multiple times safely
    /// - if the session is already running, it will be a no-op.
    func startSession() {
        sessionQueue.async { [self] in
            guard !session.isRunning else { return }
            self.configureSession()
            self.session.startRunning()
            Task { @MainActor in self.isSessionRunning = true }
            // Observe runtime errors for session recovery
            self.sessionErrorObserver = NotificationCenter.default.addObserver(
                forName: NSNotification.Name(rawValue: "AVCaptureSessionError"),
                object: session,
                queue: .main
            ) { [weak self] notification in
                self?.handleSessionError(notification)
            }
            // Defer video rotation so the connection stabilises after startRunning.
            // Setting videoRotationAngle immediately can trigger Fig err=-12710.
            self.sessionQueue.asyncAfter(deadline: .now() + 0.15) { [self] in
                self.configureVideoRotation()
            }
        }
    }

    /// Stops the camera session and releases all resources.
    ///
    /// This method stops the video capture pipeline, removes all observers,
    /// and cleans up the session. It can be called multiple times safely.
    func stopSession() {
        sessionQueue.async { [self] in
            if let observer = sessionErrorObserver {
                NotificationCenter.default.removeObserver(observer)
                sessionErrorObserver = nil
            }
            self.session.stopRunning()
            Task { @MainActor in self.isSessionRunning = false }
        }
    }

    deinit {
        if let observer = sessionErrorObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    @objc private func handleSessionError(_ notification: Notification) {
        guard let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError else { return }
        Logger.camera.error("Session runtime error: \(error.localizedDescription) (domain=\(error.domain) code=\(error.code))")

        if error.code == -12710 {
            Logger.camera.warning("err=-12710 suggests a connection/rotation configuration mismatch. Re-applying rotation in 0.5s.")
            sessionQueue.asyncAfter(deadline: .now() + 0.5) { [self] in
                configureVideoRotation()
            }
        }

        sessionQueue.asyncAfter(deadline: .now() + 1.0) { [self] in
            guard !session.isRunning else { return }
            session.startRunning()
            Task { @MainActor in self.isSessionRunning = session.isRunning }
        }
    }

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .photo

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera,
                          .builtInTelephotoCamera, .builtInDualCamera,
                          .builtInTripleCamera, .builtInDualWideCamera],
            mediaType: .video,
            position: .back
        )

        let lenses: [LensOption] = discovery.devices.map { device in
            LensOption(device: device, label: labelForDevice(device))
        }
        Task { @MainActor in self.availableLenses = lenses }

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device)
        else {
            Logger.camera.error("configureSession: failed to access wide-angle camera or create device input")
            session.commitConfiguration()
            return
        }

        if session.canAddInput(input) { session.addInput(input) }
        currentDevice = device

        videoOutput.setSampleBufferDelegate(processor, queue: sessionQueue)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        // Audio output for AVAssetWriter pipeline
        if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }

        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }

        // Live Photo requires the capture to be enabled before commitConfiguration
        if photoOutput.isLivePhotoCaptureSupported {
            photoOutput.isLivePhotoCaptureEnabled = true
        }

        // Microphone input for video recording audio
        if let audioDevice = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
           session.canAddInput(audioInput) {
            session.addInput(audioInput)
        }

        session.commitConfiguration()

        Task { @MainActor in
            self.isProRAWSupported = photoOutput.isAppleProRAWSupported
            self.isDepthDataSupported = photoOutput.isDepthDataDeliverySupported
        }

        setupObservations(for: device)

        processor.onPreviewSizeKnown = { [weak self] size in
            Task { @MainActor in self?.previewImageSize = size }
        }
    }

    // MARK: - Manual Controls (call on any thread; executes on sessionQueue)

    /// Sets the camera ISO value.
    ///
    /// - Parameter iso: The desired ISO value. Will be clamped to the device's
    ///   supported range (minISO to maxISO for the current active format).
    ///
    /// This method is thread-safe and can be called from any context. The actual
    /// device configuration occurs on the sessionQueue.
    func setISO(_ iso: Float) {
        sessionQueue.async { [self] in
            guard let device = currentDevice else {
                Logger.camera.error("Cannot set ISO: no camera device available")
                return
            }
            let clamped = iso.fxClamped(to: device.activeFormat.minISO...device.activeFormat.maxISO)
            device.withLock {
                device.setExposureModeCustom(duration: device.exposureDuration, iso: clamped)
            }
        }
    }

    func setShutterSpeed(_ duration: CMTime) {
        sessionQueue.async { [self] in
            guard let device = currentDevice else { return }
            let min = device.activeFormat.minExposureDuration
            let max = device.activeFormat.maxExposureDuration
            let clamped = CMTimeClampToRange(duration, range: CMTimeRange(start: min, end: max))
            device.withLock {
                device.setExposureModeCustom(duration: clamped, iso: device.iso, completionHandler: nil)
            }
        }
    }

    /// Sets ISO and shutter speed atomically in a single `setExposureModeCustom` call.
    /// Avoids the race where separate setISO/setShutter calls each read stale device values.
    /// Also updates captureSettings immediately so sliders reflect the preset values.
    func setManualExposure(iso: Float, duration: CMTime) {
        sessionQueue.async { [self] in
            guard let device = currentDevice else { return }
            let clampedISO = iso.fxClamped(to: device.activeFormat.minISO...device.activeFormat.maxISO)
            let minDur = device.activeFormat.minExposureDuration
            let maxDur = device.activeFormat.maxExposureDuration
            let clampedDuration = CMTimeClampToRange(duration, range: CMTimeRange(start: minDur, end: maxDur))
            device.withLock {
                device.setExposureModeCustom(duration: clampedDuration, iso: clampedISO)
            }
            Task { @MainActor in
                self.captureSettings.isoValue = clampedISO
                self.captureSettings.shutterSpeed = clampedDuration
            }
        }
    }

    /// Sets the camera white balance to the specified temperature and tint.
    ///
    /// - Parameters:
    ///   - kelvin: The white balance temperature in Kelvin (typically 5500 for daylight)
    ///   - tint: The white balance tint (-150 green to +150 magenta)
    ///
    /// The method automatically clamps the resulting color gains to ensure they stay
    /// within the device's supported range (1.0 to maxWhiteBalanceGain) to prevent
    /// crashes from invalid values.
    func setWhiteBalance(kelvin: Float, tint: Float = 0) {
        sessionQueue.async { [self] in
            guard let device = currentDevice else {
                Logger.camera.error("Cannot set white balance: no camera device available")
                return
            }
            let tnt = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: kelvin, tint: tint)
            var gains = device.deviceWhiteBalanceGains(for: tnt)
            let maxGain = device.maxWhiteBalanceGain
            let minGain = min(gains.redGain, gains.greenGain, gains.blueGain)
            if minGain < 1.0 {
                let scale = 1.0 / minGain
                gains.redGain   *= scale
                gains.greenGain *= scale
                gains.blueGain  *= scale
            }
            let peakGain = max(gains.redGain, gains.greenGain, gains.blueGain)
            if peakGain > maxGain {
                let scale = maxGain / peakGain
                gains.redGain   *= scale
                gains.greenGain *= scale
                gains.blueGain  *= scale
            }
            gains.redGain   = gains.redGain.fxClamped(to: 1.0...maxGain)
            gains.greenGain = gains.greenGain.fxClamped(to: 1.0...maxGain)
            gains.blueGain  = gains.blueGain.fxClamped(to: 1.0...maxGain)
            device.withLock {
                device.setWhiteBalanceModeLocked(with: gains)
            }
        }
    }

    /// Sets the camera focus distance using lens position.
    ///
    /// - Parameter lensPosition: The focus distance as a normalized value (0.0 to 1.0),
    ///   where 0.0 is infinity and 1.0 is the closest focusing distance.
    ///
    /// This method is thread-safe and executes on the sessionQueue.
    func setFocus(lensPosition: Float) {
        sessionQueue.async { [self] in
            guard let device = currentDevice else {
                Logger.camera.error("Cannot set focus: no camera device available")
                return
            }
            device.withLock {
                device.setFocusModeLocked(lensPosition: lensPosition.fxClamped(to: 0...1))
            }
        }
    }

    /// Sets the camera focus and exposure point of interest.
    ///
    /// - Parameter point: Normalized CGPoint (0.0 to 1.0) indicating the point of interest
    ///   within the camera frame. (0,0) is top-left, (1,1) is bottom-right.
    ///
    /// This method is thread-safe and executes on the sessionQueue. The focus and exposure
    /// will be locked to the specified point until changed or reset.
    /// - Parameters:
    ///   - point: Normalized CGPoint in AVFoundation space (0,0 = top-left, 1,1 = bottom-right).
    ///   - adjustExposure: When false (AEL active), only repoints focus — leaves exposure locked.
    func setFocusPoint(_ point: CGPoint, adjustExposure: Bool = true) {
        sessionQueue.async { [self] in
            guard let device = currentDevice else {
                Logger.camera.error("Cannot set focus point: no camera device available")
                return
            }
            let afMode = captureSettings.focusMode
            device.withLock {
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = point
                    device.focusMode = device.isFocusModeSupported(afMode) ? afMode : .autoFocus
                }
                if adjustExposure && device.isExposurePointOfInterestSupported {
                    // Spot metering tracks the tap point; matrix/center stay at center
                    let expPoint: CGPoint = captureSettings.meteringMode == .spot
                        ? point
                        : CGPoint(x: 0.5, y: 0.5)
                    device.exposurePointOfInterest = expPoint
                    device.exposureMode = .autoExpose
                }
            }
        }
    }

    /// Sets the exposure compensation (EV) value.
    ///
    /// - Parameter bias: The exposure compensation value in EV stops (-3 to +3 typical).
    ///
    /// This method is thread-safe and executes on the sessionQueue. The exposure compensation
    /// is stored in both the device and the captureSettings for UI consistency.
    func setExposureCompensation(_ bias: Float) {
        sessionQueue.async { [self] in
            guard let device = currentDevice else {
                Logger.camera.error("Cannot set exposure compensation: no camera device available")
                return
            }
            let clamped = bias.fxClamped(to: device.minExposureTargetBias...device.maxExposureTargetBias)
            device.withLock {
                device.setExposureTargetBias(clamped)
            }
            Task { @MainActor in self.captureSettings.exposureCompensation = clamped }
        }
    }

    /// Sets the camera zoom factor.
    ///
    /// - Parameter factor: The zoom factor (1.0 = no zoom, 2.0 = 2x zoom, etc.).
    ///
    /// This method is thread-safe and executes on the sessionQueue. The zoom factor
    /// is clamped to the device's supported range and updated in the currentZoomFactor
    /// property for UI binding.
    func setZoom(_ factor: CGFloat) {
        sessionQueue.async { [self] in
            guard let device = currentDevice else {
                Logger.camera.error("Cannot set zoom: no camera device available")
                return
            }
            let clamped = factor.fxClamped(
                to: device.minAvailableVideoZoomFactor...device.maxAvailableVideoZoomFactor
            )
            device.withLock {
                device.videoZoomFactor = clamped
            }
            Task { @MainActor in self.currentZoomFactor = clamped }
        }
    }

    /// Resets the camera to automatic exposure control.
    ///
    /// This method releases any manual exposure settings and returns the camera to
    /// automatic exposure mode. It is thread-safe and executes on the sessionQueue.
    func setAutoExposure() {
        sessionQueue.async { [self] in
            guard let device = currentDevice else {
                Logger.camera.error("Cannot set auto exposure: no camera device available")
                return
            }
            device.withLock {
                device.exposureMode = .continuousAutoExposure
            }
            Task { @MainActor in self.captureSettings.isAELocked = false }
        }
    }

    /// Resets the camera to automatic focus control.
    ///
    /// This method releases any manual focus settings and returns the camera to
    /// automatic focus mode. It is thread-safe and executes on the sessionQueue.
    func setAutoFocus() {
        sessionQueue.async { [self] in
            guard let device = currentDevice else {
                Logger.camera.error("Cannot set auto focus: no camera device available")
                return
            }
            let mode = captureSettings.focusMode
            device.withLock {
                let target = device.isFocusModeSupported(mode) ? mode : .continuousAutoFocus
                device.focusMode = target
            }
        }
    }

    /// Switches between AF-C (continuous tracking) and AF-S (single-shot lock).
    func setFocusMode(_ mode: AVCaptureDevice.FocusMode) {
        sessionQueue.async { [self] in
            guard let device = currentDevice else { return }
            device.withLock {
                if device.isFocusModeSupported(mode) {
                    device.focusMode = mode
                }
            }
            Task { @MainActor in self.captureSettings.focusMode = mode }
        }
    }

    /// Resets the camera to automatic white balance control.
    ///
    /// This method releases any manual white balance settings and returns the camera to
    /// automatic white balance mode. It is thread-safe and executes on the sessionQueue.
    func setAutoWhiteBalance() {
        sessionQueue.async { [self] in
            guard let device = currentDevice else {
                Logger.camera.error("Cannot set auto white balance: no camera device available")
                return
            }
            device.withLock {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
        }
    }

    /// Locks the current auto exposure settings (AE Lock).
    ///
    /// This method freezes the current exposure settings (ISO and shutter speed) so
    /// they remain constant regardless of lighting changes. It is thread-safe and
    /// executes on the sessionQueue.
    func lockAutoExposure() {
        sessionQueue.async { [self] in
            guard let device = currentDevice else {
                Logger.camera.error("Cannot lock auto exposure: no camera device available")
                return
            }
            device.withLock {
                device.setExposureModeCustom(duration: device.exposureDuration, iso: device.iso)
            }
            Task { @MainActor in self.captureSettings.isAELocked = true }
        }
    }

    /// Unlocks auto exposure settings (release AE Lock).
    ///
    /// This method releases the frozen exposure settings and returns the camera to
    /// automatic exposure control. It is thread-safe and executes on the sessionQueue.
    func unlockAutoExposure() {
        sessionQueue.async { [self] in
            guard let device = currentDevice else {
                Logger.camera.error("Cannot unlock auto exposure: no camera device available")
                return
            }
            device.withLock {
                device.exposureMode = .continuousAutoExposure
            }
            Task { @MainActor in self.captureSettings.isAELocked = false }
        }
    }

    func setMeteringMode(_ mode: MeteringMode) {
        sessionQueue.async { [self] in
            guard let device = currentDevice else { return }
            device.withLock {
                switch mode {
                case .matrix:
                    // True evaluative: don't constrain the exposure point — let the device
                    // use its own scene analysis across the full frame.
                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    }
                case .center:
                    // Center-weighted: explicitly bias the AE algorithm to the center region.
                    if device.isExposurePointOfInterestSupported {
                        device.exposurePointOfInterest = CGPoint(x: 0.5, y: 0.5)
                    }
                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    }
                case .spot:
                    // Spot: meter at the current tap-to-focus point.
                    // focusPointOfInterest defaults to (0.5, 0.5) when never explicitly set,
                    // so just use it directly — (0,0) is a valid top-left coordinate.
                    if device.isExposurePointOfInterestSupported {
                        device.exposurePointOfInterest = device.focusPointOfInterest
                    }
                    if device.isExposureModeSupported(.autoExpose) {
                        device.exposureMode = .autoExpose
                    }
                case .highlightWeighted:
                    // Approximate: use CIAreaMaximum to find the brightest region, meter there
                    if device.isExposurePointOfInterestSupported {
                        device.exposurePointOfInterest = CGPoint(x: 0.5, y: 0.2) // upper frame bias for highlights
                        device.exposureMode = .autoExpose
                    }
                }
            }
            Task { @MainActor in self.captureSettings.meteringMode = mode }
        }
    }

    // MARK: - ProRAW

    func setProRAWEnabled(_ enabled: Bool) {
        sessionQueue.async { [self] in
            guard photoOutput.isAppleProRAWSupported else { return }
            session.beginConfiguration()
            photoOutput.isAppleProRAWEnabled = enabled
            session.commitConfiguration()
            Logger.camera.info("ProRAW \(enabled ? "enabled" : "disabled")")
        }
    }

    // MARK: - Night Mode

    func setNightModeEnabled(_ enabled: Bool) {
        sessionQueue.async { [self] in
            guard let device = currentDevice else { return }
            device.withLock {
                if device.isLowLightBoostSupported {
                    device.automaticallyEnablesLowLightBoostWhenAvailable = enabled
                }
            }
            session.beginConfiguration()
            photoOutput.maxPhotoQualityPrioritization = enabled ? .quality : .balanced
            session.commitConfiguration()
        }
    }

    // MARK: - Portrait / Depth Data

    func setDepthDataEnabled(_ enabled: Bool) {
        sessionQueue.async { [self] in
            guard photoOutput.isDepthDataDeliverySupported else { return }
            session.beginConfiguration()
            photoOutput.isDepthDataDeliveryEnabled = enabled
            if enabled && photoOutput.isPortraitEffectsMatteDeliverySupported {
                photoOutput.isPortraitEffectsMatteDeliveryEnabled = true
            } else {
                photoOutput.isPortraitEffectsMatteDeliveryEnabled = false
            }
            session.commitConfiguration()
            Logger.camera.info("Depth data \(enabled ? "enabled" : "disabled")")
        }
    }

    /// Flips the camera between front and back positions.
    ///
    /// This method switches the active camera device and reconfigures the session.
    /// It is thread-safe and executes on the sessionQueue. After flipping, the camera
    /// will need a moment to stabilize before video frames are delivered.
    func flipCamera() {
        sessionQueue.async { [self] in
            let currentPosition = currentDevice?.position ?? .back
            let newPosition: AVCaptureDevice.Position = currentPosition == .back ? .front : .back
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: newPosition),
                  let newInput = try? AVCaptureDeviceInput(device: device)
            else {
                Logger.camera.error("Failed to flip camera: cannot access device at position \(newPosition.rawValue)")
                return
            }

            session.beginConfiguration()
            for input in session.inputs.compactMap({ $0 as? AVCaptureDeviceInput }) {
                session.removeInput(input)
            }
            if session.canAddInput(newInput) { session.addInput(newInput) }
            currentDevice = device
            session.commitConfiguration()
            Task { @MainActor in self.isDepthDataSupported = photoOutput.isDepthDataDeliverySupported }
            cleanupObservers()
            setupObservations(for: device)
            sessionQueue.asyncAfter(deadline: .now() + 0.15) { [self] in
                configureVideoRotation()
            }
        }
    }

    // MARK: - Still Capture

    /// - Parameter bypassBusyGuard: Set `true` for burst mode, which needs overlapping captures.
    func capturePhoto(delegate: AVCapturePhotoCaptureDelegate, bypassBusyGuard: Bool = false) {
        sessionQueue.async { [self] in
            guard bypassBusyGuard || !isCapturing else { return }
            if !bypassBusyGuard {
                Task { @MainActor in self.isCapturing = true }
            }
            let settings = makePhotoSettings(format: captureSettings.captureFormat)
            settings.flashMode = flashMode
            settings.photoQualityPrioritization = photoOutput.maxPhotoQualityPrioritization.rawValue >= AVCapturePhotoOutput.QualityPrioritization.quality.rawValue
                ? .quality
                : photoOutput.maxPhotoQualityPrioritization
            photoOutput.capturePhoto(with: settings, delegate: delegate)
        }
    }

    func capturePhotoBracketed(evStep: Float, delegate: AVCapturePhotoCaptureDelegate) {
        sessionQueue.async { [self] in
            guard !isCapturing else { return }
            Task { @MainActor in self.isCapturing = true }

            let offsets: [Float] = [-evStep, 0, evStep]
            let maxCount = photoOutput.maxBracketedCapturePhotoCount
            let bracketedSettings: [AVCaptureBracketedStillImageSettings] = offsets
                .prefix(maxCount)
                .map { AVCaptureAutoExposureBracketedStillImageSettings.autoExposureSettings(exposureTargetBias: $0) }

            let settings = AVCapturePhotoBracketSettings(
                rawPixelFormatType: 0,
                processedFormat: [AVVideoCodecKey: AVVideoCodecType.jpeg],
                bracketedSettings: bracketedSettings
            )
            settings.flashMode = flashMode
            photoOutput.capturePhoto(with: settings, delegate: delegate)
        }
    }

    /// Captures 3 shots sequentially at current K ± kStep, then current K.
    func capturePhotoBracketedWB(kStep: Float, delegate: AVCapturePhotoCaptureDelegate) {
        sessionQueue.async { [self] in
            guard !isCapturing else { return }
            Task { @MainActor in self.isCapturing = true }
            let baseK = captureSettings.whiteBalance
            let tint  = captureSettings.whiteBalanceTint
            let steps: [Float] = [-kStep, 0, kStep]
            let captureSettings = self.captureSettings
            for (i, step) in steps.enumerated() {
                sessionQueue.asyncAfter(deadline: .now() + Double(i) * 0.35) { [self] in
                    let k = (baseK + step).fxClamped(to: 2000...10000)
                    self.setWhiteBalance(kelvin: k, tint: tint)
                    let settings = self.makePhotoSettings(format: captureSettings.captureFormat)
                    settings.flashMode = self.flashMode
                    self.photoOutput.capturePhoto(with: settings, delegate: delegate)
                }
            }
        }
    }

    private func makePhotoSettings(format: CaptureFormat) -> AVCapturePhotoSettings {
        let settings: AVCapturePhotoSettings
        switch format {
        case .rawPlusJpeg:
            if let rawType = photoOutput.availableRawPhotoPixelFormatTypes.first {
                settings = AVCapturePhotoSettings(
                    rawPixelFormatType: rawType,
                    processedFormat: [AVVideoCodecKey: AVVideoCodecType.jpeg]
                )
            } else {
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            }
        case .raw:
            if let rawType = photoOutput.availableRawPhotoPixelFormatTypes.first {
                settings = AVCapturePhotoSettings(rawPixelFormatType: rawType, processedFormat: nil)
            } else {
                settings = AVCapturePhotoSettings()
            }
        case .jpeg:
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        }
        // Attach a Live Photo movie file URL when enabled
        if isLivePhotoEnabled && photoOutput.isLivePhotoCaptureEnabled {
            let liveURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("mov")
            settings.livePhotoMovieFileURL = liveURL
        }
        return settings
    }

    // MARK: - Video Rotation

    /// Tells AVFoundation to deliver portrait-upright frames to the video output.
    /// Must be called on sessionQueue, after session.commitConfiguration().
    private func configureVideoRotation() {
        let portraitAngle: CGFloat = 90
        if let conn = videoOutput.connection(with: .video),
           conn.isVideoRotationAngleSupported(portraitAngle) {
            conn.videoRotationAngle = portraitAngle
        }
    }

    // MARK: - Video Recording

    func startRecording() {
        sessionQueue.async { [self] in
            guard !isWaitingToRecord && assetWriter == nil else { return }
            isWaitingToRecord = true
            // AVAssetWriter is set up lazily on the first processed frame so we
            // know the actual CIImage dimensions after the full filter chain.
            processor.onProcessedFrame = { [weak self] ciImage, time in
                guard let self else { return }
                if self.isWaitingToRecord {
                    self.isWaitingToRecord = false
                    self.setupAssetWriter(firstImage: ciImage, startTime: time)
                } else {
                    self.appendVideoFrame(ciImage, time: time)
                }
            }
            audioOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        }
        Task { @MainActor in UIApplication.shared.isIdleTimerDisabled = true }
    }

    func stopRecording() {
        sessionQueue.async { [self] in
            isWaitingToRecord = false
            processor.onProcessedFrame = nil
            audioOutput.setSampleBufferDelegate(nil, queue: nil)
            guard let writer = assetWriter else { return }
            videoWriterInput?.markAsFinished()
            audioWriterInput?.markAsFinished()
            assetWriter = nil
            videoWriterInput = nil
            audioWriterInput = nil
            pixelBufferAdaptor = nil
            let outputURL = writer.outputURL
            writer.finishWriting {
                guard writer.status == .completed else {
                    Logger.camera.error("Video writing failed: \(writer.error?.localizedDescription ?? "unknown")")
                    return
                }
                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: outputURL)
                }, completionHandler: { _, error in
                    if let error { Logger.camera.error("Video save failed: \(error.localizedDescription)") }
                })
            }
            Task { @MainActor in
                self.isRecording = false
                self.recordingDuration = 0
                self.stopRecordingTimer()
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
    }

    @MainActor
    private func startRecordingTimer() {
        recordingTimer?.invalidate()
        recordingDuration = 0
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.recordingDuration += 1
        }
    }

    @MainActor
    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
    }

    private func setupAssetWriter(firstImage: CIImage, startTime: CMTime) {
        let extent = firstImage.extent
        let width = Int(extent.width)
        let height = Int(extent.height)
        let settings = captureSettings.videoSettings
        let fps = settings.frameRate

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")

        guard let writer = try? AVAssetWriter(url: url, fileType: .mp4) else {
            Logger.camera.error("Failed to create AVAssetWriter")
            return
        }

        // Video input
        let codecType: AVVideoCodecType = settings.codec == .h264 ? .h264 :
                                          settings.codec == .proRes && isProResRecordingSupported ? .proRes4444 : .hevc
        let compressionProps: [String: Any] = [
            AVVideoAverageBitRateKey: (width * height >= 3840 * 2160) ? 40_000_000 : 15_000_000,
            AVVideoMaxKeyFrameIntervalKey: fps,
            AVVideoExpectedSourceFrameRateKey: fps
        ]
        let videoOutputSettings: [String: Any] = [
            AVVideoCodecKey: codecType,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compressionProps
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoOutputSettings)
        videoInput.expectsMediaDataInRealTime = true

        let pixelAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: pixelAttrs
        )

        // Audio input
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
        audioInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
            Logger.camera.error("Cannot add inputs to AVAssetWriter")
            return
        }
        writer.add(videoInput)
        writer.add(audioInput)
        writer.startWriting()
        writer.startSession(atSourceTime: startTime)

        assetWriter = writer
        videoWriterInput = videoInput
        audioWriterInput = audioInput
        pixelBufferAdaptor = adaptor

        appendVideoFrame(firstImage, time: startTime)

        Task { @MainActor in
            self.isRecording = true
            self.startRecordingTimer()
        }
        Logger.camera.info("Video recording started: \(width)×\(height) \(fps)fps \(codecType.rawValue)")
    }

    private func appendVideoFrame(_ ciImage: CIImage, time: CMTime) {
        guard let input = videoWriterInput,
              let adaptor = pixelBufferAdaptor,
              let pool = adaptor.pixelBufferPool,
              input.isReadyForMoreMediaData else { return }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        guard let pixelBuffer = pb else { return }
        CIContext.shared.render(ciImage, to: pixelBuffer)
        adaptor.append(pixelBuffer, withPresentationTime: time)
    }

    /// Checks if the current device supports ProRes recording.
    var isProResRecordingSupported: Bool {
        guard let device = currentDevice else { return false }
        return device.formats.contains { format in
            let desc = format.formatDescription
            return CMFormatDescriptionGetMediaSubType(desc) == kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
        }
    }

    var isProResSupported: Bool { isProResRecordingSupported }

    // MARK: - Live Photo

    func toggleLivePhoto() {
        isLivePhotoEnabled.toggle()
    }

    // MARK: - Zoom Levels

    var availableZoomFactors: [CGFloat] {
        guard let device = currentDevice else { return [1.0] }
        let switchOvers = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat($0.doubleValue) }
        var factors: [CGFloat] = [1.0]
        // Insert 0.5× for ultrawide (zoom factor 1 on a triple/dual-wide system)
        let hasUltraWide = device.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
        if hasUltraWide { factors.insert(0.5, at: 0) }
        factors.append(contentsOf: switchOvers.filter { $0 > 1.0 })
        // Cap at 3 options for clean UI
        return Array(factors.prefix(3))
    }

    // MARK: - Macro Mode (Phase 6)

    var isMacroSupported: Bool {
        guard let device = currentDevice else { return false }
        return device.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
            && device.isCenterStageActive == false  // proxy for macro-capable device
    }

    func setMacroModeEnabled(_ enabled: Bool) {
        sessionQueue.async { [self] in
            guard let device = currentDevice else { return }
            device.withLock {
                if device.isAutoFocusRangeRestrictionSupported {
                    device.autoFocusRangeRestriction = enabled ? .near : .none
                }
            }
        }
    }

    // MARK: - Frame Rate

    func configureVideoFrameRate(_ fps: Int) {
        guard let device = currentDevice else { return }
        let targetFPS = Double(fps)
        let supportedRanges = device.activeFormat.videoSupportedFrameRateRanges
        guard supportedRanges.contains(where: { $0.maxFrameRate >= targetFPS }) else { return }
        let cmDuration = CMTimeMake(value: 1, timescale: Int32(targetFPS))
        device.withLock {
            device.activeVideoMinFrameDuration = cmDuration
            device.activeVideoMaxFrameDuration = cmDuration
        }
    }

    // MARK: - KVO Observations

    private func setupObservations(for device: AVCaptureDevice) {
        deviceObservations.forEach { $0.invalidate() }
        deviceObservations = [
            device.observe(\.iso, options: .new) { [weak self] d, _ in
                guard let self else { return }
                Task { @MainActor in
                    self.currentISO = d.iso
                    if self.captureSettings.isAutoISO == true {
                        self.captureSettings.isoValue = d.iso
                    }
                }
            },
            device.observe(\.exposureDuration, options: .new) { [weak self] d, _ in
                guard let self else { return }
                Task { @MainActor in
                    self.currentShutterSpeed = d.exposureDuration
                    if self.captureSettings.isAutoShutter == true {
                        self.captureSettings.shutterSpeed = d.exposureDuration
                    }
                }
            },
            device.observe(\.lensPosition, options: .new) { [weak self] d, _ in
                guard let self else { return }
                Task { @MainActor in
                    self.currentLensPosition = d.lensPosition
                    if self.captureSettings.isAutoFocus == true {
                        self.captureSettings.focusDistance = d.lensPosition
                    }
                }
            },
            device.observe(\.deviceWhiteBalanceGains, options: .new) { [weak self] d, _ in
                guard let self else { return }
                guard d.isAdjustingWhiteBalance == false else { return }
                let tnt = d.temperatureAndTintValues(for: d.deviceWhiteBalanceGains)
                Task { @MainActor in
                    self.currentWhiteBalance = tnt.temperature
                    self.currentWhiteBalanceTint = tnt.tint
                    if self.captureSettings.isAutoWhiteBalance == true {
                        self.captureSettings.whiteBalance = tnt.temperature
                        self.captureSettings.whiteBalanceTint = tnt.tint
                    }
                }
            }
        ]
    }
    
    // Clean up all observers
    func cleanupObservers() {
        deviceObservations.forEach { $0.invalidate() }
        deviceObservations.removeAll()
    }

    private func labelForDevice(_ device: AVCaptureDevice) -> String {
        switch device.deviceType {
        case .builtInUltraWideCamera: return "0.5×"
        case .builtInWideAngleCamera: return "1×"
        case .builtInTelephotoCamera: return "3×"
        default: return device.localizedName
        }
    }
}

// MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

extension CameraManager: AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        guard let input = audioWriterInput,
              input.isReadyForMoreMediaData,
              assetWriter?.status == .writing else { return }
        input.append(sampleBuffer)
    }
}

// MARK: - Supporting Types

struct LensOption: Identifiable {
    let id = UUID()
    let device: AVCaptureDevice
    let label: String
}

// MARK: - Comparable extensions

extension Comparable {
    func fxClamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - AVCaptureDevice lock helper

extension AVCaptureDevice {
    func withLock(_ body: () -> Void) {
        do {
            try lockForConfiguration()
            defer { unlockForConfiguration() }
            body()
        } catch {
            Logger.camera.error("lockForConfiguration failed: \(error.localizedDescription)")
        }
    }
}
