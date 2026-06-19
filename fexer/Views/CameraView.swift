import SwiftUI
import AVFoundation
import CoreImage
import ImageIO
import Photos
import OSLog
import MediaPlayer

struct CameraView: View {
    @State private var cameraManager: CameraManager
    @State private var stylesManager: StylesManager
    @State private var cameraViewModel: CameraViewModel
    @State private var stylesViewModel: StylesViewModel
    @State private var showReview = false
    @State private var capturedPhoto: CapturedPhoto?
    @State private var showSettings = false
    @State private var activeDelegates: [UUID: CapturePhotoDelegate] = [:]
    @State private var showMeteringTooltip = false
    @State private var meteringTooltipTask: Task<Void, Never>?
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
    @AppStorage("showShootingModes")    private var showShootingModes     = false
    @AppStorage("showGallery")          private var showGallery           = true
    @AppStorage("cropRatio")            private var cropRatioRaw          = CropRatio.full.rawValue
    @AppStorage("showFalseColor")       private var showFalseColor        = false
    @AppStorage("isBracketingEnabled")  private var isBracketingEnabled   = false
    @AppStorage("bracketEVStep")        private var bracketEVStep: Double = 1.0
    @AppStorage("selfTimerDelay")       private var selfTimerDelay: Int   = 0
    @AppStorage("focusPeakingColor")    private var focusPeakingColor: String = "red"
    @AppStorage("timelapseInterval")    private var timelapseInterval: Double = 5.0
    @AppStorage("defaultCaptureFormat") private var defaultCaptureFormat  = "JPEG"
    @AppStorage("isProRAWEnabled")      private var isProRAWEnabled       = false
    @AppStorage("volumeButtonBehavior") private var volumeButtonBehavior  = "Shutter"
    @AppStorage("watermarkText")        private var watermarkText         = ""
    @AppStorage("longExposureDuration") private var longExposureDuration: Double = 4.0
    @AppStorage("videoFrameRate")   private var videoFrameRate: Int    = 30
    @AppStorage("isWBBracketEnabled") private var isWBBracketEnabled   = false
    @AppStorage("wbBracketKStep")   private var wbBracketKStep: Double = 500.0
    @AppStorage("selfTimerRepeat")  private var selfTimerRepeat: Int   = 1
    @AppStorage("showWaveform")     private var showWaveform           = false
    @AppStorage("showVectorscope")  private var showVectorscope        = false

    @State private var volumeObservation: NSKeyValueObservation?

    private var cropRatio: CropRatio { CropRatio(rawValue: cropRatioRaw) ?? .full }

    init(cameraManager: CameraManager, stylesManager: StylesManager) {
        _cameraManager = State(initialValue: cameraManager)
        _stylesManager = State(initialValue: stylesManager)
        _cameraViewModel = State(initialValue: CameraViewModel(cameraManager: cameraManager, stylesManager: stylesManager))
        _stylesViewModel = State(initialValue: StylesViewModel(stylesManager: stylesManager))
    }

    var body: some View {
        ZStack {
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
                QuickAccessBar(cameraManager: cameraManager)
                    .environment(appState)
                Spacer()
            }

            // ── Recording indicator — blinking red dot + elapsed time ────────────
            if cameraManager.isRecording {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                        .opacity(recordingBlink ? 1 : 0.2)
                        .animation(.easeInOut(duration: 0.6).repeatForever(), value: recordingBlink)
                    Text(formatRecordingTime(cameraManager.recordingDuration))
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.black.opacity(0.55), in: Capsule())
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, CameraView.quickBarHeight + 8)
                .allowsHitTesting(false)
                .transition(.opacity)
            }

            // ── Metering mode button + tooltip ───────────────────────────────────
            VStack(alignment: .trailing, spacing: 4) {
                Button {
                    let next = cameraManager.captureSettings.meteringMode.next
                    cameraManager.setMeteringMode(next)
                    HapticManager.light()
                    showMeteringTooltipBriefly()
                } label: {
                    Image(systemName: cameraManager.captureSettings.meteringMode.systemImage)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(.black.opacity(0.45), in: Circle())
                }

                if showMeteringTooltip {
                    Text(cameraManager.captureSettings.meteringMode.rawValue)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.black.opacity(0.6), in: Capsule())
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.top, CameraView.quickBarHeight + 10)
            .padding(.trailing, 12)

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
            if showHistogram && !cameraViewModel.histogram.red.isEmpty {
                HistogramView(data: cameraViewModel.histogram)
                    .padding(.top, CameraView.quickBarHeight + 8)
                    .padding(.leading, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            // ── Waveform monitor ──────────────────────────────────────────────────
            if showWaveform && !cameraViewModel.histogram.luma.isEmpty {
                WaveformView(data: cameraViewModel.histogram)
                    .padding(.top, CameraView.quickBarHeight + 8)
                    .padding(.leading, showHistogram ? 152 : 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .allowsHitTesting(false)
            }

            // ── Vectorscope ───────────────────────────────────────────────────────
            if showVectorscope {
                VectorscopeView()
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
            if showLevelIndicator {
                LevelIndicatorView()
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, max(160, (letterboxBarHeight ?? 0) + 12))
                    .allowsHitTesting(false)
            }

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

            // ── Review ───────────────────────────────────────────────────────────
            if showReview, let photo = capturedPhoto {
                ReviewView(photo: photo) {
                    withAnimation(.easeInOut(duration: 0.3)) { showReview = false }
                }
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
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .gesture(swipeUpGesture)
        .sheet(isPresented: $showSettings) {
            SettingsView(cameraManager: cameraManager, stylesManager: stylesManager)
                .environment(appState)
        }
        .onAppear {
            HapticManager.warmUp()
            cameraManager.startSession()
            syncProcessor()
            cameraManager.processor.onPixelBuffer = stylesViewModel.onFrameAvailable
            UIApplication.shared.isIdleTimerDisabled = true
            Task { await appState.permissionsManager.requestPhotoLibraryAccess() }
            Task { await appState.permissionsManager.requestMicrophoneAccess() }
            appState.permissionsManager.requestLocationAccess()
            cameraViewModel.timelapseInterval = timelapseInterval
            // Wire persisted capture settings
            cameraManager.captureSettings.captureFormat = CaptureFormat(rawValue: defaultCaptureFormat) ?? .jpeg
            cameraManager.setProRAWEnabled(isProRAWEnabled)
            setupVolumeButtonObserver()
        }
        .onDisappear {
            volumeObservation?.invalidate()
            volumeObservation = nil
            cameraManager.stopSession()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: stylesManager.activeStyle)    { syncProcessor() }
        .onChange(of: stylesManager.styleIntensity) { syncProcessor() }
        .onChange(of: showFocusPeaking)             { syncProcessor() }
        .onChange(of: showZebra)                    { syncProcessor() }
        .onChange(of: showFalseColor)               { syncProcessor() }
        .onChange(of: focusPeakingColor)            { syncProcessor() }
        .onChange(of: timelapseInterval)            { cameraViewModel.timelapseInterval = timelapseInterval }
        .onChange(of: cameraManager.isRecording) { _, recording in
            if recording { recordingBlink.toggle() }
        }
        .onChange(of: defaultCaptureFormat) { _, v in
            cameraManager.captureSettings.captureFormat = CaptureFormat(rawValue: v) ?? .jpeg
        }
        .onChange(of: isProRAWEnabled) { _, v in
            cameraManager.setProRAWEnabled(v)
        }
        .onChange(of: volumeButtonBehavior) { _, _ in
            volumeObservation?.invalidate()
            volumeObservation = nil
            setupVolumeButtonObserver()
        }
        .onChange(of: videoFrameRate) { _, fps in
            cameraManager.configureVideoFrameRate(fps)
        }
    }

    // MARK: - Shutter row

    private var shutterRow: some View {
        HStack(alignment: .center) {
            if showGallery {
                Button { appState.currentScreen = .gallery } label: {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.white.opacity(0.12))
                        .frame(width: 52, height: 52)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(.white.opacity(0.15), lineWidth: 0.5)
                        )
                        .overlay(
                            Image(systemName: "photo.stack")
                                .font(.system(size: 20, weight: .medium))
                                .foregroundStyle(.white.opacity(0.9))
                        )
                }
            } else {
                Spacer().frame(width: 52, height: 52)
            }

            Spacer()
            shutterButton
            Spacer()
            recordButton
        }
    }

    // MARK: - Record button

    private var recordButton: some View {
        let recording = cameraManager.isRecording
        return Button {
            if recording {
                cameraManager.stopRecording()
            } else {
                cameraManager.startRecording()
            }
            HapticManager.medium()
        } label: {
            ZStack {
                Circle()
                    .stroke(.white, lineWidth: 3)
                    .frame(width: 52, height: 52)
                Circle()
                    .fill(recording ? Color.red : Color.white.opacity(0.85))
                    .frame(width: recording ? 22 : 40, height: recording ? 22 : 40)
                    .clipShape(recording ? AnyShape(RoundedRectangle(cornerRadius: 4)) : AnyShape(Circle()))
                    .animation(.easeInOut(duration: 0.2), value: recording)
            }
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
                                    cameraViewModel.startBurst(delegate: delegate)
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
                Text("\(cameraViewModel.burstCount)/10")
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
            cameraViewModel.startTimerCapture(delay: Double(selfTimerDelay)) { performCapture() }
        } else {
            performCapture()
        }
    }

    private func performCapture() {
        if cameraViewModel.activeMode == .video {
            if cameraManager.isRecording {
                cameraManager.stopRecording()
            } else {
                cameraManager.startRecording()
            }
            HapticManager.medium()
            return
        }
        if cameraViewModel.activeMode == .longExposure {
            performLongExposureCapture()
            return
        }
        HapticManager.shutter()
        let delegate = makeCaptureDelegate()
        activeDelegates[delegate.id] = delegate
        if isWBBracketEnabled {
            cameraManager.capturePhotoBracketedWB(kStep: Float(wbBracketKStep), delegate: delegate)
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
                self.saveLongExposureImage(
                    ciImage, filter: captureFilter,
                    cropRatio: capturedCropRatio, watermark: capturedWatermark,
                    location: location
                )
            }
        }
    }

    private func saveLongExposureImage(_ ciImage: CIImage, filter: LUTFilter?,
                                        cropRatio: CropRatio, watermark: String,
                                        location: CLLocation?) {
        var out = ciImage
        if let f = filter {
            f.inputImage = out
            out = f.outputImage ?? out
        }
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
              let cg = CIContext.shared.createCGImage(out, from: out.extent, format: .RGBA8, colorSpace: sRGB),
              let jpeg = UIImage(cgImage: cg).jpegData(compressionQuality: 0.95)
        else { return }

        var data = jpeg
        if cropRatio != .full, let cropped = Self.cropImageData(data, to: cropRatio) { data = cropped }
        if !watermark.isEmpty, let marked = Self.burnWatermark(in: data, text: watermark) { data = marked }

        PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
        } completionHandler: { _, error in
            if let error { Logger.camera.error("Long exposure save: \(error.localizedDescription)") }
        }
        HapticManager.light()
    }

    // MARK: - Zoom strip

    private var lensSwitcherRow: some View {
        let factors = cameraManager.availableZoomFactors
        guard factors.count > 1 else { return AnyView(EmptyView()) }

        let live = cameraManager.currentZoomFactor
        let activeFactor = factors.min(by: { abs($0 - live) < abs($1 - live) }) ?? factors[0]
        let isAtStop = abs(live - activeFactor) < 0.05

        return AnyView(
            HStack(spacing: 8) {
                ForEach(factors, id: \.self) { factor in
                    let isActive = factor == activeFactor
                    Button {
                        cameraManager.setZoom(factor)
                        HapticManager.selectionChanged()
                    } label: {
                        Text(isActive && !isAtStop ? liveZoomLabel(live) : zoomStopLabel(factor))
                            .font(.system(size: 13, weight: isActive ? .bold : .medium, design: .monospaced))
                            .foregroundStyle(isActive ? .black : .white)
                            .frame(height: 30)
                            .padding(.horizontal, 10)
                            .background(isActive ? Color.white : Color.white.opacity(0.15),
                                        in: Capsule())
                    }
                }
            }
            .frame(height: 36)
        )
    }

    private func zoomStopLabel(_ factor: CGFloat) -> String {
        if factor < 1 { return "0.5\u{00D7}" }
        if factor == 1 { return "1\u{00D7}" }
        return "\(Int(factor))\u{00D7}"
    }

    private func liveZoomLabel(_ factor: CGFloat) -> String {
        String(format: "%.1f\u{00D7}", factor)
    }

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
        HStack(spacing: 12) {
            // Frame rate picker
            let supportedFPS = [24, 30, 60, 120, 240]
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
                        .background(isActive ? Color.yellow : Color.white.opacity(0.12),
                                    in: Capsule())
                }
                .buttonStyle(.plain)
            }

            Spacer()

            // Codec badge
            if cameraManager.isProResSupported {
                Button {
                    let codecs = VideoCodec.allCases
                    let idx = codecs.firstIndex(where: { $0 == cameraManager.captureSettings.videoSettings.codec }) ?? 0
                    cameraManager.captureSettings.videoSettings.codec = codecs[(idx + 1) % codecs.count]
                    HapticManager.light()
                } label: {
                    Text(cameraManager.captureSettings.videoSettings.codec.rawValue)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.white.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
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
            focusPeaking: showFocusPeaking,
            zebra: showZebra,
            falseColor: showFalseColor,
            peakingColorName: focusPeakingColor
        )
    }

    private func formatRecordingTime(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    // Show metering mode name for 1.5s then fade out
    private func showMeteringTooltipBriefly() {
        meteringTooltipTask?.cancel()
        withAnimation(.easeIn(duration: 0.15)) { showMeteringTooltip = true }
        meteringTooltipTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.3)) { showMeteringTooltip = false }
            }
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
        let onShowReview: (CapturedPhoto) -> Void = { [self] photo in
            capturedPhoto = photo
            withAnimation(.easeInOut(duration: 0.3)) { showReview = true }
        }

        return CapturePhotoDelegate(
            onProcessed: { photo, shouldShowReview in
                guard let rawData = photo.fileDataRepresentation() else {
                    Logger.camera.error("fileDataRepresentation returned nil")
                    return
                }

                // Bake LUT and/or anamorphic desqueeze into captured image.
                // Portrait photos stay upright via .applyOrientationProperty.
                let styledData: Data = {
                    let needsLUT = captureFilter != nil && !photo.isRawPhoto
                    let needsDesqueeze = isAnamorphic && !photo.isRawPhoto
                    guard needsLUT || needsDesqueeze,
                          let source = CGImageSourceCreateWithData(rawData as CFData, nil),
                          let uti = CGImageSourceGetType(source),
                          let ciImage = CIImage(data: rawData, options: [.applyOrientationProperty: true])
                    else { return rawData }

                    var out = ciImage

                    if needsLUT, let filter = captureFilter {
                        filter.inputImage = out
                        out = filter.outputImage ?? out
                    }

                    // Apply 2× horizontal desqueeze to match what the preview showed
                    if needsDesqueeze {
                        out = out.transformed(by: CGAffineTransform(scaleX: 2.0, y: 1.0))
                    }

                    guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
                          let cgImage = CIContext.shared.createCGImage(
                              out, from: out.extent, format: .RGBA8, colorSpace: sRGB)
                    else { return rawData }

                    let mutableData = NSMutableData()
                    guard let dest = CGImageDestinationCreateWithData(mutableData, uti, 1, nil)
                    else { return rawData }

                    var props = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]) ?? [:]
                    props[kCGImagePropertyOrientation as String] = 1
                    if var tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
                        tiff[kCGImagePropertyTIFFOrientation as String] = 1
                        props[kCGImagePropertyTIFFDictionary as String] = tiff
                    }
                    CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
                    guard CGImageDestinationFinalize(dest) else { return rawData }
                    return mutableData as Data
                }()

                // Apply crop to match viewfinder ratio (RAW skipped — raw data is always full-frame)
                var processedData = styledData
                if !photo.isRawPhoto && capturedCropRatio != .full {
                    processedData = Self.cropImageData(processedData, to: capturedCropRatio) ?? processedData
                }

                // Burn watermark text onto non-RAW images
                if !photo.isRawPhoto && !capturedWatermark.isEmpty {
                    processedData = Self.burnWatermark(in: processedData, text: capturedWatermark) ?? processedData
                }

                let dataToSave: Data
                if let style = activeStyle, !photo.isRawPhoto {
                    dataToSave = ExifReader.embedStyleTag(in: processedData, styleName: style.name) ?? processedData
                } else {
                    dataToSave = processedData
                }

                saveToPhotoLibrary(data: dataToSave, photo: photo, location: captureLocation)

                guard shouldShowReview else { return }

                let captured = CapturedPhoto(
                    jpegData: processedData,
                    captureSettings: captureSettings,
                    appliedStyle: activeStyle,
                    styleIntensity: styleIntensity,
                    location: captureLocation,
                    exifMetadata: photo.metadata
                )
                onShowReview(captured)
            },
            onCaptureDone: { [cameraManager] delegateID in
                Task { @MainActor [self] in
                    cameraManager.isCapturing = false
                    activeDelegates.removeValue(forKey: delegateID)
                }
            }
        )
    }

    // MARK: - Volume button observer

    private func setupVolumeButtonObserver() {
        guard volumeButtonBehavior != "Disabled" else { return }
        let session = AVAudioSession.sharedInstance()
        // .playback without .mixWithOthers gives the best chance of suppressing
        // the system volume HUD (combined with VolumeHUDSuppressor in the hierarchy).
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true)
        volumeObservation = session.observe(\.outputVolume, options: [.old, .new]) { _, change in
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

    /// Center-crops JPEG data to match the given crop ratio. Metadata is preserved.
    private static func cropImageData(_ data: Data, to ratio: CropRatio) -> Data? {
        guard let aspect = ratio.portraitAspect,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let uti = CGImageSourceGetType(source),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }

        let imgW = CGFloat(cgImage.width)
        let imgH = CGFloat(cgImage.height)
        let currentAspect = imgW / imgH

        let cropRect: CGRect
        if aspect <= currentAspect {
            // Target is narrower — crop width, keep full height
            let newW = imgH * aspect
            cropRect = CGRect(x: (imgW - newW) / 2, y: 0, width: newW, height: imgH)
        } else {
            // Target is wider — crop height, keep full width
            let newH = imgW / aspect
            cropRect = CGRect(x: 0, y: (imgH - newH) / 2, width: imgW, height: newH)
        }

        guard let cropped = cgImage.cropping(to: cropRect) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, uti, 1, nil) else { return nil }
        var props = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]) ?? [:]
        props[kCGImagePropertyOrientation as String] = 1
        CGImageDestinationAddImage(dest, cropped, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// Renders text as a watermark in the bottom-right corner of a JPEG image.
    private static func burnWatermark(in data: Data, text: String) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let uti = CGImageSourceGetType(source),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }

        let size = CGSize(width: cgImage.width, height: cgImage.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIImage(cgImage: cgImage).draw(in: CGRect(origin: .zero, size: size))
            let fontSize = max(24, size.width * 0.022)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: UIColor.white.withAlphaComponent(0.65)
            ]
            let str = NSAttributedString(string: text, attributes: attrs)
            let strSize = str.size()
            let padding = fontSize * 1.4
            str.draw(at: CGPoint(x: size.width - strSize.width - padding,
                                 y: size.height - strSize.height - padding))
        }

        guard let watermarkedCG = rendered.cgImage else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, uti, 1, nil) else { return nil }
        var props = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]) ?? [:]
        props[kCGImagePropertyOrientation as String] = 1
        CGImageDestinationAddImage(dest, watermarkedCG, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}

// MARK: - Logger

extension Logger {
    nonisolated static let camera = Logger(subsystem: "com.nandanvarma.fexer", category: "camera")
}

// MARK: - Supporting types

struct ShutterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1.0)
            .animation(.easeInOut(duration: 0.08), value: configuration.isPressed)
    }
}

final class CapturePhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    let id: UUID
    private let onProcessed: (AVCapturePhoto, Bool) -> Void
    private let onCaptureDone: (UUID) -> Void

    init(id: UUID = UUID(),
         onProcessed: @escaping (AVCapturePhoto, Bool) -> Void,
         onCaptureDone: @escaping (UUID) -> Void) {
        self.id = id
        self.onProcessed = onProcessed
        self.onCaptureDone = onCaptureDone
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        if let error {
            Logger.camera.error("Capture error: \(error.localizedDescription)")
            return
        }
        var shouldShowReview = true
        // RAW in a RAW+JPEG capture: expectedPhotoCount == 2 means JPEG will follow
        if photo.isRawPhoto && photo.resolvedSettings.expectedPhotoCount > 1 {
            shouldShowReview = false
        }
        // Bracketed capture: only show review for the EV-0 frame
        if let auto = photo.bracketSettings
            as? AVCaptureAutoExposureBracketedStillImageSettings {
            shouldShowReview = abs(auto.exposureTargetBias) < 0.01
        }
        onProcessed(photo, shouldShowReview)
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        onCaptureDone(id)
    }
}

// MARK: - Volume HUD suppressor

/// Adds a zero-size MPVolumeView to the UIKit hierarchy so the system knows
/// the app is managing volume display itself, suppressing the built-in HUD.
private struct VolumeHUDSuppressor: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView()
        view.alpha = 0.001
        view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}
