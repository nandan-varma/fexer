import AVFoundation
import CoreMedia
import OSLog

extension CameraManager {

    // MARK: - Manual Controls (call on any thread; executes on sessionQueue)

    func setISO(_ iso: Float) {
        sessionQueue.async { [self] in
            guard let device = currentDevice else {
                Logger.camera.error("Cannot set ISO: no camera device available")
                return
            }
            guard device.isExposureModeSupported(.custom) else { return }
            let clamped = iso.fxClamped(to: device.activeFormat.minISO...device.activeFormat.maxISO)
            device.withLock {
                device.setExposureModeCustom(duration: device.exposureDuration, iso: clamped)
            }
        }
    }

    func setShutterSpeed(_ duration: CMTime) {
        sessionQueue.async { [self] in
            guard let device = currentDevice else { return }
            guard device.isExposureModeSupported(.custom) else { return }
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
            guard device.isExposureModeSupported(.custom) else { return }
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

    func setWhiteBalance(kelvin: Float, tint: Float = 0) {
        sessionQueue.async { [self] in
            guard let device = currentDevice else {
                Logger.camera.error("Cannot set white balance: no camera device available")
                return
            }
            applyWhiteBalance(kelvin: kelvin, tint: tint, to: device)
        }
    }

    /// Clamps and applies WB gains directly on the current device. Must be called on sessionQueue.
    func applyWhiteBalance(kelvin: Float, tint: Float, to device: AVCaptureDevice) {
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
        device.withLock { device.setWhiteBalanceModeLocked(with: gains) }
    }

    func setFocus(lensPosition: Float) {
        sessionQueue.async { [self] in
            guard let device = currentDevice else {
                Logger.camera.error("Cannot set focus: no camera device available")
                return
            }
            guard device.isLockingFocusWithCustomLensPositionSupported else { return }
            device.withLock {
                device.setFocusModeLocked(lensPosition: lensPosition.fxClamped(to: 0...1))
            }
        }
    }

    func setFocusPoint(_ point: CGPoint, adjustExposure: Bool = true) {
        // Snapshot @MainActor properties before crossing to sessionQueue.
        let afMode = captureSettings.focusMode
        let meteringMode = captureSettings.meteringMode
        sessionQueue.async { [self] in
            guard let device = currentDevice else {
                Logger.camera.error("Cannot set focus point: no camera device available")
                return
            }
            device.withLock {
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = point
                    device.focusMode = device.isFocusModeSupported(afMode) ? afMode : .autoFocus
                }
                if adjustExposure && device.isExposurePointOfInterestSupported {
                    // Spot metering tracks the tap point; all others stay at center
                    let expPoint: CGPoint = meteringMode == .spot ? point : CGPoint(x: 0.5, y: 0.5)
                    device.exposurePointOfInterest = expPoint
                    device.exposureMode = .autoExpose
                }
            }
        }
    }

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

    func setAutoFocus() {
        let mode = captureSettings.focusMode
        sessionQueue.async { [self] in
            guard let device = currentDevice else {
                Logger.camera.error("Cannot set auto focus: no camera device available")
                return
            }
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
            // .locked is a transient hardware state for manual focus, not a persisted AF preference.
            // captureSettings.focusMode holds the user's AFC/AFS choice used by setAutoFocus()
            // and setFocusPoint() — corrupting it with .locked breaks both after manual → auto.
            if mode != .locked {
                Task { @MainActor in self.captureSettings.focusMode = mode }
            }
        }
    }

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

    func lockAutoExposure() {
        sessionQueue.async { [self] in
            guard let device = currentDevice else {
                Logger.camera.error("Cannot lock auto exposure: no camera device available")
                return
            }
            guard device.isExposureModeSupported(.custom) else { return }
            device.withLock {
                device.setExposureModeCustom(duration: device.exposureDuration, iso: device.iso)
            }
            Task { @MainActor in self.captureSettings.isAELocked = true }
        }
    }

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
                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    }
                case .center:
                    if device.isExposurePointOfInterestSupported {
                        device.exposurePointOfInterest = CGPoint(x: 0.5, y: 0.5)
                    }
                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    }
                case .spot:
                    if device.isExposurePointOfInterestSupported {
                        device.exposurePointOfInterest = device.focusPointOfInterest
                    }
                    if device.isExposureModeSupported(.autoExpose) {
                        device.exposureMode = .autoExpose
                    }
                case .highlightWeighted:
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
}
