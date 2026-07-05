import SwiftUI

struct ViewfinderView: View {
    @Bindable var cameraViewModel: CameraViewModel
    var cropRatio: CropRatio = .full
    @State private var sunDragBaseEV: Float = 0
    @State private var isSunDragging = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                #if targetEnvironment(simulator)
                simulatorPlaceholder
                    .frame(width: geo.size.width, height: geo.size.height)
                    .ignoresSafeArea()
                #else
                // Camera preview — tap/pinch/swipe handled inside CameraPreview UIKit layer.
                CameraPreview(
                    cameraManager: cameraViewModel.cameraManager,
                    cropRatio: cropRatio,
                    onTapToFocus: { avPoint, screenPoint in
                        cameraViewModel.focusIndicatorPosition = screenPoint
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.65)) {
                            cameraViewModel.handleTapToFocus(at: avPoint)
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

                if cameraViewModel.showFocusIndicator {
                    focusBrackets
                        .transition(.asymmetric(
                            insertion: .scale(scale: 1.3).combined(with: .opacity),
                            removal: .opacity
                        ))
                    if !cameraViewModel.isAELocked {
                        sunEVControl
                            .transition(.opacity)
                    }
                }
                #endif
            }
        }
    }

    // MARK: - Corner bracket focus indicator

    private var focusBrackets: some View {
        let locked = cameraViewModel.isFocusLocked
        let size: CGFloat = locked ? 60 : 80
        let color: Color = locked ? .yellow : .white
        return FocusBracketsView(size: size, color: color, lineWidth: locked ? 1.5 : 2.0)
            .position(cameraViewModel.focusIndicatorPosition)
            .animation(.spring(response: 0.28, dampingFraction: 0.62), value: locked)
    }

    // MARK: - Sun EV drag control

    private var sunEVControl: some View {
        let locked = cameraViewModel.isFocusLocked
        let size: CGFloat = locked ? 60 : 80
        let position = cameraViewModel.focusIndicatorPosition
        let ev = cameraViewModel.accumulatedExposureBias
        let trackH: CGFloat = 110
        let thumbY = -CGFloat(ev / 3.0).fxClamped(to: -1...1) * (trackH / 2)

        return ZStack(alignment: .center) {
            Capsule()
                .fill(.yellow.opacity(0.22))
                .frame(width: 2, height: trackH)
            Rectangle()
                .fill(.yellow.opacity(0.45))
                .frame(width: 8, height: 1)
            Image(systemName: "sun.max.fill")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.yellow)
                .shadow(color: .yellow.opacity(0.45), radius: 5)
                .offset(y: thumbY)
                .animation(.interactiveSpring(), value: ev)
                .gesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { value in
                            if !isSunDragging {
                                isSunDragging = true
                                sunDragBaseEV = cameraViewModel.accumulatedExposureBias
                            }
                            let evDelta = Float(-value.translation.height / 55)
                            cameraViewModel.setBrightnessBias(sunDragBaseEV + evDelta)
                        }
                        .onEnded { _ in isSunDragging = false }
                )
        }
        .position(CGPoint(x: position.x + size / 2 + 26, y: position.y))
        .animation(.spring(response: 0.28, dampingFraction: 0.62), value: locked)
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
}

// MARK: - Corner bracket shape

private struct FocusBracketsView: View {
    let size: CGFloat
    let color: Color
    let lineWidth: CGFloat

    var body: some View {
        Canvas { ctx, _ in
            let corner = size * 0.28
            var path = Path()
            // top-left
            path.move(to: CGPoint(x: 0, y: corner))
            path.addLine(to: .zero)
            path.addLine(to: CGPoint(x: corner, y: 0))
            // top-right
            path.move(to: CGPoint(x: size - corner, y: 0))
            path.addLine(to: CGPoint(x: size, y: 0))
            path.addLine(to: CGPoint(x: size, y: corner))
            // bottom-right
            path.move(to: CGPoint(x: size, y: size - corner))
            path.addLine(to: CGPoint(x: size, y: size))
            path.addLine(to: CGPoint(x: size - corner, y: size))
            // bottom-left
            path.move(to: CGPoint(x: corner, y: size))
            path.addLine(to: CGPoint(x: 0, y: size))
            path.addLine(to: CGPoint(x: 0, y: size - corner))
            ctx.stroke(path, with: .color(color),
                       style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
    }
}
