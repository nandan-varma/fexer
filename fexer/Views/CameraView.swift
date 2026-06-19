import SwiftUI
import AVFoundation
import OSLog

struct CameraView: View {
    @State private var cameraManager: CameraManager
    @State private var stylesManager: StylesManager
    @State private var cameraViewModel: CameraViewModel
    @State private var stylesViewModel: StylesViewModel
    @State private var showReview = false
    @State private var capturedPhoto: CapturedPhoto?
    @State private var showSettings = false
    @State private var activeDelegates: [UUID: CapturePhotoDelegate] = [:]

    @Environment(AppState.self) var appState

    // Overlay visibility — shared keys with SettingsView
    @AppStorage("showHistogram")      private var showHistogram      = true
    @AppStorage("showGrid")           private var showGrid           = false
    @AppStorage("gridType")           private var gridType           = "Thirds"
    @AppStorage("showFocusPeaking")   private var showFocusPeaking   = false
    @AppStorage("showZebra")          private var showZebra          = false
    @AppStorage("showLevelIndicator") private var showLevelIndicator = false
    @AppStorage("showStylePicker")    private var showStylePicker    = false
    @AppStorage("showShootingModes")  private var showShootingModes  = false
    @AppStorage("showGallery")        private var showGallery        = true
    @AppStorage("cropRatio")           private var cropRatioRaw          = CropRatio.full.rawValue
    @AppStorage("showFalseColor")      private var showFalseColor         = false
    @AppStorage("isBracketingEnabled") private var isBracketingEnabled    = false
    @AppStorage("bracketEVStep")       private var bracketEVStep: Double  = 1.0
    @AppStorage("selfTimerDelay")      private var selfTimerDelay: Int    = 0
    @AppStorage("focusPeakingColor")   private var focusPeakingColor: String = "red"

    private var cropRatio: CropRatio { CropRatio(rawValue: cropRatioRaw) ?? .full }

    init(cameraManager: CameraManager, stylesManager: StylesManager) {
        _cameraManager = State(initialValue: cameraManager)
        _stylesManager = State(initialValue: stylesManager)
        _cameraViewModel = State(initialValue: CameraViewModel(cameraManager: cameraManager, stylesManager: stylesManager))
        _stylesViewModel = State(initialValue: StylesViewModel(stylesManager: stylesManager))
    }

    var body: some View {
        ZStack {
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

            // ── Histogram — stays inside preview area ────────────────────────────
            if showHistogram && !cameraViewModel.histogram.red.isEmpty {
                HistogramView(data: cameraViewModel.histogram)
                    .padding(.top, max(60, (letterboxBarHeight ?? 0) + 16))
                    .padding(.leading, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

                if showStylePicker {
                    StylePickerView(stylesViewModel: stylesViewModel, isExpanded: false,
                                   onAdjust: { syncProcessor() })
                        .padding(.bottom, 8)
                }

                if showShootingModes {
                    shootingModeLabel
                        .padding(.bottom, 8)
                }

                lensSwitcherRow
                    .padding(.bottom, 14)

                shutterRow
                    .padding(.horizontal, 32)
                    .padding(.bottom, max(34, 0))
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
                .frame(height: cameraManager.captureSettings.isAutoWhiteBalance ? 330 : 376)
                .offset(y: cameraViewModel.isPanelExpanded ? 0 : 420)
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
            // Feed live frames to StylePreviewRenderer so thumbnails can be generated
            cameraManager.processor.onPixelBuffer = stylesViewModel.onFrameAvailable
            UIApplication.shared.isIdleTimerDisabled = true
            Task { await appState.permissionsManager.requestPhotoLibraryAccess() }
            appState.permissionsManager.requestLocationAccess()
        }
        .onDisappear {
            cameraManager.stopSession()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: stylesManager.activeStyle)    { syncProcessor() }
        .onChange(of: stylesManager.styleIntensity) { syncProcessor() }
        .onChange(of: showFocusPeaking)             { syncProcessor() }
        .onChange(of: showZebra)                    { syncProcessor() }
        .onChange(of: showFalseColor)               { syncProcessor() }
        .onChange(of: focusPeakingColor)            { syncProcessor() }
    }

    // MARK: - Shutter row

    private var shutterRow: some View {
        HStack {
            if showGallery {
                Button { appState.currentScreen = .gallery } label: {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.white.opacity(0.15))
                        .frame(width: 52, height: 52)
                        .overlay(Image(systemName: "photo.stack").font(.system(size: 22)).foregroundStyle(.white))
                }
            } else {
                Spacer().frame(width: 52, height: 52)
            }

            Spacer()
            shutterButton
            Spacer()

            Button {
                cameraManager.flipCamera()
                HapticManager.medium()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath.camera")
                    .font(.system(size: 22))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(.white.opacity(0.15), in: Circle())
            }
        }
    }

    // MARK: - Shutter button

    private var shutterButton: some View {
        let ev = cameraManager.captureSettings.exposureCompensation
        let fraction = CGFloat((ev + 3) / 6)
        let aelLocked = cameraViewModel.isAELocked

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

            // Inner capture button — tap to shoot, long-press to toggle AEL
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

            // Bracket badge
            if isBracketingEnabled {
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
        HapticManager.shutter()
        let delegate = makeCaptureDelegate()
        activeDelegates[delegate.id] = delegate
        if isBracketingEnabled {
            cameraManager.capturePhotoBracketed(evStep: Float(bracketEVStep), delegate: delegate)
        } else {
            cameraManager.capturePhoto(delegate: delegate)
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

    // MARK: - Shooting mode label

    private var shootingModeLabel: some View {
        Text(cameraViewModel.activeMode.rawValue.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.8))
            .tracking(2)
    }

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
        let screen = UIScreen.main
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

    private func makeCaptureDelegate() -> CapturePhotoDelegate {
        let captureLocation = appState.permissionsManager.currentLocation
        let activeStyle = stylesManager.activeStyle
        let styleIntensity = stylesManager.styleIntensity
        let captureSettings = cameraManager.captureSettings
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

                let dataToSave: Data
                if let style = activeStyle, !photo.isRawPhoto {
                    dataToSave = ExifReader.embedStyleTag(in: rawData, styleName: style.name) ?? rawData
                } else {
                    dataToSave = rawData
                }

                saveToPhotoLibrary(data: dataToSave, photo: photo, location: captureLocation)

                guard shouldShowReview else { return }

                let captured = CapturedPhoto(
                    jpegData: rawData,
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
}

// MARK: - Logger

extension Logger {
    static let camera = Logger(subsystem: "com.nandanvarma.fexer", category: "camera")
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
