import SwiftUI
import AVFoundation
import Observation
import OSLog

struct HistogramData {
    var red:   [Float] = []
    var green: [Float] = []
    var blue:  [Float] = []
    var luma:  [Float] = []

    nonisolated init(red: [Float] = [], green: [Float] = [], blue: [Float] = [], luma: [Float] = []) {
        self.red = red; self.green = green; self.blue = blue; self.luma = luma
    }
}


@Observable
final class CameraViewModel {
    let cameraManager: CameraManager
    let stylesManager: StylesManager

    // UI state
    enum RailParam: Equatable { case iso, shutter, wb, focus }
    var activeRailParam: RailParam? = nil
    var activeModeIndex = 0
    var shutterFlashTick: Int = 0
    var isZooming: Bool = false
    private var zoomHideTask: Task<Void, Never>?
    var isFocusLocked = false
    var focusIndicatorPosition: CGPoint = .zero
    var showFocusIndicator = false
    var zoomLevel: CGFloat = 1.0

    // AE Lock — computed from hardware state so it can never drift
    var isAELocked: Bool { cameraManager.captureSettings.isAELocked }

    // Self-timer
    var timerCountdown: Int = 0
    var isTimerActive: Bool = false
    var selfTimerRepeatCount: Int = 1  // 1 = single shot; 0 = infinite
    var selfTimerRepeatCurrent: Int = 0

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

    // Monitoring overlay data — updated from histogramQueue (~30 Hz)
    var histogram    = HistogramData()
    var waveform     = WaveformData()
    var vectorscope  = VectorscopeData()

    // Exposure compensation (driven by right-side swipe)
    var accumulatedExposureBias: Float = 0
    var isBrightnessAdjusting = false
    private var brightnessHideTask: Task<Void, Never>?

    // Previous crop ratio to restore when leaving anamorphic mode
    private var preModeRaw: String = CropRatio.full.rawValue

    // Saved exposure to restore when leaving long exposure / night mode
    private struct SavedExposure {
        var iso: Float
        var shutter: CMTime
        var autoISO: Bool
        var autoShutter: Bool
    }
    private var savedExposure: SavedExposure?

    private var focusTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?

    var activeMode: ShootingMode { ShootingMode.allCases[activeModeIndex] }

    init(cameraManager: CameraManager, stylesManager: StylesManager) {
        self.cameraManager = cameraManager
        self.stylesManager = stylesManager
        attachMonitoringCallbacks()
    }

    // MARK: - Processor monitoring callbacks

    /// Wires histogram/waveform/vectorscope callbacks. Called from init and on view appear.
    func attachMonitoringCallbacks() {
        cameraManager.processor.onHistogramUpdate = { [weak self] r, g, b, l in
            Task { @MainActor in
                self?.histogram = HistogramData(red: r, green: g, blue: b, luma: l)
            }
        }
        cameraManager.processor.onWaveformUpdate = { [weak self] data in
            Task { @MainActor in self?.waveform = data }
        }
        cameraManager.processor.onVectorscopeUpdate = { [weak self] data in
            Task { @MainActor in self?.vectorscope = data }
        }
    }

    func detachMonitoringCallbacks() {
        cameraManager.processor.onHistogramUpdate = nil
        cameraManager.processor.onWaveformUpdate = nil
        cameraManager.processor.onVectorscopeUpdate = nil
    }

    // MARK: - Gesture Handlers

    func handleTapToFocus(at normalizedPoint: CGPoint) {
        // Ignore when the focus slider is in manual mode — user owns the lens position.
        guard cameraManager.captureSettings.isAutoFocus else { return }

        // When AEL is active, refocus only — don't move the exposure point.
        cameraManager.setFocusPoint(normalizedPoint,
                                    adjustExposure: !cameraManager.captureSettings.isAELocked)
        // focusIndicatorPosition is set to screen coords by ViewfinderView before this call.
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
                withAnimation(.easeOut(duration: 0.35)) {
                    self.showFocusIndicator = false
                }
                self.isFocusLocked = false
            }
        }
    }

    func handlePinchZoom(scale: CGFloat, velocity: CGFloat) {
        let newZoom = scale.fxClamped(to: 0.5...15.0)
        zoomLevel = newZoom
        cameraManager.setZoom(newZoom)
        isZooming = true
        zoomHideTask?.cancel()
        zoomHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            withAnimation(.easeOut(duration: 0.3)) { self.isZooming = false }
        }
    }

    func setBrightnessBias(_ ev: Float) {
        let delta = CGFloat(ev.fxClamped(to: -3...3) - accumulatedExposureBias)
        handleBrightnessSwipe(delta: delta)
    }

    func handleDoubleTapReset() {
        focusTask?.cancel()
        focusTask = nil
        showFocusIndicator = false
        isFocusLocked = false
        // Set auto flags before dispatching to sessionQueue so KVO callbacks that fire
        // as the hardware switches modes already see auto mode and update the sliders.
        cameraManager.captureSettings.isAutoISO = true
        cameraManager.captureSettings.isAutoShutter = true
        cameraManager.captureSettings.isAutoFocus = true
        cameraManager.captureSettings.isAutoWhiteBalance = true
        cameraManager.captureSettings.whiteBalanceTint = 0
        cameraManager.setAutoExposure()
        cameraManager.setAutoFocus()
        cameraManager.setAutoWhiteBalance()
        cameraManager.setExposureCompensation(0)
        accumulatedExposureBias = 0
        HapticManager.medium()
    }

    // MARK: - AE Lock

    func toggleAELock() {
        if isAELocked {
            cameraManager.unlockAutoExposure()
            HapticManager.light()
        } else {
            cameraManager.lockAutoExposure()
            HapticManager.focusLocked()
        }
    }

    // MARK: - Self-timer

    func startTimerCapture(delay: Double, repeatCount: Int = 1, action: @escaping () -> Void) {
        guard !isTimerActive else { return }
        selfTimerRepeatCount = repeatCount
        selfTimerRepeatCurrent = 0
        isTimerActive = true
        timerCountdown = Int(delay)

        timerTask = Task {
            // repeatCount == 0 means repeat until cancelled
            var shotsTaken = 0
            while !Task.isCancelled && (repeatCount == 0 || shotsTaken < repeatCount) {
                var remaining = Int(delay)
                while remaining > 0 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard !Task.isCancelled else { return }
                    remaining -= 1
                    await MainActor.run { self.timerCountdown = remaining }
                }
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    self.selfTimerRepeatCurrent += 1
                    self.timerCountdown = Int(delay)
                    action()
                }
                shotsTaken += 1
            }
            await MainActor.run {
                self.isTimerActive = false
                self.timerCountdown = 0
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
        isBrightnessAdjusting = true
        brightnessHideTask?.cancel()
        brightnessHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self.isBrightnessAdjusting = false
        }
    }

    // MARK: - Overlay Sync

    /// Caller passes AppStorage flags so this class doesn't need to own them.
    func syncOverlaysToProcessor(
        focusPeaking: Bool = false,
        zebra: Bool = false,
        falseColor: Bool = false,
        waveform: Bool = false,
        vectorscope: Bool = false,
        peakingColorName: String = "red",
        zebraHighThreshold: Float = 0.95,
        zebraLowThreshold: Float = 0.02
    ) {
        cameraManager.processor.isFocusPeakingEnabled = focusPeaking
        cameraManager.processor.isZebraEnabled = zebra
        cameraManager.processor.isFalseColorEnabled = falseColor
        cameraManager.processor.isWaveformEnabled = waveform
        cameraManager.processor.isVectorscopeEnabled = vectorscope
        cameraManager.processor.peakingColor = Self.ciColor(forPeakingColorName: peakingColorName)
        cameraManager.processor.zebraHighThreshold = zebraHighThreshold
        cameraManager.processor.zebraLowThreshold = zebraLowThreshold
        let filter = stylesManager.activeLUTFilter()
        cameraManager.processor.lutFilter = filter
    }

    static func ciColor(forPeakingColorName name: String) -> CIColor {
        switch name {
        case "green":  return CIColor(red: 0.2, green: 1,   blue: 0.2, alpha: 0.9)
        case "white":  return CIColor(red: 1,   green: 1,   blue: 1,   alpha: 0.9)
        case "yellow": return CIColor(red: 1,   green: 0.9, blue: 0,   alpha: 0.9)
        default:       return CIColor(red: 1,   green: 0.2, blue: 0.2, alpha: 0.9)
        }
    }

    // MARK: - Capture

    func capturePhoto(delegate: AVCapturePhotoCaptureDelegate) {
        HapticManager.shutter()
        cameraManager.capturePhoto(delegate: delegate)
    }

    // MARK: - Burst

    /// Fires up to `maxShots` photos 100 ms apart. Call `stopBurst()` to cancel early.
    /// `makeDelegate` is invoked once per shot — AVFoundation delegates must never be reused
    /// across captures (each fires its own didFinishCaptureFor lifecycle).
    func startBurst(maxShots: Int = 10, makeDelegate: @escaping @MainActor () -> AVCapturePhotoCaptureDelegate) {
        guard !isBurstActive else { return }
        isBurstActive = true
        burstCount = 0
        Logger.camera.info("Burst started")

        burstTask = Task {
            for i in 1...max(1, maxShots) {
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    self.burstCount = i
                    self.shutterFlashTick += 1
                    HapticManager.shutter()
                }
                cameraManager.capturePhoto(delegate: makeDelegate(), bypassBusyGuard: true)
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
    /// `makeDelegate` is invoked once per shot — AVFoundation delegates must never be reused.
    func startTimelapse(makeDelegate: @escaping @MainActor () -> AVCapturePhotoCaptureDelegate) {
        guard !isTimelapseActive else { return }
        isTimelapseActive = true
        timelapseCount = 0
        Logger.camera.info("Timelapse started, interval=\(self.timelapseInterval)s")

        timelapseTask = Task {
            while !Task.isCancelled {
                await MainActor.run {
                    self.timelapseCount += 1
                    self.shutterFlashTick += 1
                    HapticManager.shutter()
                }
                cameraManager.capturePhoto(delegate: makeDelegate(), bypassBusyGuard: true)
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
            cropRatioRaw.wrappedValue = preModeRaw
            cameraManager.processor.isAnamorphicDesqueezeEnabled = false
        case .longExposure:
            cameraManager.cancelLongExposureCapture()
            if let saved = savedExposure {
                if saved.autoISO && saved.autoShutter {
                    cameraManager.setAutoExposure()
                    cameraManager.captureSettings.isAutoISO = true
                    cameraManager.captureSettings.isAutoShutter = true
                } else {
                    cameraManager.setManualExposure(iso: saved.iso, duration: saved.shutter)
                    cameraManager.captureSettings.isAutoISO = saved.autoISO
                    cameraManager.captureSettings.isAutoShutter = saved.autoShutter
                }
                savedExposure = nil
            }
        case .night:
            if let saved = savedExposure {
                if saved.autoISO && saved.autoShutter {
                    cameraManager.setAutoExposure()
                    cameraManager.captureSettings.isAutoISO = true
                    cameraManager.captureSettings.isAutoShutter = true
                } else {
                    cameraManager.setManualExposure(iso: saved.iso, duration: saved.shutter)
                    cameraManager.captureSettings.isAutoISO = saved.autoISO
                    cameraManager.captureSettings.isAutoShutter = saved.autoShutter
                }
                savedExposure = nil
            }
            cameraManager.setNightModeEnabled(false)
        case .selfTimer:
            cancelTimer()
        case .portrait:
            cameraManager.setDepthDataEnabled(false)
        case .video:
            cameraManager.stopRecording()
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
            // Enable depth data delivery — Photos.app and compatible apps use this for portrait effects
            cameraManager.setDepthDataEnabled(true)

        case .selfTimer:
            break // user configures delay in the advisory row; don't override their stored setting

        case .longExposure:
            // Save current exposure so it can be restored on exit
            savedExposure = SavedExposure(
                iso: cameraManager.captureSettings.isoValue,
                shutter: cameraManager.captureSettings.shutterSpeed,
                autoISO: cameraManager.captureSettings.isAutoISO,
                autoShutter: cameraManager.captureSettings.isAutoShutter
            )
            // Only preset ISO/shutter as a starting point if the user was in full auto
            if cameraManager.captureSettings.isAutoISO && cameraManager.captureSettings.isAutoShutter {
                cameraManager.captureSettings.isAutoISO = false
                cameraManager.captureSettings.isAutoShutter = false
                cameraManager.setManualExposure(iso: 50, duration: CMTime(value: 1, timescale: 1))
                Logger.camera.info("Long exposure mode: preset ISO 50, 1s (was auto)")
            } else {
                Logger.camera.info("Long exposure mode: keeping user manual exposure")
            }

        case .night:
            // Save current exposure so it can be restored on exit
            savedExposure = SavedExposure(
                iso: cameraManager.captureSettings.isoValue,
                shutter: cameraManager.captureSettings.shutterSpeed,
                autoISO: cameraManager.captureSettings.isAutoISO,
                autoShutter: cameraManager.captureSettings.isAutoShutter
            )
            // Only preset if user was in full auto
            if cameraManager.captureSettings.isAutoISO && cameraManager.captureSettings.isAutoShutter {
                cameraManager.captureSettings.isAutoISO = false
                cameraManager.captureSettings.isAutoShutter = false
                cameraManager.setManualExposure(iso: 3200, duration: CMTime(value: 1, timescale: 15))
                Logger.camera.info("Night mode: preset ISO 3200, 1/15s (was auto)")
            } else {
                Logger.camera.info("Night mode: keeping user manual exposure")
            }
            cameraManager.setNightModeEnabled(true)

        case .burst:
            break // burst starts on shutter press

        case .timelapse:
            break // timelapse starts on shutter press

        case .video:
            break // recording starts on shutter tap

        case .anamorphic:
            // Save current crop, apply 2.39:1 guide, and enable 2× horizontal desqueeze in preview
            preModeRaw = cropRatioRaw.wrappedValue
            cropRatioRaw.wrappedValue = CropRatio.r239_100.rawValue
            cameraManager.processor.isAnamorphicDesqueezeEnabled = true
            Logger.camera.info("Anamorphic mode: 2.39:1 crop + 2× desqueeze enabled")
        }
    }
}
