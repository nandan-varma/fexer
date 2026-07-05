import AVFoundation
import SwiftUI
import UIKit

extension CameraView {

    func onCameraViewAppear() {
        HapticManager.warmUp()
        DeviceOrientationTracker.shared.start()
        cameraManager.startSession()
        syncProcessor()
        cameraViewModel.attachMonitoringCallbacks()
        cameraManager.processor.onPixelBuffer = stylesViewModel.onFrameAvailable
        // Wire trap focus — when camera locks, fire shutter
        cameraManager.setTrapFocusCallback { [self] in
            guard cameraManager.captureSettings.isTrapFocusEnabled else { return }
            performCapture()
        }
        // Wire session-reconfiguration guards to gate volume-button captures.
        cameraManager.onVolumeGateWillBlock = { [self] in
            self.volumeGate.block()
        }
        cameraManager.onVolumeGateDidUnblock = { [self] in
            self.volumeGate.unblock()
        }
        UIApplication.shared.isIdleTimerDisabled = true
        Task { await appState.permissionsManager.requestPhotoLibraryAccess() }
        Task { await appState.permissionsManager.requestMicrophoneAccess() }
        appState.permissionsManager.requestLocationAccess()
        cameraViewModel.timelapseInterval = timelapseInterval
        cameraManager.captureSettings.captureFormat = CaptureFormat(rawValue: defaultCaptureFormat) ?? .heif
        cameraManager.setProRAWEnabled(isProRAWEnabled)
        cameraManager.captureSettings.isOpticalZoomLocked = isOpticalZoomLocked
        cameraManager.captureSettings.isTrapFocusEnabled = isTrapFocusEnabled
        setupVolumeButtonObserver()
        applyPendingShootingMode()
    }

    func onCameraViewDisappear() {
        volumeObservation?.invalidate()
        volumeObservation = nil
        if let token = volumeInterruptionToken {
            NotificationCenter.default.removeObserver(token)
            volumeInterruptionToken = nil
        }
        if let token = volumeRouteChangeToken {
            NotificationCenter.default.removeObserver(token)
            volumeRouteChangeToken = nil
        }
        cameraManager.onVolumeGateWillBlock = nil
        cameraManager.onVolumeGateDidUnblock = nil
        cameraManager.stopSession()
        cameraManager.cancelLongExposureCapture()
        cameraManager.processor.onPixelBuffer = nil
        cameraViewModel.detachMonitoringCallbacks()
        cameraViewModel.stopBurst()
        cameraViewModel.stopTimelapse()
        cameraViewModel.cancelTimer()
        aelToastTask?.cancel()
        UIApplication.shared.isIdleTimerDisabled = false
        DeviceOrientationTracker.shared.stop()
    }

    func applyPendingShootingMode() {
        guard let mode = appState.pendingShootingMode,
              let index = ShootingMode.allCases.firstIndex(of: mode) else { return }
        appState.pendingShootingMode = nil
        cameraViewModel.selectMode(index: index, cropRatioRaw: $cropRatioRaw, selfTimerDelay: $selfTimerDelay)
    }

    func formatTimecode(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}
