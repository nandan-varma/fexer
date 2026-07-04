import AVFoundation
import OSLog

extension CameraManager {

    // MARK: - KVO Observations

    func setupObservations(for device: AVCaptureDevice) {
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

    func cleanupObservers() {
        deviceObservations.forEach { $0.invalidate() }
        deviceObservations.removeAll()
        subjectAreaObserver.map { NotificationCenter.default.removeObserver($0) }
        subjectAreaObserver = nil
    }
}
