import AVFoundation
import CoreImage
import Observation

@Observable
final class CameraManager: NSObject {
    // MARK: - Published state (MainActor)
    var isSessionRunning = false
    var currentISO: Float = 200
    var currentShutterSpeed: CMTime = CMTimeMake(value: 1, timescale: 250)
    var currentWhiteBalance: Float = 5500
    var currentLensPosition: Float = 0.5
    var currentZoomFactor: CGFloat = 1.0
    var availableLenses: [LensOption] = []
    var flashMode: AVCaptureDevice.FlashMode = .off
    var isCapturing = false
    var lastCapturedPhoto: CapturedPhoto?

    // MARK: - Internal (sessionQueue only)
    let processor = CaptureProcessor()
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.fexer.session", qos: .userInteractive)
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var currentDevice: AVCaptureDevice?
    private var deviceObservations: [NSKeyValueObservation] = []

    var captureSettings = CaptureSettings()

    // MARK: - Setup

    func startSession() {
        sessionQueue.async { [self] in
            guard !session.isRunning else { return }
            self.configureSession()
            self.session.startRunning()
            Task { @MainActor in self.isSessionRunning = true }
        }
    }

    func stopSession() {
        sessionQueue.async { [self] in
            self.session.stopRunning()
            Task { @MainActor in self.isSessionRunning = false }
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

        photoOutput.isHighResolutionCaptureEnabled = true
        photoOutput.maxPhotoQualityPrioritization = .quality
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }

        session.commitConfiguration()
        setupObservations(for: device)
    }

    // MARK: - Manual Controls (call on any thread; executes on sessionQueue)

    func setISO(_ iso: Float) {
        sessionQueue.async { [self] in
            guard let device = currentDevice else { return }
            let clamped = iso.fxClamped(to: device.activeFormat.minISO...device.activeFormat.maxISO)
            try? device.lockForConfiguration()
            device.setExposureModeCustom(duration: device.exposureDuration, iso: clamped, completionHandler: nil)
            device.unlockForConfiguration()
        }
    }

    func setShutterSpeed(_ duration: CMTime) {
        sessionQueue.async { [self] in
            guard let device = currentDevice else { return }
            let min = device.activeFormat.minExposureDuration
            let max = device.activeFormat.maxExposureDuration
            let clamped = CMTimeClampToRange(duration, range: CMTimeRange(start: min, end: max))
            try? device.lockForConfiguration()
            device.setExposureModeCustom(duration: clamped, iso: device.iso, completionHandler: nil)
            device.unlockForConfiguration()
        }
    }

    func setWhiteBalance(kelvin: Float) {
        sessionQueue.async { [self] in
            guard let device = currentDevice else { return }
            let tnt = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: kelvin, tint: 0)
            var gains = device.deviceWhiteBalanceGains(for: tnt)
            let maxGain = device.maxWhiteBalanceGain
            gains.redGain   = gains.redGain.fxClamped(to: 1.0...maxGain)
            gains.greenGain = gains.greenGain.fxClamped(to: 1.0...maxGain)
            gains.blueGain  = gains.blueGain.fxClamped(to: 1.0...maxGain)
            try? device.lockForConfiguration()
            device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
            device.unlockForConfiguration()
        }
    }

    func setFocus(lensPosition: Float) {
        sessionQueue.async { [self] in
            guard let device = currentDevice else { return }
            try? device.lockForConfiguration()
            device.setFocusModeLocked(lensPosition: lensPosition.fxClamped(to: 0...1), completionHandler: nil)
            device.unlockForConfiguration()
        }
    }

    func setFocusPoint(_ point: CGPoint) {
        sessionQueue.async { [self] in
            guard let device = currentDevice else { return }
            try? device.lockForConfiguration()
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = point
                device.focusMode = .autoFocus
            }
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = point
                device.exposureMode = .autoExpose
            }
            device.unlockForConfiguration()
        }
    }

    func setExposureCompensation(_ bias: Float) {
        sessionQueue.async { [self] in
            guard let device = currentDevice else { return }
            let clamped = bias.fxClamped(to: device.minExposureTargetBias...device.maxExposureTargetBias)
            try? device.lockForConfiguration()
            device.setExposureTargetBias(clamped, completionHandler: nil)
            device.unlockForConfiguration()
        }
    }

    func setZoom(_ factor: CGFloat) {
        sessionQueue.async { [self] in
            guard let device = currentDevice else { return }
            let clamped = factor.fxClamped(
                to: device.minAvailableVideoZoomFactor...device.maxAvailableVideoZoomFactor
            )
            try? device.lockForConfiguration()
            device.videoZoomFactor = clamped
            device.unlockForConfiguration()
            Task { @MainActor in self.currentZoomFactor = clamped }
        }
    }

    func setAutoExposure() {
        sessionQueue.async { [self] in
            guard let device = currentDevice else { return }
            try? device.lockForConfiguration()
            device.exposureMode = .continuousAutoExposure
            device.unlockForConfiguration()
        }
    }

    func setAutoFocus() {
        sessionQueue.async { [self] in
            guard let device = currentDevice else { return }
            try? device.lockForConfiguration()
            device.focusMode = .continuousAutoFocus
            device.unlockForConfiguration()
        }
    }

    func setAutoWhiteBalance() {
        sessionQueue.async { [self] in
            guard let device = currentDevice else { return }
            try? device.lockForConfiguration()
            device.whiteBalanceMode = .continuousAutoWhiteBalance
            device.unlockForConfiguration()
        }
    }

    func flipCamera() {
        sessionQueue.async { [self] in
            let currentPosition = currentDevice?.position ?? .back
            let newPosition: AVCaptureDevice.Position = currentPosition == .back ? .front : .back
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: newPosition),
                  let newInput = try? AVCaptureDeviceInput(device: device)
            else { return }

            session.beginConfiguration()
            session.inputs.forEach { session.removeInput($0) }
            if session.canAddInput(newInput) { session.addInput(newInput) }
            currentDevice = device
            session.commitConfiguration()
            setupObservations(for: device)
        }
    }

    // MARK: - Still Capture

    func capturePhoto(delegate: AVCapturePhotoCaptureDelegate) {
        sessionQueue.async { [self] in
            guard !isCapturing else { return }
            Task { @MainActor in self.isCapturing = true }

            var settings: AVCapturePhotoSettings
            if captureSettings.captureFormat == .jpeg || captureSettings.captureFormat == .rawPlusJpeg {
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            } else {
                settings = AVCapturePhotoSettings()
            }
            settings.flashMode = flashMode
            settings.photoQualityPrioritization = .quality

            photoOutput.capturePhoto(with: settings, delegate: delegate)
        }
    }

    // MARK: - KVO Observations

    private func setupObservations(for device: AVCaptureDevice) {
        deviceObservations.forEach { $0.invalidate() }
        deviceObservations = [
            device.observe(\.iso, options: .new) { [weak self] d, _ in
                Task { @MainActor in self?.currentISO = d.iso }
            },
            device.observe(\.exposureDuration, options: .new) { [weak self] d, _ in
                Task { @MainActor in self?.currentShutterSpeed = d.exposureDuration }
            },
            device.observe(\.lensPosition, options: .new) { [weak self] d, _ in
                Task { @MainActor in self?.currentLensPosition = d.lensPosition }
            },
            device.observe(\.deviceWhiteBalanceGains, options: .new) { [weak self] d, _ in
                guard d.isAdjustingWhiteBalance == false else { return }
                let tnt = d.temperatureAndTintValues(for: d.deviceWhiteBalanceGains)
                Task { @MainActor in self?.currentWhiteBalance = tnt.temperature }
            }
        ]
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
