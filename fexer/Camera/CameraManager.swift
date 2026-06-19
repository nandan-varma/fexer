import AVFoundation
import CoreImage
import Observation
import OSLog
import Foundation
import UIKit

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

    // MARK: - Internal (sessionQueue only)
    let processor = CaptureProcessor()
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.fexer.session", qos: .userInteractive)
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var currentDevice: AVCaptureDevice?
    private var deviceObservations: [NSKeyValueObservation] = []

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
        else { session.commitConfiguration(); return }

        if session.canAddInput(input) { session.addInput(input) }
        currentDevice = device

        videoOutput.setSampleBufferDelegate(processor, queue: sessionQueue)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }

        // Live Photo requires the capture to be enabled before commitConfiguration
        if photoOutput.isLivePhotoCaptureSupported {
            photoOutput.isLivePhotoCaptureEnabled = true
        }

        if session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
            if let conn = movieOutput.connection(with: .video),
               conn.isVideoStabilizationSupported {
                conn.preferredVideoStabilizationMode = .auto
            }
        }

        session.commitConfiguration()

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
    func setFocusPoint(_ point: CGPoint) {
        sessionQueue.async { [self] in
            guard let device = currentDevice else {
                Logger.camera.error("Cannot set focus point: no camera device available")
                return
            }
            device.withLock {
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = point
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = point
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
            device.withLock {
                device.focusMode = .continuousAutoFocus
            }
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
                if device.isExposurePointOfInterestSupported {
                    switch mode {
                    case .matrix, .center:
                        device.exposurePointOfInterest = CGPoint(x: 0.5, y: 0.5)
                        device.exposureMode = .continuousAutoExposure
                    case .spot:
                        device.exposureMode = .continuousAutoExposure
                    }
                }
            }
            Task { @MainActor in self.captureSettings.meteringMode = mode }
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
            cleanupObservers()
            setupObservations(for: device)
            sessionQueue.asyncAfter(deadline: .now() + 0.15) { [self] in
                configureVideoRotation()
            }
        }
    }

    // MARK: - Still Capture

    func capturePhoto(delegate: AVCapturePhotoCaptureDelegate) {
        sessionQueue.async { [self] in
            guard !isCapturing else { return }
            Task { @MainActor in self.isCapturing = true }

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
        if let conn = movieOutput.connection(with: .video),
           conn.isVideoRotationAngleSupported(portraitAngle) {
            conn.videoRotationAngle = portraitAngle
        }
    }

    // MARK: - Video Recording

    func startRecording() {
        sessionQueue.async { [self] in
            guard !movieOutput.isRecording else { return }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("mov")
            movieOutput.startRecording(to: url, recordingDelegate: self)
            // isRecording is set in the delegate callback once recording actually starts
        }
        Task { @MainActor in
            UIApplication.shared.isIdleTimerDisabled = true
        }
    }

    func stopRecording() {
        sessionQueue.async { [self] in
            guard movieOutput.isRecording else { return }
            movieOutput.stopRecording()
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

// MARK: - AVCaptureFileOutputRecordingDelegate

extension CameraManager: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput,
                                didStartRecordingTo fileURL: URL,
                                from connections: [AVCaptureConnection]) {
        Task { @MainActor in
            self.isRecording = true
            self.startRecordingTimer()
        }
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput,
                                didFinishRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection],
                                error: Error?) {
        if let error {
            Logger.camera.error("Video recording failed: \(error.localizedDescription)")
        }
        Task { @MainActor in
            self.isRecording = false
            self.recordingDuration = 0
            self.stopRecordingTimer()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        // Save to Photos library on a background thread
        UISaveVideoAtPathToSavedPhotosAlbum(outputFileURL.path, nil, nil, nil)
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
        guard (try? lockForConfiguration()) != nil else { return }
        defer { unlockForConfiguration() }
        body()
    }
}
