import SwiftUI
import AVFoundation
import CoreImage
import ImageIO
import Photos
import OSLog

/// Blocks spurious AVAudioSession.outputVolume KVO events during audio session
/// setup and after interruptions (permission dialogs, calls, etc.).
/// Thread-safe: KVO fires on a background thread, interruption handler may be on any thread.
private final class VolumeGate: @unchecked Sendable {
    private var notReadyUntil: Date
    private let lock = NSLock()

    init() { notReadyUntil = Date().addingTimeInterval(2.0) }

    func extend() {
        lock.withLock { notReadyUntil = Date().addingTimeInterval(0.5) }
    }

    var isReady: Bool { lock.withLock { Date() >= notReadyUntil } }
}

struct CameraView: View {
    @State private var cameraManager: CameraManager
    @State private var stylesManager: StylesManager
    @State private var cameraViewModel: CameraViewModel
    @State private var stylesViewModel: StylesViewModel
    @State private var galleryViewModel = GalleryViewModel()
    @State private var showReview = false
    @State private var capturedPhoto: CapturedPhoto?
    @State private var showSettings = false
    @State private var activeDelegates: [UUID: CapturePhotoDelegate] = [:]
    @State private var recordingBlink = true

    @Environment(AppState.self) var appState

    // Overlay visibility — shared keys with SettingsView
    @AppStorage("showHistogram")        private var showHistogram         = true
    @AppStorage("showGrid")             private var showGrid              = false
    @AppStorage("gridType")             private var gridType              = "Thirds"
    @AppStorage("showFocusPeaking")     private var showFocusPeaking      = false
    @AppStorage("showZebra")            private var showZebra             = false
    @AppStorage("showLevelIndicator")   private var showLevelIndicator    = false
    @AppStorage("showStylePicker")      private var showStylePicker       = false
    @AppStorage("showShootingModes")    private var showShootingModes     = true
    @AppStorage("showGallery")          private var showGallery           = true
    @AppStorage("cropRatio")            private var cropRatioRaw          = CropRatio.full.rawValue
    @AppStorage("showFalseColor")       private var showFalseColor        = false
    @AppStorage("isBracketingEnabled")  private var isBracketingEnabled   = false
    @AppStorage("bracketEVStep")        private var bracketEVStep: Double = 1.0
    @AppStorage("selfTimerDelay")       private var selfTimerDelay: Int   = 0
    @AppStorage("focusPeakingColor")    private var focusPeakingColor: String = "red"
    @AppStorage("timelapseInterval")    private var timelapseInterval: Double = 5.0
    @AppStorage("defaultCaptureFormat") private var defaultCaptureFormat  = "HEIF"
    @AppStorage("isProRAWEnabled")      private var isProRAWEnabled       = false
    @AppStorage("volumeButtonBehavior") private var volumeButtonBehavior  = "Shutter"
    @AppStorage("watermarkText")        private var watermarkText         = ""
    @AppStorage("longExposureDuration") private var longExposureDuration: Double = 4.0
    @AppStorage("videoFrameRate")      private var videoFrameRate: Int       = 30
    @AppStorage("videoResolution")    private var videoResolutionRaw: String = VideoResolution.hd1080p.rawValue
    @AppStorage("isWBBracketEnabled") private var isWBBracketEnabled   = false
    @AppStorage("wbBracketKStep")   private var wbBracketKStep: Double = 500.0
    @AppStorage("selfTimerRepeat")  private var selfTimerRepeat: Int   = 1
    @AppStorage("burstCount")       private var burstCount: Int        = 10
    @AppStorage("showWaveform")          private var showWaveform          = false
    @AppStorage("showVectorscope")       private var showVectorscope       = false
    @AppStorage("isCleanViewActive")     private var isCleanViewActive     = false
    @AppStorage("showEVIndicator")       private var showEVIndicator       = false
    @AppStorage("showReviewAfterShot")   private var showReviewAfterShot   = false
    @AppStorage("zebraHighThreshold")    private var zebraHighThreshold: Double = 95.0
    @AppStorage("zebraLowThreshold")     private var zebraLowThreshold: Double  = 2.0
    @AppStorage("hintSwipeUpSeen")    private var hintSwipeUpSeen      = false

    @AppStorage("torchLevel")           private var torchLevel: Double = 1.0
    @AppStorage("stabilizationMode")    private var stabilizationModeRaw: String = StabilizationMode.auto.rawValue
    @AppStorage("videoColorSpace")      private var videoColorSpaceRaw: String  = VideoColorSpace.sRGB.rawValue
    @AppStorage("isHDREnabled")         private var isHDREnabled        = false
    @AppStorage("isOpticalZoomLocked")  private var isOpticalZoomLocked = false
    @AppStorage("isTrapFocusEnabled")   private var isTrapFocusEnabled  = false

    @State private var isZoomDialActive = false
    @State private var showPresetsSheet = false
    @State private var lastCapturedThumb: UIImage?

    @State private var volumeObservation: NSKeyValueObservation?
    @State private var volumeInterruptionToken: NSObjectProtocol?
    @State private var volumeRouteChangeToken: NSObjectProtocol?
    @State private var showSwipeUpHint = false
    @State private var aelToastText: String? = nil
    @State private var aelToastTask: Task<Void, Never>?
    @State private var recordingStartDate: Date? = nil
    @State private var nightProcessingAngle: Double = 0

    private var stabilizationMode: StabilizationMode {
        StabilizationMode(rawValue: stabilizationModeRaw) ?? .auto
    }
    private var videoColorSpace: VideoColorSpace {
        VideoColorSpace(rawValue: videoColorSpaceRaw) ?? .sRGB
    }

    private var cropRatio: CropRatio { CropRatio(rawValue: cropRatioRaw) ?? .full }
    private var videoResolution: VideoResolution { VideoResolution(rawValue: videoResolutionRaw) ?? .hd1080p }

    init(cameraManager: CameraManager, stylesManager: StylesManager) {
        _cameraManager = State(initialValue: cameraManager)
        _stylesManager = State(initialValue: stylesManager)
        _cameraViewModel = State(initialValue: CameraViewModel(cameraManager: cameraManager, stylesManager: stylesManager))
        _stylesViewModel = State(initialValue: StylesViewModel(stylesManager: stylesManager))
    }

    var body: some View {
        mainContent
    }

    private var mainContent: some View {
        let core = ZStack {
            baseLayer
            hudOverlayLayer
            controlLayer
            modalOverlayLayer
        }
        let styleStack = core
            .statusBarHidden()
            .persistentSystemOverlays(.hidden)
            .preferredColorScheme(.dark)
            .gesture(swipeUpGesture)
        let sheetWrapper = styleStack
            .sheet(isPresented: $showSettings) {
                SettingsView(cameraManager: cameraManager, stylesManager: stylesManager)
                    .environment(appState)
            }
        let lifecycle = sheetWrapper
            .onAppear { onCameraViewAppear() }
            .onDisappear { onCameraViewDisappear() }
            .onChange(of: stylesManager.activeStyle)    { syncProcessor() }
            .onChange(of: stylesManager.styleIntensity) { syncProcessor() }
            .onChange(of: showFocusPeaking)             { syncProcessor() }
            .onChange(of: showZebra)                    { syncProcessor() }
            .onChange(of: showFalseColor)               { syncProcessor() }
            .onChange(of: showWaveform)                 { syncProcessor() }
            .onChange(of: showVectorscope)              { syncProcessor() }
            .onChange(of: zebraHighThreshold)           { syncProcessor() }
            .onChange(of: zebraLowThreshold)            { syncProcessor() }
        let features = lifecycle
            .onChange(of: focusPeakingColor)            { syncProcessor() }
            .onChange(of: isCleanViewActive)            { syncProcessor() }
            .onChange(of: cameraViewModel.isPanelExpanded) { _, expanded in
                if expanded && !hintSwipeUpSeen {
                    withAnimation { hintSwipeUpSeen = true }
                }
            }
        let captureBindings = features
            .onChange(of: cameraViewModel.isAELocked) { _, locked in
                aelToastTask?.cancel()
                withAnimation(.easeIn(duration: 0.15)) {
                    aelToastText = locked ? "EXPOSURE LOCKED" : "EXPOSURE UNLOCKED"
                }
                aelToastTask = Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    withAnimation(.easeOut(duration: 0.3)) { aelToastText = nil }
                }
            }
            .onChange(of: timelapseInterval)            { cameraViewModel.timelapseInterval = timelapseInterval }
            .onChange(of: cameraManager.isRecording) { _, recording in
                if recording { recordingBlink.toggle() }
            }
            .onChange(of: defaultCaptureFormat) { _, v in
                cameraManager.captureSettings.captureFormat = CaptureFormat(rawValue: v) ?? .heif
            }
            .onChange(of: isProRAWEnabled) { _, v in
                cameraManager.setProRAWEnabled(v)
            }
            .onChange(of: volumeButtonBehavior) { _, _ in
                volumeObservation?.invalidate()
                volumeObservation = nil
                setupVolumeButtonObserver()
            }
        let settingsSync = captureBindings
            .onChange(of: videoFrameRate) { _, fps in
                cameraManager.configureVideoFrameRate(fps)
            }
            .onChange(of: videoResolutionRaw) { _, raw in
                let res = VideoResolution(rawValue: raw) ?? .hd1080p
                if cameraViewModel.activeMode == .video {
                    cameraManager.configureForVideoMode(resolution: res)
                }
            }
            .onChange(of: cameraViewModel.activeMode) { _, newMode in
                if newMode == .video {
                    cameraManager.configureForVideoMode(resolution: videoResolution)
                } else {
                    cameraManager.configureForPhotoMode()
                }
            }
            .onChange(of: isOpticalZoomLocked) { _, v in
                cameraManager.captureSettings.isOpticalZoomLocked = v
            }
            .onChange(of: isTrapFocusEnabled) { _, v in
                cameraManager.captureSettings.isTrapFocusEnabled = v
            }
        return settingsSync
    }

    // MARK: - Body sub-layers (type-checker optimization)

    @ViewBuilder
    private var baseLayer: some View {
        // Invisible MPVolumeView keeps the system volume HUD from appearing
        // when volume buttons are used as shutter/zoom controls.
        VolumeHUDSuppressor()
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)

        // ── Viewfinder ──────────────────────────────────────────────────────
        ViewfinderView(cameraViewModel: cameraViewModel, cropRatio: cropRatio)
            .ignoresSafeArea()

        // ── Crop letterbox bars (solid black — hide sensor content outside crop) ──
        if let barH = letterboxBarHeight {
            VStack(spacing: 0) {
                Color.black.frame(height: barH)
                Spacer()
                Color.black.frame(height: barH)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var hudOverlayLayer: some View {
        // ── Timer countdown ──────────────────────────────────────────────────
        if cameraViewModel.isTimerActive && cameraViewModel.timerCountdown > 0 {
            let barH = letterboxBarHeight ?? 0
            Text("\(cameraViewModel.timerCountdown)")
                .font(.system(size: 100, weight: .thin, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
                .shadow(color: .black.opacity(0.7), radius: 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .padding(.top, barH)
                .padding(.bottom, max(180, barH + 180))
                .allowsHitTesting(false)
                .transition(.scale.combined(with: .opacity))
        }

        // ── Grid overlay — constrained to the actual preview area ─────────────
        if showGrid {
            GeometryReader { geo in
                let barH = letterboxBarHeight ?? 0
                GridOverlayView(gridType: GridType(rawValue: gridType) ?? .thirds)
                    .frame(width: geo.size.width, height: max(0, geo.size.height - 2 * barH))
                    .offset(y: barH)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }

        // ── Quick-access bar — top of viewfinder ────────────────────────────
        VStack {
            QuickAccessBar(cameraManager: cameraManager, onShowPresets: {
                showPresetsSheet = true
            })
            .environment(appState)
            Spacer()
        }

        // ── Recording indicator — blinking red dot + timecode + audio level ──
        if cameraManager.isRecording {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                    .opacity(recordingBlink ? 1 : 0.2)
                    .animation(.easeInOut(duration: 0.6).repeatForever(), value: recordingBlink)
                Text(formatTimecode(cameraManager.recordingDuration))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                AudioLevelMeterView(level: cameraManager.audioLevel)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.black.opacity(0.55), in: Capsule())
            .rotationEffect(.degrees(DeviceOrientationTracker.shared.rotationAngle))
            .animation(.spring(response: 0.35, dampingFraction: 0.75),
                       value: DeviceOrientationTracker.shared.rotationAngle)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, CameraView.quickBarHeight + 8)
            .allowsHitTesting(false)
            .transition(.opacity)
        }

        // ── EV offset indicator — shows exposureTargetOffset when auto-exposure active ──
        let evOffset = cameraManager.captureSettings.exposureTargetOffset
        if showEVIndicator && !isCleanViewActive && !cameraManager.captureSettings.isAELocked &&
            (cameraManager.captureSettings.isAutoISO || cameraManager.captureSettings.isAutoShutter) {
            EVOffsetIndicator(offset: evOffset,
                              isAELocked: cameraManager.captureSettings.isAELocked)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, CameraView.quickBarHeight + 72)
                .padding(.leading, 16)
                .allowsHitTesting(false)
                .transition(.opacity)
        }

        // ── Aperture badge (read-only hardware value) ────────────────────────
        if !isCleanViewActive {
            let aperture = cameraManager.captureSettings.lensAperture
            Text(String(format: "ƒ/%.1f", aperture))
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, CameraView.quickBarHeight + 52)
                .padding(.trailing, 52)
                .allowsHitTesting(false)
        }

        // ── Macro proximity indicator ─────────────────────────────────────────
        if cameraManager.isMacroSupported && cameraManager.currentZoomFactor < 0.8 {
            Text("MACRO")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.black)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Color.yellow, in: Capsule())
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, CameraView.quickBarHeight + 10)
                .padding(.trailing, 52)
                .allowsHitTesting(false)
        }

        // ── Histogram — stays inside preview area ────────────────────────────
        if showHistogram && !isCleanViewActive && !cameraViewModel.histogram.red.isEmpty {
            HistogramView(data: cameraViewModel.histogram)
                .padding(.top, CameraView.quickBarHeight + 8)
                .padding(.leading, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }

        // ── Waveform monitor ──────────────────────────────────────────────────
        if showWaveform && !isCleanViewActive && !cameraViewModel.waveform.isEmpty {
            WaveformView(
                data: cameraViewModel.waveform,
                highThreshold: Float(zebraHighThreshold / 100),
                lowThreshold: Float(zebraLowThreshold / 100)
            )
            .padding(.top, CameraView.quickBarHeight + 8)
            .padding(.leading, showHistogram ? 152 : 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(false)
        }

        // ── Vectorscope ───────────────────────────────────────────────────────
        if showVectorscope && !isCleanViewActive && !cameraViewModel.vectorscope.isEmpty {
            VectorscopeView(data: cameraViewModel.vectorscope)
                .padding(.top, CameraView.quickBarHeight + 8)
                .padding(.trailing, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .allowsHitTesting(false)
        }

        // ── Scene classifier suggestion badge ────────────────────────────────
        if let suggested = stylesManager.suggestedStyle, stylesManager.activeStyle == nil {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.yellow)
                Text(suggested.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                Button {
                    stylesManager.activeStyle = suggested
                    HapticManager.light()
                } label: {
                    Text("Apply")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.yellow, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.black.opacity(0.6), in: Capsule())
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.top, CameraView.quickBarHeight + 76)
            .padding(.leading, 16)
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
            .allowsHitTesting(true)
        }

        // ── Level indicator — stays inside preview area ──────────────────────
        if showLevelIndicator && !isCleanViewActive {
            LevelIndicatorView()
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, max(160, (letterboxBarHeight ?? 0) + 12))
                .allowsHitTesting(false)
        }

        // ── AEL toast notification ───────────────────────────────────────────
        if let msg = aelToastText {
            Text(msg)
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(cameraViewModel.isAELocked ? .yellow : .white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(.black.opacity(0.65), in: Capsule())
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, CameraView.quickBarHeight + 52)
                .allowsHitTesting(false)
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
        }

        // ── Live EV indicator (brightness swipe) ─────────────────────────────
        if cameraViewModel.isBrightnessAdjusting {
            BrightnessEVIndicator(ev: cameraViewModel.accumulatedExposureBias)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .padding(.trailing, 16)
                .allowsHitTesting(false)
                .transition(.opacity)
        }

        // ── Swipe-up hint ────────────────────────────────────────────────────
        if showSwipeUpHint && !hintSwipeUpSeen && !cameraViewModel.isPanelExpanded {
            SwipeUpHintView()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 180)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private var controlLayer: some View {
        // ── Bottom controls ──────────────────────────────────────────────────
        VStack(spacing: 0) {
            Spacer()

            // Gradient backdrop starts above the lens/shutter row for legibility
            VStack(spacing: 0) {
                if showStylePicker {
                    StylePickerView(stylesViewModel: stylesViewModel, isExpanded: true,
                                   onAdjust: { syncProcessor() })
                        .padding(.bottom, 6)
                }

                if showShootingModes {
                    shootingModePicker
                        .padding(.bottom, 8)
                }

                lensSwitcherRow
                    .padding(.bottom, 16)

                shutterRow
                    .padding(.horizontal, 28)
                    .padding(.bottom, max(34, 0))
            }
            .background(
                LinearGradient(
                    colors: [.clear, .black.opacity(0.55)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea(edges: .bottom)
            )
        }

        // ── Manual controls panel ────────────────────────────────────────────
        // Always rendered (not `if`) so Canvas/Metal pipeline compilation
        // happens at launch, not on first swipe-up gesture.
        VStack {
            Spacer()
            ManualControlsPanel(
                cameraManager: cameraManager,
                onSettings: { showSettings = true }
            ) {
                cameraViewModel.handleSwipeDown()
            }
            .frame(height: cameraManager.captureSettings.isAutoWhiteBalance ? 382 : 428)
            .offset(y: cameraViewModel.isPanelExpanded ? 0 : 480)
            .opacity(cameraViewModel.isPanelExpanded ? 1 : 0)
            .allowsHitTesting(cameraViewModel.isPanelExpanded)
            .padding(.bottom, 8)
        }
        .ignoresSafeArea(edges: .bottom)
    }

    @ViewBuilder
    private var modalOverlayLayer: some View {
        // ── Review ───────────────────────────────────────────────────────────
        if showReview {
            ReviewCarouselView(
                initialPhoto: capturedPhoto,
                galleryViewModel: galleryViewModel,
                onDismiss: {
                    withAnimation(.easeInOut(duration: 0.3)) { showReview = false }
                },
                onOpenFullGallery: {
                    withAnimation(.easeInOut(duration: 0.3)) { showReview = false }
                    appState.currentScreen = .gallery
                }
            )
            .transition(.move(edge: .trailing).combined(with: .opacity))
            .zIndex(10)
        }

        // ── Before / After style preview (long-press on style thumbnail) ────
        if let style = stylesViewModel.beforeAfterStyle {
            StyleBeforeAfterView(style: style) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    stylesViewModel.beforeAfterStyle = nil
                }
            }
            .transition(.opacity)
            .zIndex(11)
        }

        // ── Capture presets sheet ────────────────────────────────────────────
        Color.clear
            .sheet(isPresented: $showPresetsSheet) {
                CapturePresetsView(cameraManager: cameraManager, stylesManager: stylesManager)
            }
    }

    // MARK: - Shutter row

    private var shutterRow: some View {
        HStack(alignment: .center) {
            if showGallery {
                Button {
                    capturedPhoto = nil
                    withAnimation(.easeInOut(duration: 0.3)) { showReview = true }
                } label: {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.white.opacity(0.12))
                        .frame(width: 52, height: 52)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(.white.opacity(0.15), lineWidth: 0.5)
                        )
                        .overlay {
                            if let thumb = lastCapturedThumb {
                                Image(uiImage: thumb)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 52, height: 52)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .transition(.opacity)
                            } else {
                                Image(systemName: "photo.stack")
                                    .font(.system(size: 20, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.9))
                                    .rotationEffect(.degrees(DeviceOrientationTracker.shared.rotationAngle))
                                    .animation(.spring(response: 0.35, dampingFraction: 0.75),
                                               value: DeviceOrientationTracker.shared.rotationAngle)
                            }
                        }
                        .animation(.easeInOut(duration: 0.3), value: lastCapturedThumb != nil)
                }
            } else {
                Spacer().frame(width: 52, height: 52)
            }

            Spacer()
            shutterButton
            Spacer()
            Spacer().frame(width: 52, height: 52)
        }
    }

    // MARK: - Shutter button

    private var shutterButton: some View {
        let ev = cameraManager.captureSettings.exposureCompensation
        let fraction = CGFloat((ev + 3) / 6)
        let aelLocked = cameraViewModel.isAELocked
        let activeMode = cameraViewModel.activeMode
        let isTimelapseActive = cameraViewModel.isTimelapseActive
        let isBurstActive = cameraViewModel.isBurstActive

        // Timelapse: red fill when active, white when idle
        let innerFill: Color = (activeMode == .timelapse && isTimelapseActive) ? .red : .white

        return ZStack {
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(fraction < 0.5 ? Color.blue : Color.orange, lineWidth: 3)
                .frame(width: 76, height: 76)
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.1), value: ev)

            Circle()
                .stroke(aelLocked ? Color.yellow : .white, lineWidth: 3)
                .frame(width: 76, height: 76)
                .animation(.easeInOut(duration: 0.15), value: aelLocked)

            // Inner capture button
            // Burst: long-press starts burst, release stops it
            // Timelapse: tap toggles start/stop
            // Other modes: tap to shoot, long-press to toggle AEL
            if activeMode == .burst {
                // Burst shutter — long-press fires continuously
                Circle()
                    .fill(isBurstActive ? Color.orange : .white)
                    .frame(width: 62, height: 62)
                    .animation(.easeInOut(duration: 0.1), value: isBurstActive)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in
                                if !cameraViewModel.isBurstActive {
                                    let delegate = makeCaptureDelegate()
                                    activeDelegates[delegate.id] = delegate
                                    cameraViewModel.startBurst(delegate: delegate, maxShots: burstCount)
                                }
                            }
                            .onEnded { _ in cameraViewModel.stopBurst() }
                    )
            } else if activeMode == .timelapse {
                // Timelapse shutter — tap toggles
                Button {
                    if isTimelapseActive {
                        cameraViewModel.stopTimelapse()
                    } else {
                        let delegate = makeCaptureDelegate()
                        activeDelegates[delegate.id] = delegate
                        cameraViewModel.startTimelapse(delegate: delegate)
                    }
                } label: {
                    Circle()
                        .fill(innerFill)
                        .frame(width: 62, height: 62)
                }
                .buttonStyle(ShutterButtonStyle())
            } else if activeMode == .video {
                // Video shutter — tap to start/stop recording
                let recording = cameraManager.isRecording
                Button { captureAction() } label: {
                    ZStack {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 62, height: 62)
                        if recording {
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.white)
                                .frame(width: 24, height: 24)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: recording)
                }
                .buttonStyle(ShutterButtonStyle())
            } else {
                // Normal shutter — tap to shoot, long-press to toggle AEL
                Button { captureAction() } label: {
                    Circle()
                        .fill(.white)
                        .frame(width: 62, height: 62)
                }
                .buttonStyle(ShutterButtonStyle())
                .highPriorityGesture(
                    LongPressGesture(minimumDuration: 0.5)
                        .onEnded { _ in cameraViewModel.toggleAELock() }
                )
            }

            // Night mode multi-frame processing indicator
            if activeMode == .night && cameraManager.isCapturing {
                Circle()
                    .trim(from: 0, to: 0.6)
                    .stroke(.yellow, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 82, height: 82)
                    .rotationEffect(.degrees(nightProcessingAngle))
                    .transition(.opacity)
                    .onAppear {
                        nightProcessingAngle = 0
                        withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                            nightProcessingAngle = 360
                        }
                    }
                    .onDisappear { nightProcessingAngle = 0 }
            }

            // AEL badge
            if aelLocked {
                Text("AEL")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Color.yellow, in: Capsule())
                    .offset(y: -48)
                    .transition(.opacity.combined(with: .scale))
            }

            // Burst count badge
            if activeMode == .burst && isBurstActive {
                Text("\(cameraViewModel.burstCount)/\(burstCount)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.orange.opacity(0.85), in: Capsule())
                    .offset(y: 48)
                    .transition(.opacity.combined(with: .scale))
            }

            // Bracket badge
            if isBracketingEnabled && activeMode != .burst {
                let stepLabel = bracketEVStep == 1.0 ? "1" : String(format: "%.1g", bracketEVStep)
                Text("±\(stepLabel)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.black.opacity(0.55), in: Capsule())
                    .offset(y: 48)
            }
        }
    }

    // MARK: - Capture flow

    private func captureAction() {
        if cameraViewModel.isTimerActive {
            cameraViewModel.cancelTimer()
            return
        }
        if cameraViewModel.activeMode == .selfTimer && selfTimerDelay > 0 {
            HapticManager.light()
            cameraViewModel.startTimerCapture(delay: Double(selfTimerDelay), repeatCount: selfTimerRepeat) { performCapture() }
        } else {
            performCapture()
        }
    }

    private func startVideoRecording() {
        let location = appState.permissionsManager.currentLocation
        let styleName = stylesManager.activeStyle?.name
        cameraManager.startRecording(location: location, styleName: styleName)
    }

    private func performCapture() {
        if cameraViewModel.activeMode == .video {
            if cameraManager.isRecording {
                cameraManager.stopRecording()
                recordingStartDate = nil
            } else {
                startVideoRecording()
                recordingStartDate = Date()
            }
            HapticManager.medium()
            return
        }
        if cameraViewModel.activeMode == .longExposure {
            performLongExposureCapture()
            return
        }
        // Screen flash for front-facing camera (no hardware flash on front)
        let isFront = cameraManager.currentDevice?.position == .front
        if isFront && cameraManager.flashMode != .off,
           let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            let screen = scene.screen
            let originalBrightness = screen.brightness
            screen.brightness = 1.0
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                screen.brightness = originalBrightness
            }
        }
        HapticManager.shutter()
        let delegate = makeCaptureDelegate()
        activeDelegates[delegate.id] = delegate
        if isWBBracketEnabled {
            cameraManager.capturePhotoBracketedWB(kStep: Float(wbBracketKStep), captureFormat: cameraManager.captureSettings.captureFormat, flash: cameraManager.flashMode, delegate: delegate)
            return
        }
        if isBracketingEnabled {
            cameraManager.capturePhotoBracketed(evStep: Float(bracketEVStep), delegate: delegate)
        } else {
            cameraManager.capturePhoto(delegate: delegate)
        }
    }

    private func performLongExposureCapture() {
        guard !cameraManager.processor.isLongExposureCapturing else { return }
        HapticManager.shutter()
        let location = appState.permissionsManager.currentLocation
        let captureFilter = stylesManager.makeCaptureFilter()
        let capturedCropRatio = cropRatio
        let capturedWatermark = watermarkText

        cameraManager.processor.beginLongExposureCapture(duration: longExposureDuration) { ciImage in
            Task { @MainActor in
                await self.saveLongExposureImage(
                    ciImage, filter: captureFilter,
                    cropRatio: capturedCropRatio, watermark: capturedWatermark,
                    location: location
                )
            }
        }
    }

    private func saveLongExposureImage(_ ciImage: CIImage, filter: LUTFilter?,
                                        cropRatio: CropRatio, watermark: String,
                                        location: CLLocation?) async {
        var out = ciImage
        if let f = filter {
            f.inputImage = out
            out = f.outputImage ?? out
        }
        // Crop in CI space — free transform on the lazy CIImage graph, no extra decode/encode
        if cropRatio != .full, let aspect = cropRatio.portraitAspect {
            let ext = out.extent
            let currentAspect = ext.width / ext.height
            let cropRect: CGRect
            if aspect <= currentAspect {
                let newW = ext.height * aspect
                cropRect = CGRect(x: ext.origin.x + (ext.width - newW) / 2, y: ext.origin.y,
                                  width: newW, height: ext.height)
            } else {
                let newH = ext.width / aspect
                cropRect = CGRect(x: ext.origin.x, y: ext.origin.y + (ext.height - newH) / 2,
                                  width: ext.width, height: newH)
            }
            out = out.cropped(to: cropRect)
        }
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
              var cg = CIContext.shared.createCGImage(out, from: out.extent, format: .RGBA8, colorSpace: sRGB)
        else { return }

        // Apply watermark onto the rendered CGImage — no second JPEG decode needed
        if !watermark.isEmpty {
            let size = CGSize(width: cg.width, height: cg.height)
            let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1
            let rendered = UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
                UIImage(cgImage: cg).draw(in: CGRect(origin: .zero, size: size))
                let fontSize = max(24, size.width * 0.022)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
                    .foregroundColor: UIColor.white.withAlphaComponent(0.65)
                ]
                let str = NSAttributedString(string: watermark, attributes: attrs)
                let strSize = str.size()
                let padding = fontSize * 1.4
                str.draw(at: CGPoint(x: size.width - strSize.width - padding,
                                     y: size.height - strSize.height - padding))
            }
            if let wCG = rendered.cgImage { cg = wCG }
        }

        guard let jpeg = UIImage(cgImage: cg).jpegData(compressionQuality: 0.95) else { return }

        let assetID: String? = await withCheckedContinuation { cont in
            var capturedID: String?
            PHPhotoLibrary.shared().performChanges({
                let req = PHAssetCreationRequest.forAsset()
                req.addResource(with: .photo, data: jpeg, options: nil)
                req.location = location
                capturedID = req.placeholderForCreatedAsset?.localIdentifier
            }) { success, error in
                if let error { Logger.camera.error("Long exposure save: \(error.localizedDescription)") }
                cont.resume(returning: success ? capturedID : nil)
            }
        }

        HapticManager.light()
        lastCapturedThumb = UIImage(data: jpeg)?.preparingThumbnail(of: CGSize(width: 200, height: 200))
        let photo = CapturedPhoto(
            jpegData: jpeg,
            captureSettings: cameraManager.captureSettings,
            location: location,
            assetLocalIdentifier: assetID
        )
        capturedPhoto = photo
        if showReviewAfterShot {
            withAnimation(.easeInOut(duration: 0.3)) { showReview = true }
        }
    }

    // MARK: - Zoom strip

    private var lensSwitcherRow: some View {
        let factors = cameraManager.availableZoomFactors
        guard factors.count > 1 else { return AnyView(EmptyView()) }

        let live = cameraManager.currentZoomFactor
        let activeFactor = factors.min(by: { abs($0 - live) < abs($1 - live) }) ?? factors[0]
        let isAtStop = abs(live - activeFactor) < 0.05

        return AnyView(
            VStack(spacing: 10) {
                if isZoomDialActive {
                    ZoomDial(
                        factors: factors,
                        currentZoom: live,
                        onZoom: { cameraManager.setZoom($0) },
                        onDismiss: {
                            withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
                                isZoomDialActive = false
                            }
                        }
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .bottom)))
                }

                HStack(spacing: 10) {
                    ForEach(factors, id: \.self) { factor in
                        let isActive = factor == activeFactor
                        let labelText = isActive && !isAtStop ? liveZoomLabel(live) : zoomStopLabel(factor)
                        lensButton(factor: factor, isActive: isActive, labelText: labelText)
                    }
                }
            }
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isZoomDialActive)
        )
    }

    @ViewBuilder
    private func lensButton(factor: CGFloat, isActive: Bool, labelText: String) -> some View {
        if isActive {
            Button {
                if isZoomDialActive {
                    withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) { isZoomDialActive = false }
                }
            } label: {
                lensButtonLabel(text: labelText, isActive: true)
            }
            .highPriorityGesture(
                LongPressGesture(minimumDuration: 0.35)
                    .onEnded { _ in
                        guard !isZoomDialActive else { return }
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                            isZoomDialActive = true
                        }
                        HapticManager.selectionChanged()
                    }
            )
        } else {
            Button {
                cameraManager.setZoom(factor)
                HapticManager.selectionChanged()
                withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) { isZoomDialActive = false }
            } label: {
                lensButtonLabel(text: labelText, isActive: false)
            }
        }
    }

    @ViewBuilder
    private func lensButtonLabel(text: String, isActive: Bool) -> some View {
        Text(text)
            .font(.system(size: 14, weight: isActive ? .bold : .semibold, design: .monospaced))
            .foregroundStyle(isActive ? .black : .white)
            .frame(minWidth: 44, minHeight: 40)
            .padding(.horizontal, 4)
            .background(
                isActive
                    ? AnyShapeStyle(Color.yellow)
                    : AnyShapeStyle(.ultraThinMaterial),
                in: Circle()
            )
            .animation(.spring(response: 0.2, dampingFraction: 0.8), value: isActive)
    }

    // Converts a raw AVFoundation videoZoomFactor to an optical label using the hardware's
    // main-camera reference point (e.g., raw 1.0 on a triple camera with mainFactor=2 → ".5×",
    // raw 2.0 → "1×", raw 6.0 → "3×"). Matches stock iOS camera label format.
    private func opticalLabel(_ rawFactor: CGFloat) -> String {
        let optical = rawFactor / cameraManager.mainCameraZoomFactor
        if optical < 1.0 {
            let s = String(format: "%g", optical)  // e.g. "0.5", "0.75"
            let trimmed = s.hasPrefix("0") ? String(s.dropFirst()) : s  // ".5", ".75"
            return trimmed + "\u{00D7}"
        }
        let r = (optical * 10).rounded() / 10
        if r == r.rounded() { return "\(Int(r))\u{00D7}" }
        return String(format: "%.1f\u{00D7}", r)
    }

    private func zoomStopLabel(_ factor: CGFloat) -> String { opticalLabel(factor) }

    private func liveZoomLabel(_ factor: CGFloat) -> String { opticalLabel(factor) }

    // MARK: - Shooting mode picker + advisory

    /// Horizontally scrollable shooting mode selector with advisory label below.
    private var shootingModePicker: some View {
        VStack(spacing: 4) {
            // Advisory / status line
            modeAdvisoryLine

            // Scrollable mode tabs with frosted glass background
            GeometryReader { geo in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(Array(ShootingMode.allCases.enumerated()), id: \.offset) { idx, mode in
                            let isActive = cameraViewModel.activeModeIndex == idx
                            Button {
                                cameraViewModel.selectMode(
                                    index: idx,
                                    cropRatioRaw: $cropRatioRaw,
                                    selfTimerDelay: $selfTimerDelay
                                )
                            } label: {
                                VStack(spacing: 3) {
                                    HStack(spacing: 4) {
                                        if mode == .night {
                                            Image(systemName: "moon.fill")
                                                .font(.system(size: 8))
                                                .foregroundStyle(.yellow)
                                                .opacity(isActive ? 1 : 0)
                                        }
                                        Text(mode.rawValue.uppercased())
                                            .font(.system(size: 10, weight: isActive ? .bold : .semibold))
                                            .foregroundStyle(isActive ? .yellow : .white.opacity(0.45))
                                            .tracking(1.2)
                                    }
                                    Capsule()
                                        .fill(isActive ? Color.yellow : Color.clear)
                                        .frame(height: 2)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(minWidth: geo.size.width, alignment: .center)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .frame(height: 38)
            .background(.ultraThinMaterial.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 8)
        }
    }

    @ViewBuilder
    private var modeIconBadge: some View {
        switch cameraViewModel.activeMode {
        case .night:
            Image(systemName: "moon.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.yellow)
        case .portrait:
            Image(systemName: "person.crop.circle")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.purple.opacity(0.9))
        case .timelapse:
            if cameraViewModel.isTimelapseActive {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var modeAdvisoryLine: some View {
        switch cameraViewModel.activeMode {
        case .longExposure:
            if cameraManager.processor.isLongExposureCapturing {
                Text("CAPTURING…")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.orange.opacity(0.9))
                    .tracking(1.5)
            } else {
                VStack(spacing: 6) {
                    HStack {
                        Text("BLEND")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.orange.opacity(0.7))
                            .tracking(1.5)
                        Spacer()
                        Text("\(Int(longExposureDuration))S — USE A TRIPOD")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(.orange.opacity(0.85))
                    }
                    Slider(value: $longExposureDuration, in: 1...30, step: 1)
                        .tint(.orange)
                }
                .padding(.horizontal, 16)
            }
        case .timelapse:
            HStack(spacing: 8) {
                if cameraViewModel.isTimelapseActive {
                    Text("\(cameraViewModel.timelapseCount) FRAMES")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.red.opacity(0.9))
                } else {
                    Text("\(timelapseIntervalLabel) INTERVAL")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .tracking(1)
        case .portrait:
            if cameraManager.isDepthDataSupported {
                Text("PORTRAIT")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.purple.opacity(0.7))
                    .tracking(1.5)
            } else {
                Text("DEPTH UNAVAILABLE — FLIP TO BACK CAMERA")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.red.opacity(0.85))
                    .tracking(1.5)
            }
        case .burst:
            if cameraViewModel.isBurstActive {
                Text("\(cameraViewModel.burstCount) / \(burstCount) FRAMES")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.orange.opacity(0.9))
                    .tracking(1.5)
            } else {
                HStack {
                    Text("BURST")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.orange.opacity(0.7))
                        .tracking(1.5)
                    Spacer()
                    Text("\(burstCount) FRAMES")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.orange.opacity(0.85))
                }
                .padding(.horizontal, 16)
                Slider(value: Binding(
                    get: { Double(burstCount) },
                    set: { burstCount = Int($0) }
                ), in: 2...40, step: 1)
                .tint(.orange)
                .padding(.horizontal, 16)
            }
        case .selfTimer:
            VStack(spacing: 6) {
                HStack {
                    Text("DELAY")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .tracking(1.5)
                    Spacer()
                    let delayLabel = selfTimerDelay == 0 ? "OFF" : "\(selfTimerDelay)S"
                    Text(delayLabel)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                }
                Slider(value: Binding(
                    get: { Double(selfTimerDelay) },
                    set: { selfTimerDelay = Int($0) }
                ), in: 0...30, step: 1)
                .tint(.white.opacity(0.7))
                HStack {
                    Text("REPEAT")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .tracking(1.5)
                    Spacer()
                    let repeatLabel = selfTimerRepeat == 0 ? "∞" : "\(selfTimerRepeat)×"
                    Text(repeatLabel)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                }
                Slider(value: Binding(
                    get: { Double(selfTimerRepeat) },
                    set: { selfTimerRepeat = Int($0) }
                ), in: 0...10, step: 1)
                .tint(.white.opacity(0.7))
            }
            .padding(.horizontal, 16)
        case .night:
            Text(cameraManager.isCapturing ? "HOLD STILL — PROCESSING" : "NIGHT — KEEP CAMERA STEADY")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.yellow.opacity(cameraManager.isCapturing ? 0.9 : 0.55))
                .tracking(1.5)
                .animation(.easeInOut(duration: 0.2), value: cameraManager.isCapturing)
        case .video:
            videoControlsRow
        default:
            EmptyView()
        }
    }

    private var timelapseIntervalLabel: String {
        let secs = cameraViewModel.timelapseInterval
        if secs < 60 {
            return "\(Int(secs))s"
        } else {
            return "\(Int(secs / 60))m"
        }
    }

    private var videoControlsRow: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                // Frame rate picker — only show rates the device actually supports
                let supportedFPS = cameraManager.supportedFrameRates(for: videoResolution)
                ForEach(supportedFPS, id: \.self) { fps in
                    let isActive = videoFrameRate == fps
                    Button {
                        videoFrameRate = fps
                        cameraManager.configureVideoFrameRate(fps)
                        HapticManager.selectionChanged()
                    } label: {
                        Text("\(fps)")
                            .font(.system(size: 10, weight: isActive ? .bold : .medium, design: .monospaced))
                            .foregroundStyle(isActive ? .black : .white.opacity(0.6))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(isActive ? Color.yellow : Color.white.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                // Slow-Mo button (when device supports high-FPS)
                if cameraManager.isSlowMotionSupported {
                    let isSlowMo = videoResolution == .slowMo
                    Button {
                        let newRes: VideoResolution = isSlowMo ? .hd1080p : .slowMo
                        videoResolutionRaw = newRes.rawValue
                        if newRes.isSlowMotion {
                            cameraManager.configureForSlowMotion(fps: cameraManager.maxSlowMotionFPS)
                        } else {
                            cameraManager.configureForVideoMode(resolution: newRes)
                        }
                        HapticManager.light()
                    } label: {
                        Text(isSlowMo ? "\(cameraManager.maxSlowMotionFPS)fps" : "Slo-Mo")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(isSlowMo ? .black : .white.opacity(0.8))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(isSlowMo ? Color.yellow : .white.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }

                // Resolution toggle
                Button {
                    guard videoResolution != .slowMo else { return }
                    let newRes: VideoResolution = videoResolution == .hd1080p ? .uhd4K : .hd1080p
                    videoResolutionRaw = newRes.rawValue
                    HapticManager.light()
                } label: {
                    Text(videoResolution == .slowMo ? "1080p" : videoResolution.rawValue)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(videoResolution == .uhd4K ? .yellow : .white.opacity(0.8))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(videoResolution == .uhd4K ? Color.yellow.opacity(0.18) : .white.opacity(0.12),
                                    in: Capsule())
                }
                .buttonStyle(.plain)

                // Codec badge (ProRes-capable devices only)
                if cameraManager.isProResRecordingSupported {
                    let activeCodec = cameraManager.captureSettings.videoSettings.codec
                    Button {
                        let codecs = VideoCodec.allCases
                        let idx = codecs.firstIndex(where: { $0 == activeCodec }) ?? 0
                        cameraManager.captureSettings.videoSettings.codec = codecs[(idx + 1) % codecs.count]
                        HapticManager.light()
                    } label: {
                        Text(activeCodec.rawValue)
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(activeCodec == .proRes ? .yellow : .white.opacity(0.8))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(activeCodec == .proRes ? Color.yellow.opacity(0.18) : .white.opacity(0.12),
                                        in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }

            // Second row: stabilization + color space + HDR
            HStack(spacing: 8) {
                // Stabilization picker
                let stabModes: [StabilizationMode] = [.off, .standard, .cinematic, .auto]
                Menu {
                    ForEach(stabModes) { mode in
                        Button {
                            stabilizationModeRaw = mode.rawValue
                            cameraManager.setVideoStabilizationMode(mode)
                            HapticManager.selectionChanged()
                        } label: {
                            Label(mode.rawValue, systemImage: stabilizationMode == mode ? "checkmark" : "")
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "hand.raised.slash")
                            .font(.system(size: 9))
                        Text(stabilizationMode.rawValue)
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    }
                    .foregroundStyle(stabilizationMode == .off ? .white.opacity(0.5) : .white.opacity(0.9))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.white.opacity(0.1), in: Capsule())
                }
                .buttonStyle(.plain)

                // Color space picker
                let availableSpaces: [VideoColorSpace] = cameraManager.isAppleLogSupported
                    ? VideoColorSpace.allCases
                    : [.sRGB, .p3, .hlg]
                Menu {
                    ForEach(availableSpaces) { cs in
                        Button {
                            videoColorSpaceRaw = cs.rawValue
                            cameraManager.setVideoColorSpace(cs)
                            HapticManager.selectionChanged()
                        } label: {
                            Label(cs.rawValue, systemImage: videoColorSpace == cs ? "checkmark" : "")
                        }
                    }
                } label: {
                    Text(videoColorSpace.rawValue)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(videoColorSpace != .sRGB ? .cyan : .white.opacity(0.6))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(videoColorSpace != .sRGB ? Color.cyan.opacity(0.15) : .white.opacity(0.1),
                                    in: Capsule())
                }
                .buttonStyle(.plain)

                // HDR toggle (when device supports HDR formats)
                if cameraManager.isHDRFormatSupported {
                    Button {
                        isHDREnabled.toggle()
                        cameraManager.setHDREnabled(isHDREnabled)
                        HapticManager.light()
                    } label: {
                        Text("HDR")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(isHDREnabled ? .black : .white.opacity(0.6))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(isHDREnabled ? Color.yellow : .white.opacity(0.1), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Layout constants

    static let quickBarHeight: CGFloat = 50

    // MARK: - Swipe gesture

    private var swipeUpGesture: some Gesture {
        DragGesture(minimumDistance: 40)
            .onEnded { g in
                let isVertical = abs(g.translation.height) > abs(g.translation.width)
                if isVertical && g.translation.height < -40 {
                    cameraViewModel.handleSwipeUp()
                } else if isVertical && g.translation.height > 40 && cameraViewModel.isPanelExpanded {
                    cameraViewModel.handleSwipeDown()
                }
            }
    }

    // MARK: - Crop helpers

    /// Height of each letterbox bar (top and bottom) in screen points, or nil when the preview fills edge-to-edge.
    /// Covers both crop-ratio bars (SwiftUI black bars) and the aspect-fit empty area in "Full" mode.
    private var letterboxBarHeight: CGFloat? {
        guard let screen = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen else { return nil }
        let imageSize = cameraManager.previewImageSize
        let imageAspect = imageSize.width > 0 && imageSize.height > 0 ? imageSize.width / imageSize.height : nil
        let barH = cropRatio.letterboxBarHeight(viewSize: screen.bounds.size, imageAspect: imageAspect)
        return barH > 1 ? barH : nil
    }

    // MARK: - Helpers

    private func syncProcessor() {
        cameraViewModel.syncOverlaysToProcessor(
            focusPeaking: showFocusPeaking && !isCleanViewActive,
            zebra: showZebra && !isCleanViewActive,
            falseColor: showFalseColor && !isCleanViewActive,
            waveform: showWaveform && !isCleanViewActive,
            vectorscope: showVectorscope && !isCleanViewActive,
            peakingColorName: focusPeakingColor,
            zebraHighThreshold: Float(zebraHighThreshold / 100),
            zebraLowThreshold: Float(zebraLowThreshold / 100)
        )
    }

    private func onCameraViewDisappear() {
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
        cameraManager.stopSession()
        cameraManager.cancelLongExposureCapture()
        cameraManager.processor.onPixelBuffer = nil
        cameraViewModel.stopBurst()
        cameraViewModel.stopTimelapse()
        cameraViewModel.cancelTimer()
        aelToastTask?.cancel()
        UIApplication.shared.isIdleTimerDisabled = false
        DeviceOrientationTracker.shared.stop()
    }

    private func onCameraViewAppear() {
        HapticManager.warmUp()
        DeviceOrientationTracker.shared.start()
        cameraManager.startSession()
        syncProcessor()
        cameraManager.processor.onPixelBuffer = stylesViewModel.onFrameAvailable
        // Wire trap focus — when camera locks, fire shutter
        cameraManager.setTrapFocusCallback { [self] in
            guard cameraManager.captureSettings.isTrapFocusEnabled else { return }
            performCapture()
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
        if !hintSwipeUpSeen { scheduleSwipeUpHint() }
        applyPendingShootingMode()
    }

    private func applyPendingShootingMode() {
        guard let mode = appState.pendingShootingMode,
              let index = ShootingMode.allCases.firstIndex(of: mode) else { return }
        appState.pendingShootingMode = nil
        cameraViewModel.selectMode(index: index, cropRatioRaw: $cropRatioRaw, selfTimerDelay: $selfTimerDelay)
    }

    private func scheduleSwipeUpHint() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !hintSwipeUpSeen else { return }
            withAnimation(.easeIn(duration: 0.4)) { showSwipeUpHint = true }
        }
    }

    private func formatTimecode(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }


    // Thread-safe box so onLivePhotoMovie and the save Task share the URL without data races.
    private nonisolated final class MovieURLBox: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: Optional<URL>.none)
        var url: URL? {
            get { lock.withLock { $0 } }
            set { lock.withLock { $0 = newValue } }
        }
    }

    private func makeCaptureDelegate() -> CapturePhotoDelegate {
        let captureLocation = appState.permissionsManager.currentLocation
        let activeStyle = stylesManager.activeStyle
        let styleIntensity = stylesManager.styleIntensity
        let captureSettings = cameraManager.captureSettings
        let captureFilter = stylesManager.makeCaptureFilter()
        let capturedCropRatio = cropRatio
        let capturedWatermark = watermarkText
        let isAnamorphic = cameraManager.processor.isAnamorphicDesqueezeEnabled
        let isPortraitMode = cameraViewModel.activeMode == .portrait
        let movieBox = MovieURLBox()
        let onShowReview: (CapturedPhoto) -> Void = { [self] photo in
            capturedPhoto = photo
            if showReviewAfterShot {
                withAnimation(.easeInOut(duration: 0.3)) { showReview = true }
            }
        }
        let onThumbGenerated: (UIImage?) -> Void = { [self] thumb in
            if let thumb { lastCapturedThumb = thumb }
        }

        let delegate = CapturePhotoDelegate(
            onProcessed: { photo, shouldShowReview in
                guard let rawData = photo.fileDataRepresentation() else {
                    Logger.camera.error("fileDataRepresentation returned nil")
                    return
                }
                // Return immediately so AVFoundation fires didFinishCaptureFor (and clears
                // isCapturing) as soon as the sensor is done — not after post-processing.
                Task.detached(priority: .userInitiated) {
                    let depthData: AVDepthData? = isPortraitMode ? photo.depthData : nil
                    let processedData = CameraView.processCapture(
                        rawData: rawData,
                        isRaw: photo.isRawPhoto,
                        captureFilter: captureFilter,
                        isAnamorphic: isAnamorphic,
                        cropRatio: capturedCropRatio,
                        watermark: capturedWatermark,
                        activeStyle: activeStyle,
                        depthData: depthData
                    )

                    // Generate gallery-button thumbnail for all (non-RAW) captures
                    if !photo.isRawPhoto {
                        let thumb = UIImage(data: processedData)?.preparingThumbnail(of: CGSize(width: 200, height: 200))
                        await MainActor.run { onThumbGenerated(thumb) }
                    }

                    // ponytail: movie URL set by onLivePhotoMovie before save; processing delay makes
                    // this safe in practice — mark with a log if it ever fires nil unexpectedly
                    guard shouldShowReview else {
                        saveToPhotoLibrary(data: processedData, photo: photo,
                                           location: captureLocation, livePhotoMovieURL: movieBox.url)
                        return
                    }

                    // For review captures: save first to get the asset identifier for delete support
                    let assetID: String? = await withCheckedContinuation { cont in
                        saveToPhotoLibrary(data: processedData, photo: photo,
                                           location: captureLocation, livePhotoMovieURL: movieBox.url) { id in
                            cont.resume(returning: id)
                        }
                    }
                    await MainActor.run {
                        let captured = CapturedPhoto(
                            jpegData: processedData,
                            captureSettings: captureSettings,
                            appliedStyle: activeStyle,
                            styleIntensity: styleIntensity,
                            location: captureLocation,
                            exifMetadata: photo.metadata,
                            assetLocalIdentifier: assetID
                        )
                        onShowReview(captured)
                    }
                }
            },
            onCaptureDone: { [cameraManager] delegateID in
                cameraManager.clearCaptureGuard()
                Task { @MainActor [self] in
                    activeDelegates.removeValue(forKey: delegateID)
                }
            }
        )
        delegate.onLivePhotoMovie = { movieBox.url = $0 }
        return delegate
    }

    // MARK: - Volume button observer

    private func setupVolumeButtonObserver() {
        guard volumeButtonBehavior != "Disabled" else { return }
        let session = AVAudioSession.sharedInstance()
        // .playback without .mixWithOthers gives the best chance of suppressing
        // the system volume HUD (combined with VolumeHUDSuppressor in the hierarchy).
        do {
            try session.setCategory(.playback, mode: .default, options: [])
        } catch {
            Logger.camera.error("Audio session setCategory failed: \(error.localizedDescription)")
        }
        do {
            try session.setActive(true)
        } catch {
            Logger.camera.error("Audio session setActive failed: \(error.localizedDescription)")
        }
        // On first launch, mic/photo-library permission dialogs interrupt the audio session.
        // When each dialog ends, AVAudioSession fires a spurious outputVolume KVO with old != new,
        // which would trigger the shutter. VolumeGate blocks events for 500 ms after setup AND
        // re-arms for 500 ms each time an interruption ends, covering the whole permission flow.
        let gate = VolumeGate()
        volumeInterruptionToken = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: nil
        ) { notification in
            guard let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: type) == .ended else { return }
            gate.extend()
            // Retry activation after interruption — the initial attempt may have failed
            // if permission dialogs were competing for the audio hardware (err=-19224).
            try? session.setActive(true)
        }
        volumeRouteChangeToken = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: nil
        ) { _ in gate.extend() }
        volumeObservation = session.observe(\.outputVolume, options: [.old, .new]) { _, change in
            guard gate.isReady else { return }
            guard let old = change.oldValue, let new = change.newValue, old != new else { return }
            Task { @MainActor in self.handleVolumeButton(didIncrease: new > old) }
        }
    }

    private func handleVolumeButton(didIncrease: Bool) {
        switch volumeButtonBehavior {
        case "Shutter":
            captureAction()
        case "Zoom":
            let delta: CGFloat = didIncrease ? 0.5 : -0.5
            let newZoom = (cameraViewModel.zoomLevel + delta).fxClamped(to: 0.5...15.0)
            cameraViewModel.handlePinchZoom(scale: newZoom, velocity: 0)
        default:
            break
        }
    }

    // MARK: - Image post-processing helpers

    /// Fused post-capture pipeline: LUT bake + desqueeze + crop + watermark + XMP tag in one pass.
    /// Runs off the AVFoundation callback thread so isCapturing clears immediately after sensor readout.
    private static func processCapture(
        rawData: Data,
        isRaw: Bool,
        captureFilter: LUTFilter?,
        isAnamorphic: Bool,
        cropRatio: CropRatio,
        watermark: String,
        activeStyle: PhotoStyle?,
        depthData: AVDepthData? = nil
    ) -> Data {
        let needsLUT          = captureFilter != nil && !isRaw
        let needsDesqueeze    = isAnamorphic && !isRaw
        let needsCrop         = !isRaw && cropRatio != .full
        let needsWatermark    = !isRaw && !watermark.isEmpty
        let needsStyleTag     = activeStyle != nil && !isRaw
        let needsPortraitBlur = depthData != nil && !isRaw

        if !needsLUT && !needsDesqueeze && !needsCrop && !needsWatermark && !needsPortraitBlur {
            // Fast path: no pixel work — add XMP tag via source-copy if needed (no full re-encode)
            if let style = activeStyle { return ExifReader.embedStyleTag(in: rawData, styleName: style.name) ?? rawData }
            return rawData
        }

        guard let source = CGImageSourceCreateWithData(rawData as CFData, nil),
              let uti = CGImageSourceGetType(source),
              let ciImage = CIImage(data: rawData, options: [.applyOrientationProperty: true])
        else {
            if needsStyleTag, let style = activeStyle { return ExifReader.embedStyleTag(in: rawData, styleName: style.name) ?? rawData }
            return rawData
        }

        var out = ciImage

        // Portrait depth blur — applied before LUT so the grade sits on top of the blurred image
        if needsPortraitBlur,
           let depth = depthData,
           let blurFilter = CIFilter(name: "CIDepthBlurEffect") {
            let converted = depth.converting(toDepthDataType: kCVPixelFormatType_DisparityFloat32)
            let orientationValue = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])?[kCGImagePropertyOrientation as String] as? UInt32 ?? 1
            let photoOrientation = CGImagePropertyOrientation(rawValue: orientationValue) ?? .up
            let disparityCI = CIImage(cvPixelBuffer: converted.depthDataMap).oriented(photoOrientation)
            blurFilter.setValue(out, forKey: kCIInputImageKey)
            blurFilter.setValue(disparityCI, forKey: "inputDisparityImage")
            blurFilter.setValue(Float(2.8), forKey: "inputAperture")
            if let blurOutput = blurFilter.outputImage {
                out = blurOutput.cropped(to: out.extent)
            }
        }

        if needsLUT, let filter = captureFilter {
            filter.inputImage = out
            out = filter.outputImage ?? out
        }

        // Apply 2× horizontal desqueeze to match what the preview showed
        if needsDesqueeze {
            out = out.transformed(by: CGAffineTransform(scaleX: 2.0, y: 1.0))
        }

        // Crop in CI space — a free transform on the lazy graph, avoids a second decode/encode cycle
        if needsCrop, let aspect = cropRatio.portraitAspect {
            let ext = out.extent
            let currentAspect = ext.width / ext.height
            let cropRect: CGRect
            if aspect <= currentAspect {
                let newW = ext.height * aspect
                cropRect = CGRect(x: ext.origin.x + (ext.width - newW) / 2, y: ext.origin.y,
                                  width: newW, height: ext.height)
            } else {
                let newH = ext.width / aspect
                cropRect = CGRect(x: ext.origin.x, y: ext.origin.y + (ext.height - newH) / 2,
                                  width: ext.width, height: newH)
            }
            out = out.cropped(to: cropRect)
        }

        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else { return rawData }

        // Build metadata props once (shared between both paths)
        var props = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]) ?? [:]
        props[kCGImagePropertyOrientation as String] = 1
        if var tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            props[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        if let style = activeStyle {
            var xmp = props["{XMP}"] as? [String: Any] ?? [:]
            xmp["fexer:AppliedStyle"] = style.name
            props["{XMP}"] = xmp
        }

        if !needsWatermark {
            // Fast path: encode directly from CIImage (GPU→hardware encoder, no 48MB CGImage buffer).
            // CGImageDestinationAddImageFromSource WITHOUT kCGImageDestinationLossyCompressionQuality
            // performs a lossless metadata-only write — compressed pixels are copied unchanged.
            let qualityKey = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
            let ciOpts: [CIImageRepresentationOption: Any] = [qualityKey: 0.92]
            let utiStr = uti as String
            let encodedData: Data?
            if utiStr == "public.heic" || utiStr == "public.heif" {
                encodedData = CIContext.shared.heifRepresentation(of: out, format: .RGBA8, colorSpace: sRGB, options: ciOpts)
            } else {
                encodedData = CIContext.shared.jpegRepresentation(of: out, colorSpace: sRGB, options: ciOpts)
            }
            guard let ciEncoded = encodedData,
                  let ciSrc = CGImageSourceCreateWithData(ciEncoded as CFData, nil)
            else { return rawData }
            let mutableData = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(mutableData, uti, 1, nil) else { return rawData }
            CGImageDestinationAddImageFromSource(dest, ciSrc, 0, props as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { return rawData }
            return mutableData as Data
        }

        // Watermark path: needs a CGImage to draw text onto
        guard var cgImage = CIContext.shared.createCGImage(out, from: out.extent, format: .RGBA8, colorSpace: sRGB)
        else { return rawData }

        let size = CGSize(width: cgImage.width, height: cgImage.height)
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1
        let rendered = UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            UIImage(cgImage: cgImage).draw(in: CGRect(origin: .zero, size: size))
            let fontSize = max(24, size.width * 0.022)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: UIColor.white.withAlphaComponent(0.65)
            ]
            let str = NSAttributedString(string: watermark, attributes: attrs)
            let strSize = str.size()
            let padding = fontSize * 1.4
            str.draw(at: CGPoint(x: size.width - strSize.width - padding,
                                 y: size.height - strSize.height - padding))
        }
        if let wCG = rendered.cgImage { cgImage = wCG }

        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(mutableData, uti, 1, nil) else { return rawData }
        CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return rawData }
        return mutableData as Data
    }

}

// MARK: - Logger

extension Logger {
    nonisolated static let camera = Logger(subsystem: "com.nandanvarma.fexer", category: "camera")
}

// MARK: - Zoom Dial

private struct ZoomDial: View {
    let factors: [CGFloat]
    let currentZoom: CGFloat
    let onZoom: (CGFloat) -> Void
    let onDismiss: () -> Void

    private let arcRadius: CGFloat = 100
    private let arcStartDeg: Double = 215
    private let arcEndDeg: Double = 325

    private var minZoom: CGFloat { factors.first ?? 0.5 }
    private var maxZoom: CGFloat { factors.last ?? 10 }

    private func zoomFraction(_ zoom: CGFloat) -> Double {
        let logMin = log(Double(max(minZoom, 0.01)))
        let logMax = log(Double(max(maxZoom, 0.01)))
        let logZ = log(Double(max(zoom, 0.01))).fxClamped(to: logMin...logMax)
        return (logZ - logMin) / (logMax - logMin)
    }

    private func zoomFromFraction(_ t: Double) -> CGFloat {
        let logMin = log(Double(max(minZoom, 0.01)))
        let logMax = log(Double(max(maxZoom, 0.01)))
        return CGFloat(exp(logMin + t.fxClamped(to: 0...1) * (logMax - logMin)))
    }

    private func zoomToAngleDeg(_ zoom: CGFloat) -> Double {
        arcStartDeg + zoomFraction(zoom) * (arcEndDeg - arcStartDeg)
    }

    private func arcPoint(deg: Double, center: CGPoint, radius: CGFloat) -> CGPoint {
        let rad = deg * .pi / 180
        return CGPoint(x: center.x + radius * cos(rad), y: center.y + radius * sin(rad))
    }

    var body: some View {
        let w: CGFloat = arcRadius * 2 + 60
        let h: CGFloat = arcRadius + 22

        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height)
            let steps = 80

            // Track arc
            var track = Path()
            for i in 0...steps {
                let t = Double(i) / Double(steps)
                let pt = arcPoint(deg: arcStartDeg + t * (arcEndDeg - arcStartDeg),
                                  center: center, radius: arcRadius)
                if i == 0 { track.move(to: pt) } else { track.addLine(to: pt) }
            }
            context.stroke(track, with: .color(.white.opacity(0.2)),
                           style: StrokeStyle(lineWidth: 3, lineCap: .round))

            // Filled arc from start up to current zoom position
            let frac = zoomFraction(currentZoom)
            let fillEndDeg = arcStartDeg + frac * (arcEndDeg - arcStartDeg)
            let fillSteps = max(1, Int(frac * Double(steps)))
            if fillSteps > 0 {
                var fill = Path()
                for i in 0...fillSteps {
                    let t = Double(i) / Double(fillSteps)
                    let pt = arcPoint(deg: arcStartDeg + t * (fillEndDeg - arcStartDeg),
                                      center: center, radius: arcRadius)
                    if i == 0 { fill.move(to: pt) } else { fill.addLine(to: pt) }
                }
                context.stroke(fill, with: .color(.yellow.opacity(0.9)),
                               style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }

            // Tick marks at each optical stop
            for factor in factors {
                let deg = zoomToAngleDeg(factor)
                let inner = arcPoint(deg: deg, center: center, radius: arcRadius - 9)
                let outer = arcPoint(deg: deg, center: center, radius: arcRadius + 9)
                var tick = Path()
                tick.move(to: inner)
                tick.addLine(to: outer)
                context.stroke(tick, with: .color(.white.opacity(0.9)),
                               style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }

            // Thumb at current zoom
            let thumbDeg = zoomToAngleDeg(currentZoom)
            let thumbPt = arcPoint(deg: thumbDeg, center: center, radius: arcRadius)
            var thumb = Path()
            thumb.addEllipse(in: CGRect(x: thumbPt.x - 9, y: thumbPt.y - 9, width: 18, height: 18))
            context.fill(thumb, with: .color(.white))
            context.stroke(thumb, with: .color(.yellow.opacity(0.6)),
                           style: StrokeStyle(lineWidth: 2))
        }
        .frame(width: w, height: h)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let center = CGPoint(x: w / 2, y: h)
                    let dx = value.location.x - center.x
                    let dy = value.location.y - center.y
                    var deg = atan2(dy, dx) * 180 / .pi
                    if deg < 0 { deg += 360 }

                    if deg > arcEndDeg {
                        deg = arcEndDeg
                    } else if deg < arcStartDeg {
                        let toStart = arcStartDeg - deg
                        let toEnd = 360 - arcEndDeg + deg
                        deg = toStart <= toEnd ? arcStartDeg : arcEndDeg
                    }

                    let t = (deg - arcStartDeg) / (arcEndDeg - arcStartDeg)
                    onZoom(zoomFromFraction(t))
                }
                .onEnded { _ in onDismiss() }
        )
    }
}


