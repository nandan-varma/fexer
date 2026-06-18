import SwiftUI

struct ManualControlsPanel: View {
    @Bindable var cameraManager: CameraManager
    var onDismiss: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            // Drag handle
            RoundedRectangle(cornerRadius: 2.5)
                .fill(.white.opacity(0.3))
                .frame(width: 36, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 14)
                .contentShape(Rectangle())
                .onTapGesture { onDismiss?() }

            // Exposure compensation strip (always visible at top of panel)
            ExposureCompensationStrip(cameraManager: cameraManager)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)

            Divider()
                .background(.white.opacity(0.15))
                .padding(.horizontal, 16)

            // Manual sliders
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 28) {
                    ISOSlider(
                        iso: $cameraManager.captureSettings.isoValue,
                        isAuto: $cameraManager.captureSettings.isAutoISO
                    ) { cameraManager.setISO(cameraManager.captureSettings.isoValue) }

                    ShutterSlider(
                        shutterSpeed: $cameraManager.captureSettings.shutterSpeed,
                        isAuto: $cameraManager.captureSettings.isAutoShutter
                    ) { cameraManager.setShutterSpeed(cameraManager.captureSettings.shutterSpeed) }

                    WhiteBalanceSlider(
                        kelvin: $cameraManager.captureSettings.whiteBalance,
                        isAuto: $cameraManager.captureSettings.isAutoWhiteBalance
                    ) { cameraManager.setWhiteBalance(kelvin: cameraManager.captureSettings.whiteBalance) }

                    FocusSlider(
                        lensPosition: $cameraManager.captureSettings.focusDistance,
                        isAuto: $cameraManager.captureSettings.isAutoFocus
                    ) { cameraManager.setFocus(lensPosition: cameraManager.captureSettings.focusDistance) }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
            }

            Spacer(minLength: 20)
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 0.5)
        )
        .gesture(
            DragGesture()
                .onEnded { g in
                    if g.translation.height > 60 { onDismiss?() }
                }
        )
    }
}

private struct ExposureCompensationStrip: View {
    let cameraManager: CameraManager
    @State private var ev: Float = 0

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text("EV")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .tracking(1)
                Spacer()
                Text(ev >= 0 ? "+\(String(format: "%.1f", ev))" : String(format: "%.1f", ev))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.yellow)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.white.opacity(0.15))
                        .frame(height: 4)

                    let fraction = CGFloat((ev + 3) / 6)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(fraction < 0.5 ? Color.blue.opacity(0.8) : Color.orange.opacity(0.8))
                        .frame(width: max(2, abs(fraction - 0.5) * geo.size.width), height: 4)
                        .offset(x: fraction < 0.5 ? fraction * geo.size.width : geo.size.width * 0.5)

                    // Center mark
                    RoundedRectangle(cornerRadius: 1)
                        .fill(.white)
                        .frame(width: 2, height: 10)
                        .offset(x: geo.size.width / 2 - 1, y: -3)
                }
            }
            .frame(height: 10)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let width = UIScreen.main.bounds.width - 40
                        let fraction = Float(g.location.x / width)
                        ev = (fraction * 6 - 3).fxClamped(to: -3...3)
                        cameraManager.setExposureCompensation(ev)
                    }
            )
        }
    }
}
