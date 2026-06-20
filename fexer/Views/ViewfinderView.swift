import SwiftUI

struct ViewfinderView: View {
    @Bindable var cameraViewModel: CameraViewModel
    var cropRatio: CropRatio = .full
    @State private var pinchBaseZoom: CGFloat = 1.0

    var body: some View {
        GeometryReader { geo in
            ZStack {
                #if targetEnvironment(simulator)
                simulatorPlaceholder
                    .frame(width: geo.size.width, height: geo.size.height)
                    .ignoresSafeArea()
                #else
                // Camera preview (fills entire screen).
                // Single-tap (focus) and double-tap (reset) are both handled inside
                // CameraPreview's UIKit layer so there is no SwiftUI overlay blocking taps.
                CameraPreview(
                    cameraManager: cameraViewModel.cameraManager,
                    cropRatio: cropRatio,
                    onTapToFocus: { normalizedPoint, _ in
                        // Invert the AVFoundation coordinate mapping (axes swapped for 90° rotation):
                        //   normalizedPoint.x = tap.y / height  →  tap.y = normalizedPoint.x * height
                        //   normalizedPoint.y = 1 - tap.x / width  →  tap.x = (1 - normalizedPoint.y) * width
                        let screenPoint = CGPoint(
                            x: (1 - normalizedPoint.y) * geo.size.width,
                            y: normalizedPoint.x * geo.size.height
                        )
                        cameraViewModel.focusIndicatorPosition = screenPoint
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.65)) {
                            cameraViewModel.handleTapToFocus(at: normalizedPoint)
                        }
                    },
                    onDoubleTap: {
                        cameraViewModel.handleDoubleTapReset()
                    },
                    onPinchZoom: { scale, velocity in
                        cameraViewModel.handlePinchZoom(scale: scale, velocity: velocity)
                    },
                    onSwipeBrightness: { delta in
                        cameraViewModel.handleBrightnessSwipe(delta: CGFloat(delta))
                    }
                )
                .ignoresSafeArea()

                // Focus square indicator
                if cameraViewModel.showFocusIndicator {
                    focusSquare
                        .transition(.asymmetric(
                            insertion: .scale(scale: 1.3),
                            removal: .opacity
                        ))
                }
                #endif
            }
        }
    }

    #if targetEnvironment(simulator)
    private var simulatorPlaceholder: some View {
        ZStack {
            Color(white: 0.12)
            VStack(spacing: 12) {
                Image(systemName: "camera.slash")
                    .font(.system(size: 48, weight: .thin))
                    .foregroundStyle(.white.opacity(0.4))
                Text("Camera unavailable in Simulator")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                Text("Run on a physical iOS device")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.25))
            }
        }
    }
    #endif

    private var focusSquare: some View {
        let isLocked = cameraViewModel.isFocusLocked
        let position = cameraViewModel.focusIndicatorPosition

        return RoundedRectangle(cornerRadius: 3)
            .stroke(isLocked ? Color.yellow : .white, lineWidth: isLocked ? 1.5 : 2)
            .frame(width: isLocked ? 60 : 80, height: isLocked ? 60 : 80)
            .position(position)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isLocked)
    }
}
