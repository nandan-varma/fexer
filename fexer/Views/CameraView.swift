import SwiftUI
import AVFoundation
import Photos
import UniformTypeIdentifiers

struct CameraView: View {
    @State private var cameraManager: CameraManager
    @State private var stylesManager: StylesManager
    @State private var cameraViewModel: CameraViewModel
    @State private var stylesViewModel: StylesViewModel
    @State private var showReview = false
    @State private var capturedPhoto: CapturedPhoto?
    @State private var showSettings = false

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

    @State private var isShutterPressed = false

    private var cropRatio: CropRatio { CropRatio(rawValue: cropRatioRaw) ?? .full }

    init() {
        let cm = CameraManager()
        let sm = StylesManager()
        _cameraManager = State(initialValue: cm)
        _stylesManager = State(initialValue: sm)
        _cameraViewModel = State(initialValue: CameraViewModel(cameraManager: cm, stylesManager: sm))
        _stylesViewModel = State(initialValue: StylesViewModel(stylesManager: sm))
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
                Text("\(cameraViewModel.timerCountdown)")
                    .font(.system(size: 100, weight: .thin, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(color: .black.opacity(0.7), radius: 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(.bottom, 180)
                    .allowsHitTesting(false)
                    .transition(.scale.combined(with: .opacity))
            }

            // ── Grid overlay ─────────────────────────────────────────────────────
            if showGrid {
                GridOverlayView(gridType: GridType(rawValue: gridType) ?? .thirds)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            // ── Histogram ────────────────────────────────────────────────────────
            if showHistogram && !cameraViewModel.histogram.red.isEmpty {
                HistogramView(data: cameraViewModel.histogram)
                    .padding(.top, 60)
                    .padding(.leading, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .allowsHitTesting(false)
            }

            // ── Level indicator ──────────────────────────────────────────────────
            if showLevelIndicator {
                LevelIndicatorView()
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 160)
                    .allowsHitTesting(false)
            }

            // ── Bottom controls ──────────────────────────────────────────────────
            VStack(spacing: 0) {
                Spacer()

                if showStylePicker {
                    StylePickerView(stylesViewModel: stylesViewModel, isExpanded: false)
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
            if cameraViewModel.isPanelExpanded {
                VStack {
                    Spacer()
                    ManualControlsPanel(
                        cameraManager: cameraManager,
                        onSettings: { showSettings = true }
                    ) {
                        cameraViewModel.handleSwipeDown()
                    }
                    .frame(height: 330)
                    .transition(.move(edge: .bottom))
                    .padding(.bottom, 8)
                }
                .ignoresSafeArea(edges: .bottom)
            }

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
            cameraManager.startSession()
            syncProcessor()
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

            // Inner capture button
            Circle()
                .fill(.white)
                .frame(width: 62, height: 62)
                .scaleEffect(isShutterPressed ? 0.88 : 1.0)
                .animation(.easeInOut(duration: 0.08), value: isShutterPressed)
                .onTapGesture { captureAction() }
                .simultaneousGesture(
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
        if isBracketingEnabled {
            cameraManager.capturePhotoBracketed(evStep: Float(bracketEVStep), delegate: delegate)
        } else {
            cameraManager.capturePhoto(delegate: delegate)
        }
    }

    // MARK: - Lens switcher

    private var lensSwitcherRow: some View {
        let factors = cameraManager.availableZoomFactors
        guard !factors.isEmpty else { return AnyView(EmptyView()) }

        return AnyView(
            HStack(spacing: 12) {
                ForEach(factors, id: \.self) { factor in
                    let isActive = abs(cameraManager.currentZoomFactor - factor) < 0.3
                    Button {
                        cameraManager.setZoom(factor)
                        HapticManager.selectionChanged()
                    } label: {
                        Text(zoomLabel(factor))
                            .font(.system(size: 13, weight: isActive ? .bold : .medium, design: .monospaced))
                            .foregroundStyle(isActive ? .black : .white)
                            .frame(width: 44, height: 30)
                            .background(isActive ? Color.yellow : Color.white.opacity(0.2),
                                        in: Capsule())
                    }
                }
            }
        )
    }

    private func zoomLabel(_ factor: CGFloat) -> String {
        factor < 1 ? "0.5×" : factor == 1 ? "1×" : "\(Int(factor))×"
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

    /// Height of each letterbox bar for the selected crop ratio, or nil for Full.
    /// Bars are placed at top and bottom; content fills the full screen width.
    private var letterboxBarHeight: CGFloat? {
        guard let aspect = cropRatio.portraitAspect else { return nil }
        let screen = UIScreen.main.bounds
        let contentH = screen.width / aspect
        let barH = (screen.height - contentH) / 2
        return barH > 1 ? barH : nil
    }

    // MARK: - Helpers

    private func syncProcessor() {
        cameraViewModel.syncOverlaysToProcessor(focusPeaking: showFocusPeaking, zebra: showZebra, falseColor: showFalseColor)
    }

    private func makeCaptureDelegate() -> CapturePhotoDelegate {
        // Snapshot all mutable state at shutter-press time
        let captureLocation = appState.permissionsManager.currentLocation
        let activeStyle = stylesManager.activeStyle
        let styleIntensity = stylesManager.styleIntensity
        let captureSettings = cameraManager.captureSettings

        return CapturePhotoDelegate(
            onProcessed: { photo, shouldShowReview in
                guard let rawData = photo.fileDataRepresentation() else {
                    print("[fexer] fileDataRepresentation returned nil")
                    return
                }

                let dataToSave: Data
                if let style = activeStyle, !photo.isRawPhoto {
                    dataToSave = ExifReader.embedStyleTag(in: rawData, styleName: style.name) ?? rawData
                } else {
                    dataToSave = rawData
                }

                let save = {
                    PHPhotoLibrary.shared().performChanges({
                        let request = PHAssetCreationRequest.forAsset()
                        let options = PHAssetResourceCreationOptions()
                        options.uniformTypeIdentifier = photo.isRawPhoto
                            ? AVFileType.dng.rawValue
                            : UTType.jpeg.identifier
                        request.addResource(with: .photo, data: dataToSave, options: options)
                        request.location = captureLocation
                    }) { _, error in
                        if let error { print("[fexer] Photo save failed: \(error.localizedDescription)") }
                    }
                }

                let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
                if status == .notDetermined {
                    PHPhotoLibrary.requestAuthorization(for: .addOnly) { granted in
                        if granted == .authorized || granted == .limited { save() }
                    }
                } else if status == .authorized || status == .limited {
                    save()
                } else {
                    print("[fexer] Photo library access denied — cannot save")
                }

                guard shouldShowReview else { return }

                let captured = CapturedPhoto(
                    jpegData: rawData,
                    captureSettings: captureSettings,
                    appliedStyle: activeStyle,
                    styleIntensity: styleIntensity,
                    location: captureLocation,
                    exifMetadata: photo.metadata
                )
                Task { @MainActor in
                    capturedPhoto = captured
                    withAnimation(.easeInOut(duration: 0.3)) { showReview = true }
                }
            },
            onCaptureDone: { [cameraManager] in
                // didFinishCaptureFor is guaranteed to fire even on errors,
                // so this is the only safe place to reset isCapturing.
                Task { @MainActor in cameraManager.isCapturing = false }
            }
        )
    }
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
    private let onProcessed: (AVCapturePhoto, Bool) -> Void
    private let onCaptureDone: () -> Void

    init(onProcessed: @escaping (AVCapturePhoto, Bool) -> Void,
         onCaptureDone: @escaping () -> Void) {
        self.onProcessed = onProcessed
        self.onCaptureDone = onCaptureDone
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        if let error {
            print("[fexer] Capture error: \(error.localizedDescription)")
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
        onCaptureDone()
    }
}
