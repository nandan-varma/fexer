import AVFoundation
import Foundation
import OSLog

extension CameraManager {

    // MARK: - ProRAW / Night / Portrait

    func setProRAWEnabled(_ enabled: Bool) {
        sessionQueue.async { [self] in
            guard photoOutput.isAppleProRAWSupported else { return }
            Task { @MainActor in self.onVolumeGateWillBlock?() }
            session.beginConfiguration()
            photoOutput.isAppleProRAWEnabled = enabled
            session.commitConfiguration()
            Logger.camera.info("ProRAW \(enabled ? "enabled" : "disabled")")
            sessionQueue.asyncAfter(deadline: .now() + 0.15) { [self] in
                Task { @MainActor in self.onVolumeGateDidUnblock?() }
            }
        }
    }

    func cancelLongExposureCapture() {
        sessionQueue.async { [self] in
            processor.cancelLongExposureCapture()
        }
    }

    func setNightModeEnabled(_ enabled: Bool) {
        sessionQueue.async { [self] in
            guard let device = currentDevice else { return }
            device.withLock {
                if device.isLowLightBoostSupported {
                    device.automaticallyEnablesLowLightBoostWhenAvailable = enabled
                }
            }
            Task { @MainActor in self.onVolumeGateWillBlock?() }
            session.beginConfiguration()
            photoOutput.maxPhotoQualityPrioritization = enabled ? .quality : .balanced
            session.commitConfiguration()
            sessionQueue.asyncAfter(deadline: .now() + 0.15) { [self] in
                Task { @MainActor in self.onVolumeGateDidUnblock?() }
            }
        }
    }

    func setDepthDataEnabled(_ enabled: Bool) {
        sessionQueue.async { [self] in
            guard photoOutput.isDepthDataDeliverySupported else { return }
            Task { @MainActor in self.onVolumeGateWillBlock?() }
            session.beginConfiguration()
            photoOutput.isDepthDataDeliveryEnabled = enabled
            if enabled && photoOutput.isPortraitEffectsMatteDeliverySupported {
                photoOutput.isPortraitEffectsMatteDeliveryEnabled = true
            } else {
                photoOutput.isPortraitEffectsMatteDeliveryEnabled = false
            }
            session.commitConfiguration()
            Logger.camera.info("Depth data \(enabled ? "enabled" : "disabled")")
            sessionQueue.asyncAfter(deadline: .now() + 0.15) { [self] in
                Task { @MainActor in self.onVolumeGateDidUnblock?() }
            }
        }
    }

    // MARK: - Still Capture

    // MARK: - Photo connection orientation

    /// Maps the UI counter-rotation angle (from DeviceOrientationTracker) to the
    /// AVCaptureConnection angle that makes pixels upright for the physical device orientation.
    /// Must be called on MainActor; result is passed into sessionQueue before each capture.
    private func currentPhotoConnectionAngle() -> CGFloat {
        let uiAngle = Int(DeviceOrientationTracker.shared.rotationAngle)
        // portrait(0)→90°  landscapeLeft(90)→0°  landscapeRight(-90)→180°  upsideDown(180)→270°
        return CGFloat((90 - uiAngle + 360) % 360)
    }

    /// Apply rotation to the photo output connection. Must be called on sessionQueue.
    private func applyPhotoConnectionRotation(_ angle: CGFloat) {
        guard let conn = photoOutput.connection(with: .video),
              conn.isVideoRotationAngleSupported(angle) else { return }
        conn.videoRotationAngle = angle
    }

    // MARK: - Still Capture

    /// - Parameter bypassBusyGuard: Set `true` for burst mode, which needs overlapping captures.
    func capturePhoto(delegate: AVCapturePhotoCaptureDelegate, bypassBusyGuard: Bool = false) {
        // Snapshot @MainActor properties before crossing to sessionQueue.
        let captureFormat = captureSettings.captureFormat
        let flash = flashMode
        let photoAngle = currentPhotoConnectionAngle()
        sessionQueue.async { [self] in
            // _captureBusy is checked and set on sessionQueue atomically — no TOCTOU.
            guard bypassBusyGuard || !_captureBusy else { return }
            if !bypassBusyGuard {
                _captureBusy = true
                Task { @MainActor in self.isCapturing = true }
            }
            applyPhotoConnectionRotation(photoAngle)
            let settings = makePhotoSettings(format: captureFormat)
            settings.flashMode = flash
            // photoQualityPrioritization is unsupported for RAW captures
            if settings.rawPhotoPixelFormatType == 0 {
                settings.photoQualityPrioritization = photoOutput.maxPhotoQualityPrioritization.rawValue >= AVCapturePhotoOutput.QualityPrioritization.quality.rawValue
                    ? .quality
                    : photoOutput.maxPhotoQualityPrioritization
            }
            photoOutput.capturePhoto(with: settings, delegate: delegate)
        }
    }

    func capturePhotoBracketed(evStep: Float, delegate: AVCapturePhotoCaptureDelegate) {
        let flash = flashMode
        let photoAngle = currentPhotoConnectionAngle()
        sessionQueue.async { [self] in
            guard !_captureBusy else { return }
            _captureBusy = true
            Task { @MainActor in self.isCapturing = true }
            applyPhotoConnectionRotation(photoAngle)

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
            settings.flashMode = flash
            photoOutput.capturePhoto(with: settings, delegate: delegate)
        }
    }

    /// Captures 3 shots sequentially at current K ± kStep, then current K.
    func capturePhotoBracketedWB(kStep: Float, captureFormat: CaptureFormat, flash: AVCaptureDevice.FlashMode, delegate: AVCapturePhotoCaptureDelegate) {
        let photoAngle = currentPhotoConnectionAngle()
        sessionQueue.async { [self] in
            guard !_captureBusy else { return }
            _captureBusy = true
            applyPhotoConnectionRotation(photoAngle)
            let steps: [Float] = [-kStep, 0, kStep]
            pendingBracketCompletions = steps.count
            Task { @MainActor in self.isCapturing = true }
            let baseK = captureSettings.whiteBalance
            let tint  = captureSettings.whiteBalanceTint
            for (i, step) in steps.enumerated() {
                sessionQueue.asyncAfter(deadline: .now() + Double(i) * 0.35) { [self] in
                    guard let device = currentDevice else { return }
                    let k = (baseK + step).fxClamped(to: 2000...10000)
                    applyWhiteBalance(kelvin: k, tint: tint, to: device)
                    let settings = self.makePhotoSettings(format: captureFormat)
                    settings.flashMode = flash
                    self.photoOutput.capturePhoto(with: settings, delegate: delegate)
                }
            }
            // Restore original WB after all shots complete.
            sessionQueue.asyncAfter(deadline: .now() + Double(steps.count) * 0.35 + 0.15) { [self] in
                guard let device = currentDevice else { return }
                applyWhiteBalance(kelvin: baseK, tint: tint, to: device)
            }
        }
    }

    func clearCaptureGuard() {
        sessionQueue.async { [self] in
            if pendingBracketCompletions > 0 {
                pendingBracketCompletions -= 1
                if pendingBracketCompletions > 0 { return }
            }
            _captureBusy = false
            Task { @MainActor in self.isCapturing = false }
        }
    }

    func makePhotoSettings(format: CaptureFormat) -> AVCapturePhotoSettings {
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
}
