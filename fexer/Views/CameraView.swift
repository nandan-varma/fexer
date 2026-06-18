import SwiftUI
import AVFoundation

struct CameraView: View {
    @State private var cameraManager = CameraManager()
    @State private var stylesManager = StylesManager()
    @State private var cameraViewModel: CameraViewModel
    @State private var stylesViewModel: StylesViewModel
    @State private var showReview = false
    @State private var capturedPhoto: CapturedPhoto?
    @State private var showModeCarousel = false
    @State private var showStylePicker = false
    @State private var histogramPosition: CGSize = .zero

    @Environment(AppState.self) var appState

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
            // Layer 1: Viewfinder (fills screen)
            ViewfinderView(cameraViewModel: cameraViewModel)
                .ignoresSafeArea()

            // Layer 2: Grid overlay
            if cameraViewModel.showGrid {
                GridOverlayView(gridType: cameraViewModel.gridType)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            // Layer 3: Histogram (draggable)
            if cameraViewModel.showHistogram && !cameraViewModel.histogramRed.isEmpty {
                HistogramView(
                    red:   cameraViewModel.histogramRed,
                    green: cameraViewModel.histogramGreen,
                    blue:  cameraViewModel.histogramBlue,
                    luma:  cameraViewModel.histogramLuma
                )
                .offset(histogramPosition)
                .gesture(
                    DragGesture()
                        .onChanged { g in histogramPosition = g.translation }
                )
                .padding(.top, 60)
                .padding(.leading, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .allowsHitTesting(true)
            }

            // Layer 4: Level indicator
            if cameraViewModel.showLevelIndicator {
                LevelIndicatorView()
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 160)
                    .allowsHitTesting(false)
            }

            // Layer 5: Shooting mode carousel
            if showModeCarousel {
                modeCarousel
                    .transition(.move(edge: .leading).combined(with: .opacity))
                    .frame(maxHeight: .infinity, alignment: .center)
            }

            // Layer 6: Bottom UI (always visible)
            VStack(spacing: 0) {
                Spacer()

                // Style picker
                StylePickerView(stylesViewModel: stylesViewModel, isExpanded: showStylePicker)
                    .padding(.bottom, 8)

                // Quick access bar
                quickAccessBar
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)

                // Shutter row
                shutterRow
                    .padding(.horizontal, 28)
                    .padding(.bottom, max(34, 0))
            }

            // Layer 7: Manual controls panel (slides up)
            if cameraViewModel.isPanelExpanded {
                VStack {
                    Spacer()
                    ManualControlsPanel(cameraManager: cameraManager) {
                        cameraViewModel.handleSwipeDown()
                    }
                    .frame(height: 340)
                    .transition(.move(edge: .bottom))
                }
                .ignoresSafeArea(edges: .bottom)
            }

            // Layer 8: Review overlay
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
        .gesture(mainSwipeGesture)
        .onAppear {
            cameraManager.startSession()
            cameraViewModel.syncOverlaysToProcessor()
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            cameraManager.stopSession()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: cameraViewModel.showFocusPeaking) { cameraViewModel.syncOverlaysToProcessor() }
        .onChange(of: cameraViewModel.showZebra)        { cameraViewModel.syncOverlaysToProcessor() }
        .onChange(of: stylesManager.activeStyle)        { cameraViewModel.syncOverlaysToProcessor() }
        .onChange(of: stylesManager.styleIntensity)     { cameraViewModel.syncOverlaysToProcessor() }
    }

    // MARK: - Shutter Row

    private var shutterRow: some View {
        HStack {
            // Gallery quick peek
            Button {
                appState.currentScreen = .gallery
            } label: {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.white.opacity(0.15))
                    .frame(width: 52, height: 52)
                    .overlay(
                        Image(systemName: "photo.stack")
                            .font(.system(size: 22))
                            .foregroundStyle(.white)
                    )
            }

            Spacer()

            // Shutter button
            shutterButton

            Spacer()

            // Flip camera
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

    // MARK: - Shutter Button

    private var shutterButton: some View {
        ZStack {
            // Exposure ring (fills based on EV)
            let ev = cameraManager.captureSettings.exposureCompensation
            let normalizedEV = CGFloat((ev + 3) / 6)
            Circle()
                .trim(from: 0, to: normalizedEV)
                .stroke(evColor(ev: ev), lineWidth: 3)
                .frame(width: 76, height: 76)
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.1), value: ev)

            // Outer ring
            Circle()
                .stroke(.white, lineWidth: 3)
                .frame(width: 76, height: 76)

            // Inner button
            Button {
                cameraViewModel.capturePhoto(delegate: photoCaptureDelegate)
            } label: {
                Circle()
                    .fill(.white)
                    .frame(width: 62, height: 62)
            }
            .buttonStyle(ShutterButtonStyle())
        }
    }

    private func evColor(ev: Float) -> Color {
        if ev < -0.5 { return .blue }
        if ev > 0.5  { return .orange }
        return .white
    }

    // MARK: - Quick Access Bar

    private var quickAccessBar: some View {
        HStack(spacing: 0) {
            ForEach(appState.quickAccessItems) { item in
                Spacer()
                quickAccessButton(item: item)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func quickAccessButton(item: QuickAccessItem) -> some View {
        Button {
            handleQuickAccessTap(item: item)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: iconForQuickItem(item))
                    .font(.system(size: 18))
                    .foregroundStyle(isQuickItemActive(item) ? .yellow : .white)
                    .frame(width: 44, height: 44)
            }
        }
        .buttonStyle(.plain)
    }

    private func iconForQuickItem(_ item: QuickAccessItem) -> String {
        switch item {
        case .flash:
            switch cameraManager.flashMode {
            case .on:  return "bolt.fill"
            case .off: return "bolt.slash"
            case .auto: return "bolt.badge.a"
            @unknown default: return "bolt"
            }
        default: return item.systemImageName
        }
    }

    private func isQuickItemActive(_ item: QuickAccessItem) -> Bool {
        switch item {
        case .flash:       return cameraManager.flashMode == .on
        case .grid:        return cameraViewModel.showGrid
        case .histogram:   return cameraViewModel.showHistogram
        case .focusPeaking:return cameraViewModel.showFocusPeaking
        case .zebra:       return cameraViewModel.showZebra
        case .levelIndicator: return cameraViewModel.showLevelIndicator
        default: return false
        }
    }

    private func handleQuickAccessTap(item: QuickAccessItem) {
        HapticManager.light()
        switch item {
        case .flash:
            let modes: [AVCaptureDevice.FlashMode] = [.off, .on, .auto]
            let current = modes.firstIndex(of: cameraManager.flashMode) ?? 0
            cameraManager.flashMode = modes[(current + 1) % modes.count]
        case .timer:
            break // TODO: self-timer UI
        case .grid:
            cameraViewModel.showGrid.toggle()
        case .histogram:
            cameraViewModel.showHistogram.toggle()
        case .flipCamera:
            cameraManager.flipCamera()
        case .focusPeaking:
            cameraViewModel.showFocusPeaking.toggle()
            cameraViewModel.syncOverlaysToProcessor()
        case .zebra:
            cameraViewModel.showZebra.toggle()
            cameraViewModel.syncOverlaysToProcessor()
        case .levelIndicator:
            cameraViewModel.showLevelIndicator.toggle()
        default:
            break
        }
    }

    // MARK: - Mode Carousel

    private var modeCarousel: some View {
        VStack(spacing: 0) {
            ForEach(Array(ShootingMode.allCases.enumerated()), id: \.element.id) { idx, mode in
                Button {
                    cameraViewModel.selectMode(index: idx)
                    withAnimation { showModeCarousel = false }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: mode.systemImageName)
                            .frame(width: 20)
                        Text(mode.rawValue)
                            .font(.system(size: 14, weight: cameraViewModel.activeModeIndex == idx ? .semibold : .regular))
                    }
                    .foregroundStyle(cameraViewModel.activeModeIndex == idx ? .yellow : .white.opacity(0.8))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .background(cameraViewModel.activeModeIndex == idx ? Color.white.opacity(0.12) : .clear)
                }
                .buttonStyle(.plain)
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.leading, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Main Swipe Gesture

    private var mainSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { g in
                let isVertical = abs(g.translation.height) > abs(g.translation.width)
                let isHorizontal = !isVertical

                if isVertical && g.translation.height < -50 {
                    // Swipe up → manual controls
                    cameraViewModel.handleSwipeUp()
                } else if isHorizontal && g.translation.width < -50 {
                    // Swipe left → mode carousel
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        showModeCarousel.toggle()
                    }
                } else if isHorizontal && g.translation.width > 50 {
                    // Swipe right → gallery
                    appState.currentScreen = .gallery
                }
            }
    }

    // MARK: - Photo Capture Delegate

    private var photoCaptureDelegate: CapturePhotoDelegate {
        CapturePhotoDelegate { photo in
            guard let data = photo.fileDataRepresentation() else { return }
            let captured = CapturedPhoto(
                jpegData: data,
                captureSettings: cameraManager.captureSettings,
                appliedStyle: stylesManager.activeStyle,
                styleIntensity: stylesManager.styleIntensity,
                exifMetadata: photo.metadata
            )
            Task { @MainActor in
                self.capturedPhoto = captured
                withAnimation(.easeInOut(duration: 0.3)) {
                    self.showReview = true
                    self.cameraManager.isCapturing = false
                }
            }
        }
    }
}

// MARK: - Shutter Button Style

struct ShutterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1.0)
            .animation(.easeInOut(duration: 0.08), value: configuration.isPressed)
    }
}

// MARK: - Photo Capture Delegate

final class CapturePhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    let onComplete: (AVCapturePhoto) -> Void

    init(onComplete: @escaping (AVCapturePhoto) -> Void) {
        self.onComplete = onComplete
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        guard error == nil else { return }
        onComplete(photo)
    }
}
