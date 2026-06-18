import SwiftUI

struct ManualControlsPanel: View {
    @Bindable var cameraManager: CameraManager
    var onDismiss: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            // ── Drag handle ──────────────────────────────────────────────────────
            handle

            // ── EV strip ────────────────────────────────────────────────────────
            EVStrip(cameraManager: cameraManager)
                .padding(.horizontal, 24)
                .padding(.bottom, 16)

            Divider()
                .background(.white.opacity(0.15))
                .padding(.horizontal, 20)

            // ── Sliders ──────────────────────────────────────────────────────────
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ISOSlider(
                        iso: $cameraManager.captureSettings.isoValue,
                        isAuto: $cameraManager.captureSettings.isAutoISO
                    ) { cameraManager.setISO(cameraManager.captureSettings.isoValue) }

                    divider

                    ShutterSlider(
                        shutterSpeed: $cameraManager.captureSettings.shutterSpeed,
                        isAuto: $cameraManager.captureSettings.isAutoShutter
                    ) { cameraManager.setShutterSpeed(cameraManager.captureSettings.shutterSpeed) }

                    divider

                    WhiteBalanceSlider(
                        kelvin: $cameraManager.captureSettings.whiteBalance,
                        isAuto: $cameraManager.captureSettings.isAutoWhiteBalance
                    ) { cameraManager.setWhiteBalance(kelvin: cameraManager.captureSettings.whiteBalance) }

                    if FeatureFlags.focusSlider {
                        divider
                        FocusSlider(
                            lensPosition: $cameraManager.captureSettings.focusDistance,
                            isAuto: $cameraManager.captureSettings.isAutoFocus
                        ) { cameraManager.setFocus(lensPosition: cameraManager.captureSettings.focusDistance) }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 0.5)
        )
        .gesture(
            DragGesture()
                .onEnded { g in if g.translation.height > 60 { onDismiss?() } }
        )
    }

    private var handle: some View {
        RoundedRectangle(cornerRadius: 2.5)
            .fill(.white.opacity(0.3))
            .frame(width: 36, height: 5)
            .padding(.top, 10)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { onDismiss?() }
    }

    private var divider: some View {
        Rectangle()
            .fill(.white.opacity(0.08))
            .frame(width: 1, height: 120)
            .padding(.top, 38) // align with track area
    }
}

// MARK: - EV Strip

/// Reads exposureCompensation directly from cameraManager — single source of truth, no local state.
private struct EVStrip: View {
    @Bindable var cameraManager: CameraManager

    var body: some View {
        let ev = cameraManager.captureSettings.exposureCompensation

        VStack(spacing: 8) {
            // Labels row
            HStack {
                Text("EV")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .tracking(1.5)
                    .textCase(.uppercase)

                Spacer()

                Text(evString(ev))
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(evColor(ev))
                    .frame(minWidth: 48, alignment: .trailing) // fixed width – no layout shift
                    .animation(.none, value: ev)
            }

            // Track
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Background
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.white.opacity(0.12))
                        .frame(height: 6)

                    // Fill bar
                    let fraction = CGFloat((ev + 3) / 6)
                    let center = geo.size.width / 2
                    let barStart = fraction < 0.5 ? fraction * geo.size.width : center
                    let barWidth = max(3, abs(fraction - 0.5) * geo.size.width)

                    RoundedRectangle(cornerRadius: 3)
                        .fill(evColor(ev).opacity(0.85))
                        .frame(width: barWidth, height: 6)
                        .offset(x: barStart)
                        .animation(.easeOut(duration: 0.08), value: ev)

                    // Center tick
                    RoundedRectangle(cornerRadius: 1)
                        .fill(.white.opacity(0.6))
                        .frame(width: 2, height: 14)
                        .offset(x: center - 1, y: -4)
                }
            }
            .frame(height: 14)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        // Use GeometryReader width via the tracked frame — gesture .location is in local coords
                        // We reconstruct via screen width minus padding (48pt each side)
                        let trackWidth = UIScreen.main.bounds.width - 48
                        let fraction = Float((g.location.x / trackWidth).clamped(to: 0...1))
                        let newEV = (fraction * 6 - 3).fxClamped(to: -3...3)
                        cameraManager.setExposureCompensation(newEV)
                    }
            )
        }
    }

    private func evString(_ ev: Float) -> String {
        ev >= 0 ? "+\(String(format: "%.1f", ev))" : String(format: "%.1f", ev)
    }

    private func evColor(_ ev: Float) -> Color {
        if ev > 0.2  { return .orange }
        if ev < -0.2 { return .cyan }
        return .white
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
