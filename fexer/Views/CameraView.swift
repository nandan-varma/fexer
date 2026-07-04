import SwiftUI
import AVFoundation
import CoreImage
import ImageIO
import Photos
import OSLog

struct CameraView: View {
    @State var cameraManager: CameraManager
    @State var stylesManager: StylesManager
    @State var cameraViewModel: CameraViewModel
    @State var stylesViewModel: StylesViewModel
    @State var galleryViewModel = GalleryViewModel()
    @State var showReview = false
    @State var capturedPhoto: CapturedPhoto?
    @State var showSettings = false
    @State var activeDelegates: [UUID: CapturePhotoDelegate] = [:]
    @State var recordingBlink = true

    @Environment(AppState.self) var appState

    // Overlay visibility — shared keys with SettingsView
    @AppStorage("showHistogram")        var showHistogram         = true
    @AppStorage("showGrid")             var showGrid              = false
    @AppStorage("gridType")             var gridType              = "Thirds"
    @AppStorage("showFocusPeaking")     var showFocusPeaking      = false
    @AppStorage("showZebra")            var showZebra             = false
    @AppStorage("showLevelIndicator")   var showLevelIndicator    = false
    @AppStorage("showStylePicker")      var showStylePicker       = false
    @AppStorage("showShootingModes")    var showShootingModes     = true
    @AppStorage("showGallery")          var showGallery           = true
    @AppStorage("cropRatio")            var cropRatioRaw          = CropRatio.full.rawValue
    @AppStorage("showFalseColor")       var showFalseColor        = false
    @AppStorage("isBracketingEnabled")  var isBracketingEnabled   = false
    @AppStorage("bracketEVStep")        var bracketEVStep: Double = 1.0
    @AppStorage("selfTimerDelay")       var selfTimerDelay: Int   = 0
    @AppStorage("focusPeakingColor")    var focusPeakingColor: String = "red"
    @AppStorage("timelapseInterval")    var timelapseInterval: Double = 5.0
    @AppStorage("defaultCaptureFormat") var defaultCaptureFormat  = "HEIF"
    @AppStorage("isProRAWEnabled")      var isProRAWEnabled       = false
    @AppStorage("volumeButtonBehavior") var volumeButtonBehavior  = "Shutter"
    @AppStorage("watermarkText")        var watermarkText         = ""
    @AppStorage("longExposureDuration") var longExposureDuration: Double = 4.0
    @AppStorage("videoFrameRate")      var videoFrameRate: Int       = 30
    @AppStorage("videoResolution")    var videoResolutionRaw: String = VideoResolution.hd1080p.rawValue
    @AppStorage("isWBBracketEnabled") var isWBBracketEnabled   = false
    @AppStorage("wbBracketKStep")   var wbBracketKStep: Double = 500.0
    @AppStorage("selfTimerRepeat")  var selfTimerRepeat: Int   = 1
    @AppStorage("burstCount")       var burstCount: Int        = 10
    @AppStorage("showWaveform")          var showWaveform          = false
    @AppStorage("showVectorscope")       var showVectorscope       = false
    @AppStorage("isCleanViewActive")     var isCleanViewActive     = false
    @AppStorage("showEVIndicator")       var showEVIndicator       = false
    @AppStorage("showReviewAfterShot")   var showReviewAfterShot   = false
    @AppStorage("zebraHighThreshold")    var zebraHighThreshold: Double = 95.0
    @AppStorage("zebraLowThreshold")     var zebraLowThreshold: Double  = 2.0
    @AppStorage("hintSwipeUpSeen")    var hintSwipeUpSeen      = false

    @AppStorage("torchLevel")           var torchLevel: Double = 1.0
    @AppStorage("stabilizationMode")    var stabilizationModeRaw: String = StabilizationMode.auto.rawValue
    @AppStorage("videoColorSpace")      var videoColorSpaceRaw: String  = VideoColorSpace.sRGB.rawValue
    @AppStorage("isHDREnabled")         var isHDREnabled        = false
    @AppStorage("isOpticalZoomLocked")  var isOpticalZoomLocked = false
    @AppStorage("isTrapFocusEnabled")   var isTrapFocusEnabled  = false

    @State var isZoomDialActive = false
    @State var showPresetsSheet = false
    @State var lastCapturedThumb: UIImage?

    @State var volumeObservation: NSKeyValueObservation?
    @State var volumeInterruptionToken: NSObjectProtocol?
    @State var volumeRouteChangeToken: NSObjectProtocol?
    @State var showSwipeUpHint = false
    @State var aelToastText: String? = nil
    @State var aelToastTask: Task<Void, Never>?
    @State var recordingStartDate: Date? = nil
    @State var nightProcessingAngle: Double = 0

    var stabilizationMode: StabilizationMode {
        StabilizationMode(rawValue: stabilizationModeRaw) ?? .auto
    }
    var videoColorSpace: VideoColorSpace {
        VideoColorSpace(rawValue: videoColorSpaceRaw) ?? .sRGB
    }
    var cropRatio: CropRatio { CropRatio(rawValue: cropRatioRaw) ?? .full }
    var videoResolution: VideoResolution { VideoResolution(rawValue: videoResolutionRaw) ?? .hd1080p }

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

        // ── EV offset indicator ──────────────────────────────────────────────
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

        // ── Histogram ────────────────────────────────────────────────────────
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
        VStack(spacing: 0) {
            Spacer()
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

        if let style = stylesViewModel.beforeAfterStyle {
            StyleBeforeAfterView(style: style) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    stylesViewModel.beforeAfterStyle = nil
                }
            }
            .transition(.opacity)
            .zIndex(11)
        }

        Color.clear
            .sheet(isPresented: $showPresetsSheet) {
                CapturePresetsView(cameraManager: cameraManager, stylesManager: stylesManager)
            }
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
    private var letterboxBarHeight: CGFloat? {
        guard let screen = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen else { return nil }
        let imageSize = cameraManager.previewImageSize
        let imageAspect = imageSize.width > 0 && imageSize.height > 0 ? imageSize.width / imageSize.height : nil
        let barH = cropRatio.letterboxBarHeight(viewSize: screen.bounds.size, imageAspect: imageAspect)
        return barH > 1 ? barH : nil
    }

    // MARK: - Helpers

    func syncProcessor() {
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
}

// MARK: - Logger

extension Logger {
    nonisolated static let camera = Logger(subsystem: "com.nandanvarma.fexer", category: "camera")
}
