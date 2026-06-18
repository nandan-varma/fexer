import SwiftUI

struct ManualControlsPanel: View {
    @Bindable var cameraManager: CameraManager
    var onSettings: (() -> Void)?
    var onDismiss: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            // ── Drag handle ──────────────────────────────────────────────────────
            handle

            // ── EV strip ────────────────────────────────────────────────────────
            EVStrip(cameraManager: cameraManager)
                .padding(.horizontal, 24)
                .padding(.bottom, 10)

            // ── WB Tint strip (only when WB is in manual mode) ──────────────────
            if !cameraManager.captureSettings.isAutoWhiteBalance {
                TintStrip(cameraManager: cameraManager)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Divider()
                .background(.white.opacity(0.15))
                .padding(.horizontal, 20)

            // ── Sliders ──────────────────────────────────────────────────────────
            HStack(alignment: .top, spacing: 0) {
                ISOSlider(
                    iso: $cameraManager.captureSettings.isoValue,
                    isAuto: $cameraManager.captureSettings.isAutoISO
                ) { cameraManager.setISO(cameraManager.captureSettings.isoValue) }
                .onChange(of: cameraManager.captureSettings.isAutoISO) { _, isAuto in
                    if isAuto { cameraManager.setAutoExposure() }
                }
                .frame(maxWidth: .infinity)

                divider

                ShutterSlider(
                    shutterSpeed: $cameraManager.captureSettings.shutterSpeed,
                    isAuto: $cameraManager.captureSettings.isAutoShutter
                ) { cameraManager.setShutterSpeed(cameraManager.captureSettings.shutterSpeed) }
                .onChange(of: cameraManager.captureSettings.isAutoShutter) { _, isAuto in
                    if isAuto { cameraManager.setAutoExposure() }
                }
                .frame(maxWidth: .infinity)

                divider

                WhiteBalanceSlider(
                    kelvin: $cameraManager.captureSettings.whiteBalance,
                    isAuto: $cameraManager.captureSettings.isAutoWhiteBalance
                ) { cameraManager.setWhiteBalance(kelvin: cameraManager.captureSettings.whiteBalance,
                                                   tint: cameraManager.captureSettings.whiteBalanceTint) }
                .onChange(of: cameraManager.captureSettings.isAutoWhiteBalance) { _, isAuto in
                    if isAuto { cameraManager.setAutoWhiteBalance() }
                }
                .frame(maxWidth: .infinity)

                if FeatureFlags.focusSlider {
                    divider
                    FocusSlider(
                        lensPosition: $cameraManager.captureSettings.focusDistance,
                        isAuto: $cameraManager.captureSettings.isAutoFocus
                    ) { cameraManager.setFocus(lensPosition: cameraManager.captureSettings.focusDistance) }
                    .onChange(of: cameraManager.captureSettings.isAutoFocus) { _, isAuto in
                        if isAuto { cameraManager.setAutoFocus() }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 20)
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
        ZStack {
            // Center pill — tapping it dismisses the panel
            RoundedRectangle(cornerRadius: 2.5)
                .fill(.white.opacity(0.3))
                .frame(width: 36, height: 5)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { onDismiss?() }

            HStack {
                // Metering mode cycling button — top-left
                Button {
                    let next = cameraManager.captureSettings.meteringMode.next
                    cameraManager.setMeteringMode(next)
                    HapticManager.selectionChanged()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: cameraManager.captureSettings.meteringMode.systemImage)
                            .font(.system(size: 12))
                        Text(cameraManager.captureSettings.meteringMode.rawValue)
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.5)
                    }
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(height: 36)
                    .contentShape(Rectangle())
                }
                .padding(.leading, 14)

                Spacer()

                // Settings gear — top-right
                Button { onSettings?() } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .padding(.trailing, 14)
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    private var divider: some View {
        Rectangle()
            .fill(.white.opacity(0.08))
            .frame(width: 1, height: 120)
            .padding(.top, 38) // align with track area
    }
}

// MARK: - Tint Strip

private struct TintStrip: View {
    @Bindable var cameraManager: CameraManager

    var body: some View {
        let tint = cameraManager.captureSettings.whiteBalanceTint

        VStack(spacing: 6) {
            HStack {
                Text("TINT")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .tracking(1.5)

                Spacer()

                Text(tint >= 0 ? "+\(Int(tint))" : "\(Int(tint))")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(abs(tint) < 5 ? .white : tint > 0 ? Color(red: 0.9, green: 0.3, blue: 0.9) : Color(red: 0.2, green: 0.85, blue: 0.2))
                    .frame(minWidth: 40, alignment: .trailing)
                    .animation(.none, value: tint)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    LinearGradient(
                        colors: [
                            Color(red: 0.1, green: 0.8, blue: 0.1),
                            Color.white.opacity(0.18),
                            Color(red: 0.9, green: 0.2, blue: 0.9)
                        ],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(height: 6)
                    .clipShape(RoundedRectangle(cornerRadius: 3))

                    // Center tick
                    RoundedRectangle(cornerRadius: 1)
                        .fill(.white.opacity(0.5))
                        .frame(width: 2, height: 12)
                        .offset(x: geo.size.width / 2 - 1, y: -3)

                    // Thumb
                    let fraction = CGFloat((tint + 150) / 300)
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.4), radius: 2)
                        .frame(width: 14, height: 14)
                        .offset(x: fraction * geo.size.width - 7, y: -4)
                        .animation(.easeOut(duration: 0.08), value: tint)
                }
            }
            .frame(height: 14)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let trackWidth = UIScreen.main.bounds.width - 48
                        let fraction = Float((g.location.x / trackWidth).clamped(to: 0...1))
                        let newTint = (fraction * 300 - 150).fxClamped(to: -150...150)
                        cameraManager.captureSettings.whiteBalanceTint = newTint
                        cameraManager.setWhiteBalance(
                            kelvin: cameraManager.captureSettings.whiteBalance,
                            tint: newTint
                        )
                    }
            )
        }
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
