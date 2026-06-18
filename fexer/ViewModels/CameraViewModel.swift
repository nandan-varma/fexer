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

    // AE Lock
    var isAELocked: Bool = false

    // Self-timer
    var timerCountdown: Int = 0
    var isTimerActive: Bool = false

    // Histogram data — single property update fires one SwiftUI notification per frame
    var histogram = HistogramData()

    // Exposure compensation (driven by right-side swipe)
    private var accumulatedExposureBias: Float = 0

    private var focusTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?

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
        cameraManager.captureSettings.whiteBalanceTint = 0
        accumulatedExposureBias = 0
        if isAELocked { toggleAELock() }
        HapticManager.medium()
    }

    // MARK: - AE Lock

    func toggleAELock() {
        if isAELocked {
            cameraManager.unlockAutoExposure()
            isAELocked = false
        } else {
            cameraManager.lockAutoExposure()
            isAELocked = true
        }
        HapticManager.medium()
    }

    // MARK: - Self-timer

    func startTimerCapture(delay: Double, action: @escaping () -> Void) {
        guard !isTimerActive else { return }
        isTimerActive = true
        timerCountdown = Int(delay)

        timerTask = Task {
            var remaining = Int(delay)
            while remaining > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                remaining -= 1
                await MainActor.run { self.timerCountdown = remaining }
            }
            await MainActor.run {
                self.isTimerActive = false
                self.timerCountdown = 0
            }
            action()
        }
    }

    func cancelTimer() {
        timerTask?.cancel()
        timerTask = nil
        isTimerActive = false
        timerCountdown = 0
    }

    func handleBrightnessSwipe(delta: CGFloat) {
        accumulatedExposureBias = (accumulatedExposureBias + Float(delta)).fxClamped(to: -3...3)
        cameraManager.setExposureCompensation(accumulatedExposureBias)
    }

    // MARK: - Overlay Sync

    /// Caller passes AppStorage flags in so this class doesn't need to own them.
    func syncOverlaysToProcessor(focusPeaking: Bool = false, zebra: Bool = false, falseColor: Bool = false) {
        cameraManager.processor.isFocusPeakingEnabled = focusPeaking
        cameraManager.processor.isZebraEnabled = zebra
        cameraManager.processor.isFalseColorEnabled = falseColor
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
