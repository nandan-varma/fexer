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
            // ── Viewfinder ──────────────────────────────────────────────────────
            ViewfinderView(cameraViewModel: cameraViewModel)
                .ignoresSafeArea()

            // ── Grid overlay (flagged) ───────────────────────────────────────────
            if FeatureFlags.gridOverlay && cameraViewModel.showGrid {
                GridOverlayView(gridType: cameraViewModel.gridType)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            // ── Histogram (always shown when flag enabled) ───────────────────────
            if FeatureFlags.histogram && !cameraViewModel.histogramRed.isEmpty {
                HistogramView(
                    red:   cameraViewModel.histogramRed,
                    green: cameraViewModel.histogramGreen,
                    blue:  cameraViewModel.histogramBlue,
                    luma:  cameraViewModel.histogramLuma
                )
                .padding(.top, 60)
                .padding(.leading, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .allowsHitTesting(false)
            }

            // ── Level indicator (flagged) ────────────────────────────────────────
            if FeatureFlags.levelIndicator {
                LevelIndicatorView()
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 160)
                    .allowsHitTesting(false)
            }

            // ── Bottom controls ──────────────────────────────────────────────────
            VStack(spacing: 0) {
                Spacer()

                // Style picker (flagged)
                if FeatureFlags.stylePicker {
                    StylePickerView(stylesViewModel: stylesViewModel, isExpanded: false)
                        .padding(.bottom, 8)
                }

                // Shooting mode label
                if FeatureFlags.shootingModes {
                    shootingModeLabel
                        .padding(.bottom, 8)
                }

                // Lens switcher
                if FeatureFlags.lensSwitch {
                    lensSwitcherRow
                        .padding(.bottom, 14)
                }

                // Shutter row
                shutterRow
                    .padding(.horizontal, 32)
                    .padding(.bottom, max(34, 0))
            }

            // ── Manual controls panel ────────────────────────────────────────────
            if cameraViewModel.isPanelExpanded {
                VStack {
                    Spacer()
                    ManualControlsPanel(cameraManager: cameraManager) {
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
        .onAppear {
            cameraManager.startSession()
            cameraViewModel.syncOverlaysToProcessor()
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            cameraManager.stopSession()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: stylesManager.activeStyle)    { cameraViewModel.syncOverlaysToProcessor() }
        .onChange(of: stylesManager.styleIntensity) { cameraViewModel.syncOverlaysToProcessor() }
    }

    // MARK: - Shutter row

    private var shutterRow: some View {
        HStack {
            // Gallery peek (flagged)
            if FeatureFlags.galleryView {
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

            // Shutter button
            shutterButton

            Spacer()

            // Flip camera
            if FeatureFlags.cameraFlip {
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
            } else {
                Spacer().frame(width: 52, height: 52)
            }
        }
    }

    // MARK: - Shutter button

    private var shutterButton: some View {
        let ev = cameraManager.captureSettings.exposureCompensation
        let fraction = CGFloat((ev + 3) / 6)

        return ZStack {
            // EV ring
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(fraction < 0.5 ? Color.blue : Color.orange, lineWidth: 3)
                .frame(width: 76, height: 76)
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.1), value: ev)

            Circle()
                .stroke(.white, lineWidth: 3)
                .frame(width: 76, height: 76)

            Button {
                HapticManager.shutter()
                cameraManager.capturePhoto(delegate: makeCaptureDelegate())
            } label: {
                Circle()
                    .fill(.white)
                    .frame(width: 62, height: 62)
            }
            .buttonStyle(ShutterButtonStyle())
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

    // MARK: - Shooting mode label (flagged)

    private var shootingModeLabel: some View {
        Text(cameraViewModel.activeMode.rawValue.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.8))
            .tracking(2)
    }

    // MARK: - Swipe up gesture (only for manual controls)

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

    // MARK: - Capture delegate

    private func makeCaptureDelegate() -> CapturePhotoDelegate {
        CapturePhotoDelegate { photo in
            guard let data = photo.fileDataRepresentation() else { return }

            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.uniformTypeIdentifier = photo.isRawPhoto
                    ? AVFileType.dng.rawValue
                    : UTType.jpeg.identifier
                request.addResource(with: .photo, data: data, options: options)
            }, completionHandler: nil)

            let captured = CapturedPhoto(
                jpegData: data,
                captureSettings: cameraManager.captureSettings,
                appliedStyle: stylesManager.activeStyle,
                styleIntensity: stylesManager.styleIntensity,
                exifMetadata: photo.metadata
            )
            Task { @MainActor in
                capturedPhoto = captured
                withAnimation(.easeInOut(duration: 0.3)) {
                    showReview = true
                    cameraManager.isCapturing = false
                }
            }
        }
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
    let onComplete: (AVCapturePhoto) -> Void
    init(onComplete: @escaping (AVCapturePhoto) -> Void) { self.onComplete = onComplete }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        guard error == nil else { return }
        onComplete(photo)
    }
}
