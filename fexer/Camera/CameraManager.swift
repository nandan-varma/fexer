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

        guard let device = bestDevice(for: .back),
              let input = try? AVCaptureDeviceInput(device: device)
        else { session.commitConfiguration(); return }

        if session.canAddInput(input) { session.addInput(input) }
        currentDevice = device

        videoOutput.setSampleBufferDelegate(processor, queue: sessionQueue)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        photoOutput.maxPhotoQualityPrioritization = .quality
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        if #available(iOS 16.0, *) {
            if let maxDim = device.activeFormat.supportedMaxPhotoDimensions.last {
                photoOutput.maxPhotoDimensions = maxDim
            }
        } else {
            photoOutput.isHighResolutionCaptureEnabled = true
        }

        session.commitConfiguration()

        // Rotate frames to portrait so CIImage arrives upright
        configureVideoRotation()
        setupObservations(for: device)
    }

    // MARK: - Manual Controls (call on any thread; executes on sessionQueue)

    func setISO(_ iso: Float) {
        sessionQueue.async { [self] in
            guard let device = currentDevice,
                  device.isExposureModeSupported(.custom) else { return }
            let clamped = iso.fxClamped(to: device.activeFormat.minISO...device.activeFormat.maxISO)
            try? device.lockForConfiguration()
            device.setExposureModeCustom(duration: AVCaptureDevice.currentExposureDuration,
                                         iso: clamped, completionHandler: nil)
            device.unlockForConfiguration()
        }
    }

    func setShutterSpeed(_ duration: CMTime) {
        sessionQueue.async { [self] in
            guard let device = currentDevice,
                  device.isExposureModeSupported(.custom) else { return }
            let min = device.activeFormat.minExposureDuration
            let max = device.activeFormat.maxExposureDuration
            let clamped = CMTimeClampToRange(duration, range: CMTimeRange(start: min, end: max))
            try? device.lockForConfiguration()
            device.setExposureModeCustom(duration: clamped,
                                         iso: AVCaptureDevice.currentISO, completionHandler: nil)
            device.unlockForConfiguration()
        }
    }

    func setWhiteBalance(kelvin: Float) {
        sessionQueue.async { [self] in
            guard let device = currentDevice,
                  device.isWhiteBalanceModeSupported(.locked) else { return }
            let gains: AVCaptureDevice.WhiteBalanceGains
            if device.isLockingWhiteBalanceWithCustomDeviceGainsSupported {
                let tnt = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: kelvin, tint: 0)
                var g = device.deviceWhiteBalanceGains(for: tnt)
                let maxGain = device.maxWhiteBalanceGain
                g.redGain   = g.redGain.fxClamped(to: 1.0...maxGain)
                g.greenGain = g.greenGain.fxClamped(to: 1.0...maxGain)
                g.blueGain  = g.blueGain.fxClamped(to: 1.0...maxGain)
                gains = g
            } else {
                gains = AVCaptureDevice.currentWhiteBalanceGains
            }
            try? device.lockForConfiguration()
            device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
            device.unlockForConfiguration()
        }
    }

    func setFocus(lensPosition: Float) {
        sessionQueue.async { [self] in
            guard let device = currentDevice,
                  device.isFocusModeSupported(.locked) else { return }
            let position: Float = device.isLockingFocusWithCustomLensPositionSupported
                ? lensPosition.fxClamped(to: 0...1)
                : AVCaptureDevice.currentLensPosition
            try? device.lockForConfiguration()
            device.setFocusModeLocked(lensPosition: position, completionHandler: nil)
            device.unlockForConfiguration()
        }
    }

    func setFocusPoint(_ point: CGPoint) {
        sessionQueue.async { [self] in
            guard let device = currentDevice else { return }
            try? device.lockForConfiguration()
            if device.isFocusPointOfInterestSupported && device.isFocusModeSupported(.autoFocus) {
                device.focusPointOfInterest = point
                device.focusMode = .autoFocus
            }
            if device.isExposurePointOfInterestSupported && device.isExposureModeSupported(.autoExpose) {
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
            Task { @MainActor in self.captureSettings.exposureCompensation = clamped }
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
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            } else if device.isExposureModeSupported(.autoExpose) {
                device.exposureMode = .autoExpose
            }
            device.unlockForConfiguration()
        }
    }

    func setAutoFocus() {
        sessionQueue.async { [self] in
            guard let device = currentDevice else { return }
            try? device.lockForConfiguration()
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            } else if device.isFocusModeSupported(.autoFocus) {
                device.focusMode = .autoFocus
            }
            device.unlockForConfiguration()
        }
    }

    func setAutoWhiteBalance() {
        sessionQueue.async { [self] in
            guard let device = currentDevice else { return }
            try? device.lockForConfiguration()
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            } else if device.isWhiteBalanceModeSupported(.autoWhiteBalance) {
                device.whiteBalanceMode = .autoWhiteBalance
            }
            device.unlockForConfiguration()
        }
    }

    func flipCamera() {
        sessionQueue.async { [self] in
            let currentPosition = currentDevice?.position ?? .back
            let newPosition: AVCaptureDevice.Position = currentPosition == .back ? .front : .back
            guard let device = bestDevice(for: newPosition),
                  let newInput = try? AVCaptureDeviceInput(device: device)
            else { return }

            session.beginConfiguration()
            session.inputs.forEach { session.removeInput($0) }
            if session.canAddInput(newInput) { session.addInput(newInput) }
            currentDevice = device
            session.commitConfiguration()
            configureVideoRotation()
            setupObservations(for: device)
        }
    }

    // MARK: - Still Capture

    func capturePhoto(delegate: AVCapturePhotoCaptureDelegate) {
        sessionQueue.async { [self] in
            guard !isCapturing else { return }
            isCapturing = true

            // Only request a specific codec if the output actually supports it.
            // Specifying an unavailable codec crashes/fails the capture silently.
            let settings: AVCapturePhotoSettings
            let wantsJpeg = captureSettings.captureFormat == .jpeg || captureSettings.captureFormat == .rawPlusJpeg
            if wantsJpeg && photoOutput.availablePhotoCodecTypes.contains(.jpeg) {
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            } else {
                settings = AVCapturePhotoSettings()
            }

            if #available(iOS 16.0, *) {
                if let maxDim = photoOutput.availablePhotoPixelFormatTypes.first {
                    _ = maxDim // maxPhotoDimensions set on output in configureSession
                }
                settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
            } else {
                settings.isHighResolutionPhotoEnabled = true
            }

            settings.flashMode = flashMode
            settings.photoQualityPrioritization = .quality

            photoOutput.capturePhoto(with: settings, delegate: delegate)
        }
    }

    // MARK: - Video Rotation

    /// Tells AVFoundation to deliver portrait-upright frames to the video output.
    /// Must be called on sessionQueue, after session.commitConfiguration().
    private func configureVideoRotation() {
        guard let connection = videoOutput.connection(with: .video) else { return }
        let portraitAngle: CGFloat = 90
        if connection.isVideoRotationAngleSupported(portraitAngle) {
            connection.videoRotationAngle = portraitAngle
        }
    }

    // MARK: - Zoom Levels

    var availableZoomFactors: [CGFloat] {
        guard let device = currentDevice else { return [1.0] }
        let switchOvers = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat($0.doubleValue) }
        var factors: [CGFloat] = []
        let hasUltraWide = device.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
        if hasUltraWide { factors.append(device.minAvailableVideoZoomFactor) }
        factors.append(1.0)
        factors.append(contentsOf: switchOvers.filter { $0 > 1.0 })
        // Remove duplicates while preserving order
        var seen = Set<CGFloat>()
        return factors.filter { seen.insert($0).inserted }
    }

    // MARK: - Device Selection

    private func bestDevice(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let preferred: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera
        ]
        return preferred.compactMap { AVCaptureDevice.default($0, for: .video, position: position) }.first
    }

    // MARK: - KVO Observations

    private func setupObservations(for device: AVCaptureDevice) {
        deviceObservations.forEach { $0.invalidate() }
        deviceObservations = [
            device.observe(\.iso, options: .new) { [weak self] d, _ in
                Task { @MainActor in
                    self?.currentISO = d.iso
                    // In auto mode, mirror live value into the binding so sliders show reality
                    if self?.captureSettings.isAutoISO == true {
                        self?.captureSettings.isoValue = d.iso
                    }
                }
            },
            device.observe(\.exposureDuration, options: .new) { [weak self] d, _ in
                Task { @MainActor in
                    self?.currentShutterSpeed = d.exposureDuration
                    if self?.captureSettings.isAutoShutter == true {
                        self?.captureSettings.shutterSpeed = d.exposureDuration
                    }
                }
            },
            device.observe(\.lensPosition, options: .new) { [weak self] d, _ in
                Task { @MainActor in
                    self?.currentLensPosition = d.lensPosition
                    if self?.captureSettings.isAutoFocus == true {
                        self?.captureSettings.focusDistance = d.lensPosition
                    }
                }
            },
            device.observe(\.deviceWhiteBalanceGains, options: .new) { [weak self] d, _ in
                guard d.isAdjustingWhiteBalance == false else { return }
                let tnt = d.temperatureAndTintValues(for: d.deviceWhiteBalanceGains)
                Task { @MainActor in
                    self?.currentWhiteBalance = tnt.temperature
                    if self?.captureSettings.isAutoWhiteBalance == true {
                        self?.captureSettings.whiteBalance = tnt.temperature
                    }
                }
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
