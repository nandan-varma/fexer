import AVFoundation
import OSLog

extension CameraManager {

    // MARK: - Video mode session preset

    /// Reconfigures the capture session for video recording at the specified resolution and frame rate.
    /// Must NOT be called while recording is active.
    func configureForVideoMode(resolution: VideoResolution, fps: Int = 30) {
        sessionQueue.async { [self] in
            guard let device = currentDevice else { return }
            guard !isRecording, !isWaitingToRecord else { return }
            Task { @MainActor in self.onVolumeGateWillBlock?() }

            let targetWidth: Int32 = resolution == .uhd4K ? 3840 : 1920
            let targetFPS = Double(fps)

            // Find a format matching both resolution and desired frame rate
            let matchingFormat = device.formats.first { format in
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                return dims.width == targetWidth &&
                    format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= targetFPS }
            }

            session.beginConfiguration()

            let preset = resolution.sessionPreset
            if session.canSetSessionPreset(preset) {
                session.sessionPreset = preset
            } else {
                session.sessionPreset = .hd1920x1080
                Logger.camera.warning("4K preset unsupported on this device, falling back to 1080p")
            }

            if let fmt = matchingFormat {
                device.withLock {
                    device.activeFormat = fmt
                    let dur = CMTimeMake(value: 1, timescale: Int32(targetFPS))
                    device.activeVideoMinFrameDuration = dur
                    device.activeVideoMaxFrameDuration = dur
                }
            } else {
                Logger.camera.warning("No format for \(resolution.rawValue) at \(fps)fps; using preset default")
            }

            session.commitConfiguration()
            configureVideoRotation()
            Task { @MainActor in self.captureSettings.videoSettings.resolution = resolution }
            sessionQueue.asyncAfter(deadline: .now() + 0.15) { [self] in
                Task { @MainActor in self.onVolumeGateDidUnblock?() }
            }
        }
    }

    /// Restores the capture session preset to `.photo` (for still capture modes).
    func configureForPhotoMode() {
        sessionQueue.async { [self] in
            guard !isRecording, !isWaitingToRecord else { return }
            Task { @MainActor in self.onVolumeGateWillBlock?() }
            session.beginConfiguration()
            session.sessionPreset = .photo
            session.commitConfiguration()
            sessionQueue.asyncAfter(deadline: .now() + 0.15) { [self] in
                Task { @MainActor in self.onVolumeGateDidUnblock?() }
            }
        }
    }

    // MARK: - Live Photo

    func toggleLivePhoto() {
        isLivePhotoEnabled.toggle()
    }

    // MARK: - Zoom Levels

    /// Raw AVFoundation zoom factors for each optical stop on the current device.
    var availableZoomFactors: [CGFloat] {
        guard let device = currentDevice else { return [] }
        let switchOvers = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat($0.doubleValue) }
        return [device.minAvailableVideoZoomFactor] + switchOvers
    }

    // MARK: - Macro Mode

    var isMacroSupported: Bool {
        guard let device = currentDevice else { return false }
        return device.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
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
            Task { @MainActor in self.onVolumeGateWillBlock?() }
            session.beginConfiguration()
            device.withLock { device.activeColorSpace = target }
            session.commitConfiguration()
            Task { @MainActor in self.captureSettings.videoColorSpace = colorSpace }
            sessionQueue.asyncAfter(deadline: .now() + 0.15) { [self] in
                Task { @MainActor in self.onVolumeGateDidUnblock?() }
            }
        }
    }

    func setHDREnabled(_ enabled: Bool) {
        sessionQueue.async { [self] in
            guard videoOutput.connection(with: .video) != nil else { return }
            Task { @MainActor in self.onVolumeGateWillBlock?() }
            defer {
                sessionQueue.asyncAfter(deadline: .now() + 0.15) {
                    Task { @MainActor in self.onVolumeGateDidUnblock?() }
                }
            }
            if enabled, let device = currentDevice {
                let currentDims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
                let isHDRCapable: (AVCaptureDevice.Format) -> Bool = {
                    $0.isVideoHDRSupported || $0.supportedColorSpaces.contains(.HLG_BT2020)
                }
                // Prefer same dimensions, fall back to any >= 1920 wide HDR format.
                let hdrFormat = device.formats.first(where: {
                    let d = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                    return d.width == currentDims.width && d.height == currentDims.height && isHDRCapable($0)
                }) ?? device.formats.first(where: {
                    CMVideoFormatDescriptionGetDimensions($0.formatDescription).width >= 1920 && isHDRCapable($0)
                })
                if let fmt = hdrFormat {
                    preHDRFormat = device.activeFormat
                    session.beginConfiguration()
                    device.withLock {
                        device.activeFormat = fmt
                        if fmt.supportedColorSpaces.contains(.HLG_BT2020) {
                            device.activeColorSpace = .HLG_BT2020
                        }
                    }
                    session.commitConfiguration()
                    Task { @MainActor in self.captureSettings.isHDREnabled = true }
                } else {
                    Logger.camera.warning("No HDR-capable format found; HDR not available on this device")
                    Task { @MainActor in self.captureSettings.isHDREnabled = false }
                }
            } else if !enabled, let device = currentDevice {
                if let saved = preHDRFormat {
                    preHDRFormat = nil
                    session.beginConfiguration()
                    device.withLock {
                        device.activeFormat = saved
                        device.activeColorSpace = .sRGB
                    }
                    session.commitConfiguration()
                }
                Task { @MainActor in self.captureSettings.isHDREnabled = false }
            }
        }
    }

    // MARK: - Slow Motion

    /// Activates a high-frame-rate format for slow-motion capture.
    func configureForSlowMotion(fps: Int) {
        sessionQueue.async { [self] in
            guard let device = currentDevice else { return }
            let targetFPS = Double(fps)
            let candidate = device.formats.first { format in
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                return dims.width == 1920 &&
                    format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= targetFPS }
            }
            guard let fmt = candidate else {
                Logger.camera.warning("No format found for \(fps)fps slow motion")
                return
            }
            Task { @MainActor in self.onVolumeGateWillBlock?() }
            session.beginConfiguration()
            device.withLock {
                device.activeFormat = fmt
                let dur = CMTimeMake(value: 1, timescale: Int32(targetFPS))
                device.activeVideoMinFrameDuration = dur
                device.activeVideoMaxFrameDuration = dur
            }
            session.commitConfiguration()
            configureVideoRotation()
            sessionQueue.asyncAfter(deadline: .now() + 0.15) { [self] in
                Task { @MainActor in self.onVolumeGateDidUnblock?() }
            }
        }
    }

    // MARK: - Trap Focus

    /// Registers a callback to fire the moment the camera locks focus.
    func setTrapFocusCallback(_ callback: @escaping () -> Void) {
        Task { @MainActor in trapFocusCaptureCallback = callback }
    }

    func clearTrapFocusCallback() {
        Task { @MainActor in trapFocusCaptureCallback = nil }
    }

    // MARK: - Frame Rate

    func configureVideoFrameRate(_ fps: Int) {
        sessionQueue.async { [self] in
            guard let device = currentDevice else { return }
            let targetFPS = Double(fps)
            let currentFormat = device.activeFormat
            let currentRanges = currentFormat.videoSupportedFrameRateRanges

            if currentRanges.contains(where: { $0.maxFrameRate >= targetFPS }) {
                let cmDuration = CMTimeMake(value: 1, timescale: Int32(targetFPS))
                device.withLock {
                    device.activeVideoMinFrameDuration = cmDuration
                    device.activeVideoMaxFrameDuration = cmDuration
                }
            } else {
                let dims = CMVideoFormatDescriptionGetDimensions(currentFormat.formatDescription)
                guard let fmt = device.formats.first(where: { format in
                    let fd = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                    return fd.width == dims.width && fd.height == dims.height &&
                        format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= targetFPS }
                }) else {
                    Logger.camera.warning("No format at \(dims.width)×\(dims.height) supports \(fps)fps")
                    return
                }
                let dur = CMTimeMake(value: 1, timescale: Int32(targetFPS))
                session.beginConfiguration()
                device.withLock {
                    device.activeFormat = fmt
                    device.activeVideoMinFrameDuration = dur
                    device.activeVideoMaxFrameDuration = dur
                }
                session.commitConfiguration()
                configureVideoRotation()
            }
        }
    }

    func supportedFrameRates(for resolution: VideoResolution) -> [Int] {
        let candidates = [24, 25, 30, 60, 120, 240]
        guard let device = currentDevice else { return [24, 25, 30, 60] }
        let targetWidth: Int32 = resolution.sessionPreset == .hd4K3840x2160 ? 3840 : 1920
        let maxFPS = device.formats
            .filter { CMVideoFormatDescriptionGetDimensions($0.formatDescription).width == targetWidth }
            .flatMap { $0.videoSupportedFrameRateRanges }
            .map { Int($0.maxFrameRate) }
            .max() ?? 60
        return candidates.filter { $0 <= maxFPS }
    }
}
