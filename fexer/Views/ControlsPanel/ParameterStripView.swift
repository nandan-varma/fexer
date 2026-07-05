import AVFoundation
import SwiftUI

/// Compact horizontal strip for adjusting a single camera parameter.
/// 280 × ~90 pt; positioned above the bottom control area.
struct ParameterStripView: View {
    let param: CameraViewModel.RailParam
    let cameraManager: CameraManager
    var onDismiss: () -> Void

    @State private var autoDismissTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 8) {
            // Header: label + live value + auto/manual toggle
            HStack(spacing: 6) {
                Text(paramLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .tracking(0.8)
                Text(currentValueString)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    toggleAuto()
                    resetAutoDismiss()
                    HapticManager.selectionChanged()
                } label: {
                    Text(isAuto ? "A" : "M")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(isAuto ? .black : .white)
                        .frame(width: 28, height: 22)
                        .background(isAuto ? Color.yellow : Color.white.opacity(0.18), in: Capsule())
                }
                .buttonStyle(.plain)
            }

            // Scrub track
            GeometryReader { geo in
                let thumbX = (normalizedPosition * geo.size.width).fxClamped(to: 0...geo.size.width)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.12))
                        .frame(height: 5)
                    if !isAuto {
                        Capsule()
                            .fill(Color.yellow.opacity(0.7))
                            .frame(width: thumbX, height: 5)
                    }
                    Circle()
                        .fill(isAuto ? Color.white.opacity(0.35) : Color.white)
                        .frame(width: 14, height: 14)
                        .offset(x: thumbX - 7)
                }
                // Enlarge hit area vertically
                .contentShape(Rectangle().inset(by: -10))
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let norm = (value.location.x / geo.size.width).fxClamped(to: 0...1)
                            applyNormalized(norm)
                            resetAutoDismiss()
                        }
                )
                .disabled(isAuto)
                .opacity(isAuto ? 0.45 : 1)
            }
            .frame(height: 14)

            // Step labels
            HStack(spacing: 0) {
                ForEach(Array(stepLabels.enumerated()), id: \.offset) { i, label in
                    if i > 0 { Spacer(minLength: 0) }
                    Text(label)
                        .font(.system(size: 8))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 280)
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.12), lineWidth: 0.5))
        .rotationEffect(.degrees(DeviceOrientationTracker.shared.rotationAngle))
        .animation(.spring(response: 0.35, dampingFraction: 0.75),
                   value: DeviceOrientationTracker.shared.rotationAngle)
        .onAppear { resetAutoDismiss() }
        .onDisappear { autoDismissTask?.cancel() }
    }

    // MARK: - Parameter info

    private var paramLabel: String {
        switch param {
        case .iso:     return "ISO"
        case .shutter: return "SHUTTER"
        case .wb:      return "WHITE BALANCE"
        case .focus:   return "FOCUS"
        }
    }

    private var isAuto: Bool {
        switch param {
        case .iso:     return cameraManager.captureSettings.isAutoISO
        case .shutter: return cameraManager.captureSettings.isAutoShutter
        case .wb:      return cameraManager.captureSettings.isAutoWhiteBalance
        case .focus:   return cameraManager.captureSettings.isAutoFocus
        }
    }

    private var currentValueString: String {
        switch param {
        case .iso:
            return cameraManager.captureSettings.isAutoISO
                ? "AUTO"
                : "ISO \(Int(cameraManager.captureSettings.isoValue))"
        case .shutter:
            return cameraManager.captureSettings.isAutoShutter
                ? "AUTO"
                : cameraManager.captureSettings.shutterSpeedDisplayString
        case .wb:
            return cameraManager.captureSettings.isAutoWhiteBalance
                ? "AUTO"
                : "\(Int(cameraManager.captureSettings.whiteBalance))K"
        case .focus:
            return cameraManager.captureSettings.isAutoFocus
                ? "AUTO"
                : String(format: "%.2f", cameraManager.captureSettings.focusDistance)
        }
    }

    private var normalizedPosition: CGFloat {
        switch param {
        case .iso:
            let stops = CaptureSettings.isoStops.map { CGFloat($0) }
            let val = CGFloat(cameraManager.captureSettings.isoValue)
            guard let idx = stops.firstIndex(where: { $0 >= val }) else { return 1 }
            return CGFloat(idx) / CGFloat(stops.count - 1)
        case .shutter:
            let stops = CaptureSettings.shutterStops
            let val = cameraManager.captureSettings.shutterSpeed
            let idx = stops.firstIndex(where: { CMTimeCompare($0, val) >= 0 }) ?? stops.count - 1
            return CGFloat(idx) / CGFloat(stops.count - 1)
        case .wb:
            return CGFloat((cameraManager.captureSettings.whiteBalance - 2000) / 6000)
                .fxClamped(to: 0...1)
        case .focus:
            return CGFloat(cameraManager.captureSettings.focusDistance).fxClamped(to: 0...1)
        }
    }

    private var stepLabels: [String] {
        switch param {
        case .iso:     return ["25", "100", "400", "1600", "6400"]
        case .shutter: return ["1/8000", "1/250", "1/30", "1\"", "30\""]
        case .wb:      return ["2K", "3K", "5.6K", "6.5K", "8K"]
        case .focus:   return ["NEAR", "", "", "", "∞"]
        }
    }

    // MARK: - Actions

    private func applyNormalized(_ norm: CGFloat) {
        switch param {
        case .iso:
            let stops = CaptureSettings.isoStops
            let idx = Int((norm * CGFloat(stops.count - 1)).rounded())
                .fxClamped(to: 0...stops.count - 1)
            let iso = stops[idx]
            cameraManager.captureSettings.isAutoISO = false
            cameraManager.captureSettings.isAutoShutter = false
            cameraManager.captureSettings.isoValue = iso
            cameraManager.setISO(iso)
        case .shutter:
            let stops = CaptureSettings.shutterStops
            let idx = Int((norm * CGFloat(stops.count - 1)).rounded())
                .fxClamped(to: 0...stops.count - 1)
            let speed = stops[idx]
            cameraManager.captureSettings.isAutoISO = false
            cameraManager.captureSettings.isAutoShutter = false
            cameraManager.captureSettings.shutterSpeed = speed
            cameraManager.setShutterSpeed(speed)
        case .wb:
            let kelvin = Float(2000 + norm * 6000)
            cameraManager.captureSettings.isAutoWhiteBalance = false
            cameraManager.captureSettings.whiteBalance = kelvin
            cameraManager.setWhiteBalance(kelvin: kelvin,
                                          tint: cameraManager.captureSettings.whiteBalanceTint)
        case .focus:
            let pos = Float(norm)
            cameraManager.captureSettings.isAutoFocus = false
            cameraManager.captureSettings.focusDistance = pos
            cameraManager.setFocus(lensPosition: pos)
        }
    }

    private func toggleAuto() {
        switch param {
        case .iso, .shutter:
            if cameraManager.captureSettings.isAutoISO && cameraManager.captureSettings.isAutoShutter {
                // Auto → manual: freeze current hardware values
                cameraManager.captureSettings.isAutoISO = false
                cameraManager.captureSettings.isAutoShutter = false
                cameraManager.setISO(cameraManager.captureSettings.isoValue)
            } else {
                cameraManager.captureSettings.isAutoISO = true
                cameraManager.captureSettings.isAutoShutter = true
                cameraManager.setAutoExposure()
            }
        case .wb:
            if cameraManager.captureSettings.isAutoWhiteBalance {
                cameraManager.captureSettings.isAutoWhiteBalance = false
                cameraManager.setWhiteBalance(kelvin: cameraManager.captureSettings.whiteBalance,
                                              tint: cameraManager.captureSettings.whiteBalanceTint)
            } else {
                cameraManager.captureSettings.isAutoWhiteBalance = true
                cameraManager.setAutoWhiteBalance()
            }
        case .focus:
            if cameraManager.captureSettings.isAutoFocus {
                cameraManager.captureSettings.isAutoFocus = false
                cameraManager.setFocusMode(.locked)
            } else {
                cameraManager.captureSettings.isAutoFocus = true
                cameraManager.setAutoFocus()
            }
        }
    }

    private func resetAutoDismiss() {
        autoDismissTask?.cancel()
        autoDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { onDismiss() }
        }
    }
}
