import SwiftUI
import AVFoundation
import Observation
import OSLog

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

    // AE Lock — computed from hardware state so it can never drift
    var isAELocked: Bool { cameraManager.captureSettings.isAELocked }

    // Self-timer
    var timerCountdown: Int = 0
    var isTimerActive: Bool = false

    // Burst
    var isBurstActive = false
    var burstCount = 0
    private var burstTask: Task<Void, Never>?

    // Timelapse
    var isTimelapseActive = false
    var timelapseCount = 0
    /// Interval in seconds between timelapse shots. Set by CameraView from its @AppStorage("timelapseInterval").
    var timelapseInterval: Double = 5.0
    private var timelapseTask: Task<Void, Never>?

    // Histogram data — single property update fires one SwiftUI notification per frame
    var histogram = HistogramData()

    // Exposure compensation (driven by right-side swipe)
    private var accumulatedExposureBias: Float = 0

    // Previous crop ratio to restore when leaving anamorphic mode
    private var preModeRaw: String = CropRatio.full.rawValue

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
        HapticManager.medium()
    }

    // MARK: - AE Lock

    func toggleAELock() {
        if isAELocked {
            cameraManager.unlockAutoExposure()
        } else {
            cameraManager.lockAutoExposure()
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
                guard !Task.isCancelled else { return }
                self.isTimerActive = false
                self.timerCountdown = 0
                action()
            }
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

    // MARK: - Burst

    /// Fires up to 10 photos 100 ms apart. Call `stopBurst()` to cancel early.
    func startBurst(delegate: AVCapturePhotoCaptureDelegate) {
        guard !isBurstActive else { return }
        isBurstActive = true
        burstCount = 0
        Logger.camera.info("Burst started")

        burstTask = Task {
            let maxShots = 10
            for i in 1...maxShots {
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    self.burstCount = i
                    HapticManager.shutter()
                }
                cameraManager.capturePhoto(delegate: delegate)
                try? await Task.sleep(nanoseconds: 100_000_000) // 100 ms
            }
            await MainActor.run {
                self.isBurstActive = false
                Logger.camera.info("Burst finished: \(self.burstCount) frames")
            }
        }
    }

    func stopBurst() {
        burstTask?.cancel()
        burstTask = nil
        isBurstActive = false
        Logger.camera.info("Burst stopped at \(self.burstCount) frames")
    }

    // MARK: - Timelapse

    /// Fires `capturePhoto` every `timelapseInterval` seconds until `stopTimelapse()` is called.
    func startTimelapse(delegate: AVCapturePhotoCaptureDelegate) {
        guard !isTimelapseActive else { return }
        isTimelapseActive = true
        timelapseCount = 0
        Logger.camera.info("Timelapse started, interval=\(self.timelapseInterval)s")

        timelapseTask = Task {
            while !Task.isCancelled {
                await MainActor.run {
                    self.timelapseCount += 1
                    HapticManager.shutter()
                }
                cameraManager.capturePhoto(delegate: delegate)
                let ns = UInt64(timelapseInterval * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
            }
        }
    }

    func stopTimelapse() {
        timelapseTask?.cancel()
        timelapseTask = nil
        isTimelapseActive = false
        Logger.camera.info("Timelapse stopped: \(self.timelapseCount) frames")
    }

    // MARK: - Mode Selection

    /// Call with the raw value string from `@AppStorage("cropRatio")` so the
    /// view model can update crop ratio without importing AppStorage itself.
    func selectMode(index: Int, cropRatioRaw: Binding<String>, selfTimerDelay: Binding<Int>) {
        guard index >= 0 && index < ShootingMode.allCases.count else { return }

        let previousMode = activeMode
        let newMode = ShootingMode.allCases[index]

        // Tear down outgoing mode
        switch previousMode {
        case .burst:
            stopBurst()
        case .timelapse:
            stopTimelapse()
        case .anamorphic:
            // Restore the crop that was in use before anamorphic was selected
            cropRatioRaw.wrappedValue = preModeRaw
        case .longExposure, .night:
            // Return to full auto when leaving these modes
            cameraManager.setAutoExposure()
            cameraManager.captureSettings.isAutoISO = true
            cameraManager.captureSettings.isAutoShutter = true
        default:
            break
        }

        withAnimation(.easeInOut(duration: 0.2)) {
            activeModeIndex = index
        }
        HapticManager.selectionChanged()

        // Apply incoming mode
        switch newMode {
        case .photo:
            break // default behavior

        case .portrait:
            // No deep-effect implementation (requires TrueDepth/dual cam); badge shown in CameraView.
            break

        case .selfTimer:
            // Ensure the timer is active (set to 3s if currently disabled)
            if selfTimerDelay.wrappedValue == 0 {
                selfTimerDelay.wrappedValue = 3
            }

        case .longExposure:
            // ISO 50, shutter 1s — lock manual exposure
            cameraManager.setAutoExposure()
            cameraManager.captureSettings.isAutoISO = false
            cameraManager.captureSettings.isAutoShutter = false
            cameraManager.setISO(50)
            cameraManager.setShutterSpeed(CMTime(value: 1, timescale: 1))
            Logger.camera.info("Long exposure mode: ISO 50, 1s")

        case .night:
            // ISO 3200, 1/15s — lock manual exposure
            cameraManager.setAutoExposure()
            cameraManager.captureSettings.isAutoISO = false
            cameraManager.captureSettings.isAutoShutter = false
            cameraManager.setISO(3200)
            cameraManager.setShutterSpeed(CMTime(value: 1, timescale: 15))
            Logger.camera.info("Night mode: ISO 3200, 1/15s")

        case .burst:
            break // burst starts on shutter press

        case .timelapse:
            break // timelapse starts on shutter press

        case .anamorphic:
            // Save current crop so we can restore it when leaving
            preModeRaw = cropRatioRaw.wrappedValue
            cropRatioRaw.wrappedValue = CropRatio.r239_100.rawValue
            Logger.camera.info("Anamorphic mode: applied 2.39:1 crop")
        }
    }
}
