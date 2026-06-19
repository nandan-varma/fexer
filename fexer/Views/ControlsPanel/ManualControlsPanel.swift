import SwiftUI

struct ManualControlsPanel: View {
    @Bindable var cameraManager: CameraManager
    var onSettings: (() -> Void)?
    var onDismiss: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            // ── Drag handle ──────────────────────────────────────────────────────
            handle

            // ── WB Preset chips ──────────────────────────────────────────────────
            WBPresetRow(cameraManager: cameraManager)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            // ── EV strip ────────────────────────────────────────────────────────
            EVStrip(cameraManager: cameraManager)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
                .opacity(cameraManager.captureSettings.isAELocked ? 0.38 : 1.0)
                .allowsHitTesting(!cameraManager.captureSettings.isAELocked)

            // ── WB Tint strip (only when WB is in manual mode) ──────────────────
            if !cameraManager.captureSettings.isAutoWhiteBalance {
                TintStrip(cameraManager: cameraManager)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Divider()
                .background(.white.opacity(0.15))
                .padding(.horizontal, 16)

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
            .padding(.horizontal, 16)
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
            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(.white.opacity(0.28))
                    .frame(width: 36, height: 5)
            }
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
                    HStack(spacing: 5) {
                        Image(systemName: cameraManager.captureSettings.meteringMode.systemImage)
                            .font(.system(size: 11, weight: .medium))
                        Text(cameraManager.captureSettings.meteringMode.rawValue.uppercased())
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(0.8)
                    }
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.07), in: Capsule())
                    .frame(height: 36)
                    .contentShape(Rectangle())
                }
                .padding(.leading, 12)

                Spacer()

                // Settings gear — top-right
                Button { onSettings?() } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 36, height: 36)
                        .background(.white.opacity(0.07), in: Circle())
                        .contentShape(Rectangle())
                }
                .padding(.trailing, 12)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var divider: some View {
        Rectangle()
            .fill(.white.opacity(0.08))
            .frame(width: 1, height: 120)
            .padding(.top, 38) // align with track area
    }
}

// MARK: - WB Preset Row

private struct WBPresetRow: View {
    @Bindable var cameraManager: CameraManager

    private var activePreset: WBPreset {
        if cameraManager.captureSettings.isAutoWhiteBalance { return .auto }
        let k = cameraManager.captureSettings.whiteBalance
        let t = cameraManager.captureSettings.whiteBalanceTint
        return WBPreset.allCases.first { preset in
            guard let pk = preset.kelvin else { return false }
            return abs(pk - k) < 200 && abs(preset.tint - t) < 15
        } ?? .daylight
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(WBPreset.allCases) { preset in
                    let isActive = activePreset == preset
                    Button {
                        HapticManager.selectionChanged()
                        if let kelvin = preset.kelvin {
                            cameraManager.captureSettings.isAutoWhiteBalance = false
                            cameraManager.captureSettings.whiteBalance = kelvin
                            cameraManager.captureSettings.whiteBalanceTint = preset.tint
                            cameraManager.setWhiteBalance(kelvin: kelvin, tint: preset.tint)
                        } else {
                            cameraManager.captureSettings.isAutoWhiteBalance = true
                            cameraManager.setAutoWhiteBalance()
                        }
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: preset.systemImage)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(isActive ? .black : .white.opacity(0.75))
                            Text(preset.kelvinLabel)
                                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                                .foregroundStyle(isActive ? .black : .white.opacity(0.5))
                        }
                        .frame(width: 44, height: 36)
                        .background(
                            isActive ? Color.yellow : Color.white.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .animation(.easeInOut(duration: 0.15), value: isActive)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
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
                let trackWidth = geo.size.width
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
                .frame(height: 14)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            guard trackWidth > 0 else { return }
                            let fraction = Float((g.location.x / trackWidth).fxClamped(to: 0...1))
                            let newTint = (fraction * 300 - 150).fxClamped(to: -150...150)
                            cameraManager.captureSettings.whiteBalanceTint = newTint
                            cameraManager.setWhiteBalance(
                                kelvin: cameraManager.captureSettings.whiteBalance,
                                tint: newTint
                            )
                        }
                )
            }
            .frame(height: 14)
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

                if cameraManager.captureSettings.isAELocked {
                    Text("AEL")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.yellow, in: Capsule())
                }

                Spacer()

                Text(evString(ev))
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(evColor(ev))
                    .frame(minWidth: 48, alignment: .trailing)
                    .animation(.none, value: ev)
            }

            // Track
            GeometryReader { geo in
                let trackWidth = geo.size.width
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
                .frame(height: 14)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            guard trackWidth > 0 else { return }
                            let fraction = Float((g.location.x / trackWidth).fxClamped(to: 0...1))
                            let newEV = (fraction * 6 - 3).fxClamped(to: -3...3)
                            cameraManager.setExposureCompensation(newEV)
                        }
                )
            }
            .frame(height: 14)
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


