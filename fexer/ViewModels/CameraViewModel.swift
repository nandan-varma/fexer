import SwiftUI
import AVFoundation
import Observation

struct HistogramData {
    var red:   [Float] = []
    var green: [Float] = []
    var blue:  [Float] = []
    var luma:  [Float] = []
}

@Observable
final class CameraViewModel {
    let cameraManager: CameraManager
    let stylesManager: StylesManager

    // UI state
    var isPanelExpanded = false
    var activeModeIndex = 0
    var isFocusLocked = false
    var focusIndicatorPosition: CGPoint = .zero
    var showFocusIndicator = false
    var zoomLevel: CGFloat = 1.0

    // Histogram data — single property update fires one SwiftUI notification per frame
    var histogram = HistogramData()

    // Exposure compensation (driven by right-side swipe)
    private var accumulatedExposureBias: Float = 0

    private var focusTask: Task<Void, Never>?

    var activeMode: ShootingMode { ShootingMode.allCases[activeModeIndex] }

    init(cameraManager: CameraManager, stylesManager: StylesManager) {
        self.cameraManager = cameraManager
        self.stylesManager = stylesManager

        cameraManager.processor.onHistogramUpdate = { [weak self] r, g, b, l in
            Task { @MainActor in
                self?.histogram = HistogramData(red: r, green: g, blue: b, luma: l)
            }
        }
    }

    // MARK: - Gesture Handlers

    func handleTapToFocus(at normalizedPoint: CGPoint) {
        cameraManager.setFocusPoint(normalizedPoint)
        focusIndicatorPosition = normalizedPoint
        showFocusIndicator = true
        isFocusLocked = false

        focusTask?.cancel()
        focusTask = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.isFocusLocked = true
                HapticManager.focusLocked()
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.showFocusIndicator = false
                self.isFocusLocked = false
            }
        }
    }

    func handlePinchZoom(scale: CGFloat, velocity: CGFloat) {
        let newZoom = scale.fxClamped(to: 0.5...15.0)
        zoomLevel = newZoom
        cameraManager.setZoom(newZoom)
    }

    func handleSwipeUp() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            isPanelExpanded = true
        }
        HapticManager.light()
    }

    func handleSwipeDown() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            isPanelExpanded = false
        }
    }

    func handleDoubleTapReset() {
        cameraManager.setAutoExposure()
        cameraManager.setAutoFocus()
        cameraManager.setAutoWhiteBalance()
        cameraManager.setExposureCompensation(0)
        cameraManager.captureSettings.isAutoISO = true
        cameraManager.captureSettings.isAutoShutter = true
        cameraManager.captureSettings.isAutoFocus = true
        cameraManager.captureSettings.isAutoWhiteBalance = true
        accumulatedExposureBias = 0
        HapticManager.medium()
    }

    func handleBrightnessSwipe(delta: CGFloat) {
        accumulatedExposureBias = (accumulatedExposureBias + Float(delta)).fxClamped(to: -3...3)
        cameraManager.setExposureCompensation(accumulatedExposureBias)
    }

    // MARK: - Overlay Sync

    /// focusPeaking and zebra come from CameraView's @AppStorage so the
    /// caller passes them in rather than this class storing them.
    func syncOverlaysToProcessor(focusPeaking: Bool = false, zebra: Bool = false) {
        cameraManager.processor.isFocusPeakingEnabled = focusPeaking
        cameraManager.processor.isZebraEnabled = zebra
        let filter = stylesManager.activeLUTFilter()
        cameraManager.processor.lutFilter = filter
    }

    // MARK: - Capture

    func capturePhoto(delegate: AVCapturePhotoCaptureDelegate) {
        HapticManager.shutter()
        cameraManager.capturePhoto(delegate: delegate)
    }

    // MARK: - Mode Selection

    func selectMode(index: Int) {
        guard index >= 0 && index < ShootingMode.allCases.count else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            activeModeIndex = index
        }
        HapticManager.selectionChanged()
    }
}
