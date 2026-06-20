import AVFoundation
import CoreImage
import CoreLocation
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
    var isAppleLogSupported: Bool = false
    var isHDRFormatSupported: Bool = false
    var isSlowMotionSupported: Bool = false
    var maxSlowMotionFPS: Int = 60

    // Live audio level (updated ~10fps while recording, 0.0=silence 1.0=peak)
    var audioLevel: Float = 0.0

    // Trap focus: when true, fire shutter the moment isAdjustingFocus → false
    var pendingTrapFocusFire: Bool = false

    // MARK: - Internal (sessionQueue only)
    let processor = CaptureProcessor()
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.fexer.session", qos: .userInteractive)
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private(set) var currentDevice: AVCaptureDevice?
    private var deviceObservations: [NSKeyValueObservation] = []
    private var subjectAreaObserver: NSObjectProtocol?
    private var trapFocusCaptureCallback: (() -> Void)?
    private var pendingCompassHeading: CLHeading?

    // AVAssetWriter recording pipeline — accessed from sessionQueue AND nonisolated audio delegate,
    // so nonisolated(unsafe). All mutations are serialised through sessionQueue.
    private var assetWriter: AVAssetWriter?
    private var videoWriterInput: AVAssetWriterInput?
    private var audioWriterInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var isWaitingToRecord = false
    private let audioOutput = AVCaptureAudioDataOutput()
    // Captured at startRecording() call site (MainActor) and consumed on sessionQueue.
    private var pendingRecordingLocation: CLLocation?
    private var pendingRecordingStyleName: String?

    // Timer runs on MainActor; kept here so we can invalidate from MainActor context
    private var recordingTimer: Timer?

    var captureSettings = CaptureSettings()

    @ObservationIgnored private lazy var iso8601Formatter = ISO8601DateFormatter()

    // MARK: - Notification observation tokens

    private var sessionErrorObserver: NSObjectProtocol?
    private var sessionInterruptionObserver: NSObjectProtocol?
    private var sessionInterruptionEndedObserver: NSObjectProtocol?

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
            // Observe runtime errors for session recovery (correct notification name).
            self.sessionErrorObserver = NotificationCenter.default.addObserver(
                forName: AVCaptureSession.runtimeErrorNotification,
                object: session,
                queue: .main
            ) { [weak self] notification in
                self?.handleSessionError(notification)
            }
            // Restart after interruptions (permission dialogs, phone calls, background, etc.)
            self.sessionInterruptionEndedObserver = NotificationCenter.default.addObserver(
                forName: AVCaptureSession.interruptionEndedNotification,
                object: session,
                queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                sessionQueue.async {
                    if !self.session.isRunning {
                        self.session.startRunning()
                    }
                    // Re-apply rotation in case connection was reset during interruption.
                    self.configureVideoRotation()
                    self.processor.isRotationReady = true
                    Task { @MainActor in self.isSessionRunning = self.session.isRunning }
                }
            }
            // Defer video rotation so the connection stabilises after startRunning.
            // Setting videoRotationAngle immediately can trigger Fig err=-12710.
            // Frames are dropped until this fires (isRotationReady gate in CaptureProcessor).
            self.sessionQueue.asyncAfter(deadline: .now() + 0.15) { [self] in
                self.configureVideoRotation()
                self.processor.isRotationReady = true
            }
        }
    }

    /// Stops the camera session and releases all resources.
    ///
    /// This method stops the video capture pipeline, removes all observers,
    /// and cleans up the session. It can be called multiple times safely.
    func stopSession() {
        sessionQueue.async { [self] in
            [sessionErrorObserver, sessionInterruptionObserver, sessionInterruptionEndedObserver]
                .compactMap { $0 }
                .forEach { NotificationCenter.default.removeObserver($0) }
            sessionErrorObserver = nil
            sessionInterruptionObserver = nil
            sessionInterruptionEndedObserver = nil
            processor.isRotationReady = false
            self.session.stopRunning()
            Task { @MainActor in self.isSessionRunning = false }
        }
    }

    deinit {
        [sessionErrorObserver, sessionInterruptionObserver, sessionInterruptionEndedObserver]
            .compactMap { $0 }
            .forEach { NotificationCenter.default.removeObserver($0) }
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

        let appleLogOK = device.formats.contains {
            $0.supportedColorSpaces.contains(.appleLog)
        }
        let hdrOK = device.formats.contains {
            $0.isVideoHDRSupported
        }
        let slowMoFPS = device.formats
            .flatMap { $0.videoSupportedFrameRateRanges }
            .filter { $0.maxFrameRate > 60 }
            .map { Int($0.maxFrameRate) }
            .max() ?? 0
        Task { @MainActor in
            self.isProRAWSupported = photoOutput.isAppleProRAWSupported
            self.isDepthDataSupported = photoOutput.isDepthDataDeliverySupported
            self.isAppleLogSupported = appleLogOK
            self.isHDRFormatSupported = hdrOK
            self.isSlowMotionSupported = slowMoFPS > 60
            self.maxSlowMotionFPS = max(60, slowMoFPS)
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
            var target = factor
            // Optical zoom lock: snap to nearest glass-only stop
            if captureSettings.isOpticalZoomLocked {
                let stops = availableZoomFactors
                target = stops.min(by: { abs($0 - factor) < abs($1 - factor) }) ?? factor
            }
            let clamped = target.fxClamped(
                to: device.minAvailableVideoZoomFactor...device.maxAvailableVideoZoomFactor
            )
            device.withLock {
                if isRecording {
                    // Smooth ramp during recording to avoid jarring jump
                    device.ramp(toVideoZoomFactor: clamped, withRate: 4.0)
                } else {
                    device.videoZoomFactor = clamped
                }
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
                    // Bias AE to protect highlights: lock to upper-frame interest point
                    // and use continuousAutoExposure so it tracks a moving scene.
                    if device.isExposurePointOfInterestSupported {
                        device.exposurePointOfInterest = CGPoint(x: 0.5, y: 0.15)
                    }
                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
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
            processor.isRotationReady = false
            session.commitConfiguration()
            Task { @MainActor in self.isDepthDataSupported = photoOutput.isDepthDataDeliverySupported }
            cleanupObservers()
            setupObservations(for: device)
            sessionQueue.asyncAfter(deadline: .now() + 0.15) { [self] in
                configureVideoRotation()
                processor.isRotationReady = true
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
        case .heif:
            // Default format = HEIF on all modern iPhones — hardware HEVC encoder, ~40% smaller files
            settings = AVCapturePhotoSettings()
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

    func startRecording(location: CLLocation? = nil, styleName: String? = nil) {
        pendingRecordingLocation = location
        pendingRecordingStyleName = styleName
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
            let savedLocation = pendingRecordingLocation
            pendingRecordingLocation = nil
            pendingRecordingStyleName = nil
            writer.finishWriting {
                guard writer.status == .completed else {
                    Logger.camera.error("Video writing failed: \(writer.error?.localizedDescription ?? "unknown")")
                    return
                }
                PHPhotoLibrary.shared().performChanges({
                    let request = PHAssetCreationRequest.forAsset()
                    let options = PHAssetResourceCreationOptions()
                    options.shouldMoveFile = true
                    request.addResource(with: .video, fileURL: outputURL, options: options)
                    request.location = savedLocation
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

        let codec = settings.codec
        let useProRes = codec == .proRes && isProResRecordingSupported
        let fileExt  = useProRes ? "mov" : "mp4"
        let fileType = useProRes ? AVFileType.mov : AVFileType.mp4

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExt)

        guard let writer = try? AVAssetWriter(url: url, fileType: fileType) else {
            Logger.camera.error("Failed to create AVAssetWriter")
            return
        }

        // Video codec — ProRes skips compression properties (uses its own quality tiers)
        let codecType: AVVideoCodecType = codec == .h264 ? .h264 :
                                          useProRes ? .proRes4444 : .hevc
        var videoOutputSettings: [String: Any] = [
            AVVideoCodecKey: codecType,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        if codecType != .proRes4444 {
            videoOutputSettings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: settings.videoBitRate,
                AVVideoMaxKeyFrameIntervalKey: fps,
                AVVideoExpectedSourceFrameRateKey: fps
            ] as [String: Any]
        }
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

        // Audio input — AAC at sample rate and bitrate scaled to resolution
        let audioOutputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: settings.audioSampleRate,
            AVEncoderBitRateKey: settings.audioBitRate
        ]
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioOutputSettings)
        audioInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
            Logger.camera.error("Cannot add inputs to AVAssetWriter")
            return
        }
        writer.add(videoInput)
        writer.add(audioInput)
        writer.metadata = makeVideoMetadata(
            settings: captureSettings,
            location: pendingRecordingLocation,
            styleName: pendingRecordingStyleName
        )
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

    private func makeVideoMetadata(
        settings: CaptureSettings,
        location: CLLocation?,
        styleName: String?
    ) -> [AVMetadataItem] {
        var items: [AVMutableMetadataItem] = []

        func item(identifier: AVMetadataIdentifier, value: NSObject & NSCopying) -> AVMutableMetadataItem {
            let i = AVMutableMetadataItem()
            i.identifier = identifier
            i.value = value
            i.extendedLanguageTag = "und"
            return i
        }

        items.append(item(identifier: .quickTimeMetadataCreationDate,
                          value: iso8601Formatter.string(from: Date()) as NSString))
        items.append(item(identifier: .quickTimeMetadataMake,  value: "Apple" as NSString))
        items.append(item(identifier: .quickTimeMetadataModel, value: UIDevice.current.model as NSString))
        items.append(item(identifier: .quickTimeMetadataSoftware, value: "fexer" as NSString))

        if let location {
            let lat = location.coordinate.latitude
            let lon = location.coordinate.longitude
            let iso6709: String
            if location.verticalAccuracy >= 0 {
                iso6709 = String(format: "%+.4f%+.5f%+.0f/", lat, lon, location.altitude)
            } else {
                iso6709 = String(format: "%+.4f%+.5f/", lat, lon)
            }
            items.append(item(identifier: .quickTimeMetadataLocationISO6709, value: iso6709 as NSString))
        }

        // Camera capture settings as custom QuickTime metadata (mdta keyspace)
        func custom(key: String, value: NSObject & NSCopying) -> AVMutableMetadataItem {
            let i = AVMutableMetadataItem()
            i.keySpace = .quickTimeMetadata
            i.key = key as NSString
            i.value = value
            return i
        }
        items.append(custom(key: "com.fexer.camera.iso",
                            value: Int(settings.isoValue) as NSNumber))
        items.append(custom(key: "com.fexer.camera.shutterSpeed",
                            value: CaptureSettings.formatShutterSpeed(
                                CMTimeGetSeconds(settings.shutterSpeed)) as NSString))
        items.append(custom(key: "com.fexer.camera.whiteBalanceKelvin",
                            value: Int(settings.whiteBalance) as NSNumber))
        items.append(custom(key: "com.fexer.camera.whiteBalanceTint",
                            value: Int(settings.whiteBalanceTint) as NSNumber))
        items.append(custom(key: "com.fexer.camera.aperture",
                            value: String(format: "f/%.1f", settings.lensAperture) as NSString))
        if let name = styleName {
            items.append(custom(key: "com.fexer.style", value: name as NSString))
        }
        // Compass bearing
        if let heading = pendingCompassHeading {
            items.append(custom(key: "com.fexer.camera.compassBearing",
                                value: String(format: "%.1f°", heading.trueHeading) as NSString))
        }
        return items
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
    /// Checks for 10-bit YCbCr capture formats, which ship only on ProRes-capable iPhones (13 Pro+).
    var isProResRecordingSupported: Bool {
        guard let device = currentDevice else { return false }
        return device.formats.contains { format in
            let sub = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            return sub == kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange ||
                   sub == kCVPixelFormatType_422YpCbCr10BiPlanarFullRange
        }
    }

    // MARK: - Video mode session preset

    /// Reconfigures the capture session for video recording at the specified resolution.
    /// Must NOT be called while recording is active.
    func configureForVideoMode(resolution: VideoResolution) {
        sessionQueue.async { [self] in
            guard !isRecording, !isWaitingToRecord else { return }
            let preset = resolution.sessionPreset
            session.beginConfiguration()
            if session.canSetSessionPreset(preset) {
                session.sessionPreset = preset
            } else {
                session.sessionPreset = .hd1920x1080
                Logger.camera.warning("4K preset unsupported on this device, falling back to 1080p")
            }
            session.commitConfiguration()
            configureVideoRotation()
            Task { @MainActor in self.captureSettings.videoSettings.resolution = resolution }
        }
    }

    /// Restores the capture session preset to `.photo` (for still capture modes).
    func configureForPhotoMode() {
        sessionQueue.async { [self] in
            guard !isRecording else { return }
            session.beginConfiguration()
            session.sessionPreset = .photo
            session.commitConfiguration()
        }
    }

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
        return factors
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

    // MARK: - Torch

    func setTorch(on: Bool, level: Float = 1.0) {
        sessionQueue.async { [self] in
            guard let device = currentDevice, device.hasTorch, device.isTorchAvailable else { return }
            device.withLock {
                if on {
                    let clamped = level.fxClamped(to: 0.01...1.0)
                    try? device.setTorchModeOn(level: clamped)
                } else {
                    device.torchMode = .off
                }
            }
            Task { @MainActor in
                self.captureSettings.isTorchOn = on
                self.captureSettings.torchLevel = level
            }
        }
    }

    var isTorchAvailable: Bool { currentDevice?.hasTorch == true && currentDevice?.isTorchAvailable == true }

    // MARK: - Video Stabilization

    func setVideoStabilizationMode(_ mode: StabilizationMode) {
        sessionQueue.async { [self] in
            if let conn = videoOutput.connection(with: .video) {
                let preferred = mode.avMode
                conn.preferredVideoStabilizationMode = preferred
            }
            Task { @MainActor in self.captureSettings.stabilizationMode = mode }
        }
    }

    // MARK: - Color Space / Apple Log / HDR

    func setVideoColorSpace(_ colorSpace: VideoColorSpace) {
        sessionQueue.async { [self] in
            guard let device = currentDevice else { return }
            let target: AVCaptureColorSpace = {
                switch colorSpace {
                case .sRGB:     return .sRGB
                case .p3:       return .P3_D65
                case .hlg:      return .HLG_BT2020
                case .appleLog:
                    if #available(iOS 17, *) { return .appleLog }
                    return .sRGB
                }
            }()
            guard device.activeFormat.supportedColorSpaces.contains(target) else {
                Logger.camera.warning("Color space \(colorSpace.rawValue) not supported by active format")
                return
            }
            device.withLock { device.activeColorSpace = target }
            Task { @MainActor in self.captureSettings.videoColorSpace = colorSpace }
        }
    }

    func setHDREnabled(_ enabled: Bool) {
        sessionQueue.async { [self] in
            guard let conn = videoOutput.connection(with: .video) else { return }
            // isVideoHDREnabled is a connection-level property
            if #available(iOS 16, *) {
                // HDR is format-driven; select an HDR-capable format when enabling
                if enabled, let device = currentDevice {
                    let hdrFormat = device.formats.first {
                        $0.isVideoHDRSupported &&
                        CMVideoFormatDescriptionGetDimensions($0.formatDescription).width >= 1920
                    }
                    if let fmt = hdrFormat {
                        device.withLock { device.activeFormat = fmt }
                    }
                }
            }
            Task { @MainActor in self.captureSettings.isHDREnabled = enabled }
        }
    }

    // MARK: - Smooth Zoom Ramp (video only)

    /// Animates zoom to `factor` at `rate` (0.5 = slow, 10 = fast). Use during recording
    /// to avoid the jarring jump of a direct videoZoomFactor assignment.
    func rampZoom(to factor: CGFloat, rate: Float = 3.0) {
        sessionQueue.async { [self] in
            guard let device = currentDevice else { return }
            let clamped = factor.fxClamped(
                to: device.minAvailableVideoZoomFactor...device.maxAvailableVideoZoomFactor
            )
            device.withLock { device.ramp(toVideoZoomFactor: clamped, withRate: rate) }
            Task { @MainActor in self.currentZoomFactor = clamped }
        }
    }

    /// Cancels an in-progress smooth zoom ramp.
    func cancelZoomRamp() {
        sessionQueue.async { [self] in
            guard let device = currentDevice else { return }
            device.withLock { device.cancelVideoZoomRamp() }
        }
    }

    // MARK: - Optical Zoom Lock

    /// Returns the nearest optical zoom switchover factor to `factor`, or `factor` itself.
    func nearestOpticalFactor(_ factor: CGFloat) -> CGFloat {
        let stops = availableZoomFactors
        return stops.min(by: { abs($0 - factor) < abs($1 - factor) }) ?? factor
    }

    // MARK: - Slow Motion

    /// Activates a high-frame-rate format for slow-motion capture.
    /// Call this when entering slow-mo mode, then configure frame rate via configureVideoFrameRate.
    func configureForSlowMotion(fps: Int) {
        sessionQueue.async { [self] in
            guard let device = currentDevice else { return }
            let targetFPS = Double(fps)
            // Find a 1080p format supporting the target frame rate
            let candidate = device.formats.first { format in
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                return dims.width == 1920 &&
                    format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= targetFPS }
            }
            guard let fmt = candidate else {
                Logger.camera.warning("No format found for \(fps)fps slow motion")
                return
            }
            session.beginConfiguration()
            device.withLock {
                device.activeFormat = fmt
                let dur = CMTimeMake(value: 1, timescale: Int32(targetFPS))
                device.activeVideoMinFrameDuration = dur
                device.activeVideoMaxFrameDuration = dur
            }
            session.commitConfiguration()
            configureVideoRotation()
        }
    }

    // MARK: - Trap Focus

    /// Registers a callback to fire the moment the camera locks focus.
    /// Used by trap focus mode: set this before the subject enters frame.
    func setTrapFocusCallback(_ callback: @escaping () -> Void) {
        Task { @MainActor in trapFocusCaptureCallback = callback }
    }

    func clearTrapFocusCallback() {
        Task { @MainActor in trapFocusCaptureCallback = nil }
    }

    // MARK: - Focus Distance (approximate physical distance)

    /// Returns approximate focus distance in cm from normalised lens position.
    /// Uses device.minimumFocusDistance (in mm) as the closest-focus anchor.
    /// Formula: at lensPosition=1, dist ≈ minFocusDist; at lensPosition=0, dist ≈ ∞.
    func approximateFocusDistance(lensPosition: Float) -> String {
        guard let device = currentDevice, lensPosition > 0.01 else { return "∞" }
        let minCm = Float(device.minimumFocusDistance) / 10.0
        // Hyperbolic mapping: distance ≈ minCm / position (crude but consistent)
        let distCm = minCm / lensPosition
        if distCm >= 1000 { return "∞" }
        if distCm >= 100  { return String(format: "%.1fm", distCm / 100.0) }
        return String(format: "%.0fcm", distCm)
    }

    // MARK: - Record + Photo simultaneously

    /// Captures a still photo while video recording is active.
    /// Uses bypassBusyGuard so the capture doesn't block on isCapturing.
    func capturePhotoWhileRecording(delegate: AVCapturePhotoCaptureDelegate) {
        guard isRecording else { return }
        capturePhoto(delegate: delegate, bypassBusyGuard: true)
    }

    // MARK: - Compass heading for metadata

    func setCompassHeading(_ heading: CLHeading) {
        pendingCompassHeading = heading
    }

    // MARK: - Frame Rate

    func configureVideoFrameRate(_ fps: Int) {
        sessionQueue.async { [self] in
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
    }

    /// Returns the frame rates actually supported by the device at the given resolution.
    /// Reads from the device format that matches the session preset, so the UI shows
    /// only valid options instead of a hardcoded list.
    func supportedFrameRates(for resolution: VideoResolution) -> [Int] {
        let candidates = [24, 30, 60, 120, 240]
        guard let device = currentDevice else { return [24, 30, 60] }
        let preset = resolution.sessionPreset
        // Find a format whose dimensions match the preset and collect its max FPS.
        let targetDims: (Int32, Int32) = preset == .hd4K3840x2160 ? (3840, 2160) : (1920, 1080)
        let matchingFormats = device.formats.filter { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return dims.width == targetDims.0 && dims.height == targetDims.1
        }
        let maxFPS = matchingFormats.flatMap { $0.videoSupportedFrameRateRanges }
                                    .map { Int($0.maxFrameRate) }
                                    .max() ?? 60
        return candidates.filter { $0 <= maxFPS }
    }

    // MARK: - KVO Observations

    private func setupObservations(for device: AVCaptureDevice) {
        deviceObservations.forEach { $0.invalidate() }
        subjectAreaObserver.map { NotificationCenter.default.removeObserver($0) }
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
            },
            device.observe(\.exposureTargetOffset, options: .new) { [weak self] d, _ in
                guard let self else { return }
                Task { @MainActor in
                    self.captureSettings.exposureTargetOffset = d.exposureTargetOffset
                }
            },
            device.observe(\.lensAperture, options: .new) { [weak self] d, _ in
                guard let self else { return }
                Task { @MainActor in
                    self.captureSettings.lensAperture = d.lensAperture
                }
            },
            device.observe(\.isAdjustingFocus, options: [.new, .old]) { [weak self] d, change in
                guard let self else { return }
                // Trap focus: fire shutter when camera finishes adjusting focus
                let wasAdjusting = change.oldValue ?? true
                let isAdjusting  = change.newValue ?? true
                if wasAdjusting && !isAdjusting {
                    Task { @MainActor in
                        if self.captureSettings.isTrapFocusEnabled {
                            self.trapFocusCaptureCallback?()
                        }
                    }
                }
            }
        ]

        // Subject area change — device notifies when the scene shifts enough to warrant refocus
        subjectAreaObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.subjectAreaDidChangeNotification,
            object: device,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.captureSettings.focusDistance = self.currentLensPosition }
        }
        device.withLock { device.isSubjectAreaChangeMonitoringEnabled = true }
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
        // Write to asset when recording
        if let input = audioWriterInput,
           input.isReadyForMoreMediaData,
           assetWriter?.status == .writing {
            input.append(sampleBuffer)
        }

        // Compute RMS audio level for the VU meter (~10fps update cadence)
        guard let channelData = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(channelData, atOffset: 0,
                                    lengthAtOffsetOut: nil, totalLengthOut: &length,
                                    dataPointerOut: &dataPointer)
        guard let ptr = dataPointer, length > 0 else { return }
        let sampleCount = length / MemoryLayout<Int16>.size
        let int16Ptr = UnsafeRawPointer(ptr).bindMemory(to: Int16.self, capacity: sampleCount)
        var sumSq: Float = 0
        for i in 0..<sampleCount {
            let s = Float(int16Ptr[i]) / Float(Int16.max)
            sumSq += s * s
        }
        let rms = sampleCount > 0 ? sqrt(sumSq / Float(sampleCount)) : 0
        // Update at ~10fps (every ~4800 samples at 48kHz)
        Task { @MainActor in self.audioLevel = self.audioLevel * 0.7 + rms * 0.3 }
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
