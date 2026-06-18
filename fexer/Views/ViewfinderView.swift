import SwiftUI

struct ViewfinderView: View {
    @Bindable var cameraViewModel: CameraViewModel
    @State private var focusSquareScale: CGFloat = 1.0
    @State private var focusSquareOpacity: Double = 0.0
    @State private var pinchBaseZoom: CGFloat = 1.0

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Camera preview (fills entire screen)
                CameraPreview(
                    cameraManager: cameraViewModel.cameraManager,
                    onTapToFocus: { normalizedPoint, _ in
                        let screenPoint = CGPoint(
                            x: normalizedPoint.x * geo.size.width,
                            y: normalizedPoint.y * geo.size.height
                        )
                        cameraViewModel.focusIndicatorPosition = screenPoint
                        animateFocusSquare()
                        cameraViewModel.handleTapToFocus(at: normalizedPoint)
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
                }

                // Double-tap gesture for reset (handled separately from camera preview)
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        cameraViewModel.handleDoubleTapReset()
                    }
                    .allowsHitTesting(true)
            }
        }
    }

    private var focusSquare: some View {
        let isLocked = cameraViewModel.isFocusLocked
        let position = cameraViewModel.focusIndicatorPosition

        return RoundedRectangle(cornerRadius: 3)
            .stroke(isLocked ? Color.yellow : .white, lineWidth: isLocked ? 1.5 : 2)
            .frame(width: isLocked ? 60 : 80, height: isLocked ? 60 : 80)
            .scaleEffect(focusSquareScale)
            .opacity(focusSquareOpacity)
            .position(position)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isLocked)
    }

    private func animateFocusSquare() {
        focusSquareScale = 1.3
        focusSquareOpacity = 1.0
        withAnimation(.spring(response: 0.35, dampingFraction: 0.65)) {
            focusSquareScale = 1.0
        }
    }
}
