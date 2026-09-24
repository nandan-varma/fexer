import AVFoundation
import SwiftUI

/// Shallow "big wheel" jog dial — appears in the bottom letterbox bezel, opposite the
/// top-bezel chip that opened it. The wheel's implied radius is far larger than the visible
/// strip (see `virtualTrackWidth`): ticks scroll beneath a fixed center pointer, so a full
/// screen-width drag covers only a fraction of the value range — more travel per stop than a
/// linear slider, which is what makes fine adjustment easy.
struct DialWheelView: View {
    let param: CameraViewModel.RailParam
    let cameraManager: CameraManager
    var onDismiss: () -> Void

    @State private var autoDismissTask: Task<Void, Never>?
    @State private var dragAnchorNormalized: CGFloat = 0
    @State private var lastDetentIndex: Int?
    /// Raw (unquantized) drag position, updated every touch move — drives the ruler's scroll
    /// so it tracks the finger continuously. `nil` when not dragging: falls back to the real
    /// applied value (which IS quantized for ISO/shutter — coarse stops, not every pixel).
    @State private var liveNormalized: CGFloat?

    /// Full 0...1 sweep takes this many points of drag — the "radius" of the wheel.
    private let virtualTrackWidth: CGFloat = 1400
    private let tickSpacing: CGFloat = 22

    private var angle: Double { DeviceOrientationTracker.shared.rotationAngle }

    var body: some View {
        // The knob itself is a fixed physical object on the black bezel — it does not
        // rotate with the device. Only the readout text and toggle letter counter-rotate
        // (each independently, like RailBadge) so they stay legible in landscape. Header +
        // toggle share one row (rather than stacking three rows) to keep the whole widget
        // shallow enough to fit inside a typical bezel without spilling onto the image.
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(paramLabel)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                        .tracking(1.2)
                        .shadow(color: .black.opacity(0.8), radius: 2, y: 1)
                    HStack(spacing: 5) {
                        Text(currentValueString)
                            .font(.system(size: 18, weight: .bold, design: .monospaced))
                            .foregroundStyle(isAuto ? .white.opacity(0.65) : .yellow)
                        Image(systemName: "arrowtriangle.down.fill")
                            .font(.system(size: 7))
                            .foregroundStyle(isAuto ? .white.opacity(0.65) : .yellow)
                    }
                    .shadow(color: .black.opacity(0.8), radius: 3, y: 1)
                }
                .rotationEffect(.degrees(angle))
                .animation(.spring(response: 0.35, dampingFraction: 0.75), value: angle)

                Spacer(minLength: 0)

                Button {
                    toggleAuto()
                    resetAutoDismiss()
                    HapticManager.selectionChanged()
                } label: {
                    Text(isAuto ? "A" : "M")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(isAuto ? .black : .white)
                        .frame(width: 26, height: 22)
                        .background(isAuto ? Color.yellow : Color.white.opacity(0.18), in: Capsule())
                        .rotationEffect(.degrees(angle))
                        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: angle)
                }
                .buttonStyle(.plain)
            }

            tickRuler
                .frame(height: 26)
                .frame(maxWidth: .infinity)
                .clipped()
                .contentShape(Rectangle())
                .gesture(dragGesture)
        }
        .padding(.horizontal, 16)
        .frame(width: 320)
        .onAppear { resetAutoDismiss() }
        .onDisappear { autoDismissTask?.cancel() }
    }

    // MARK: - Tick ruler (Canvas — cheap, no per-tick view identity)

    private var tickRuler: some View {
        Canvas { context, size in
            let centerX = size.width / 2
            let total = totalDetents
            let scrollPos = (liveNormalized ?? normalizedPosition) * CGFloat(total) * tickSpacing

            for i in 0...total {
                let tickX = CGFloat(i) * tickSpacing
                let x = centerX + (tickX - scrollPos)
                guard x > -2, x < size.width + 2 else { continue }
                let isMajor = i % 5 == 0
                let h: CGFloat = isMajor ? 16 : 8
                var path = Path()
                path.move(to: CGPoint(x: x, y: size.height - h))
                path.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(
                    path,
                    with: .color(.white.opacity(isMajor ? 0.55 : 0.22)),
                    lineWidth: isMajor ? 1.5 : 1
                )
            }

            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: size.height))
            baseline.addLine(to: CGPoint(x: size.width, y: size.height))
            context.stroke(baseline, with: .color(.white.opacity(0.15)), lineWidth: 1)

            var pointer = Path()
            pointer.move(to: CGPoint(x: centerX, y: size.height - 20))
            pointer.addLine(to: CGPoint(x: centerX, y: size.height))
            context.stroke(pointer, with: .color(.yellow), lineWidth: 2)
        }
    }

    // MARK: - Drag → value

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if value.translation == .zero {
                    dragAnchorNormalized = normalizedPosition
                    lastDetentIndex = detentIndex(for: normalizedPosition)
                }
                // Content follows the finger 1:1 (drag left reveals higher values, like
                // swiping to the next item in a carousel) — dividing by virtualTrackWidth
                // is what makes the wheel's effective radius large, i.e. precise.
                let delta = -value.translation.width / virtualTrackWidth
                let newNorm = (dragAnchorNormalized + delta).fxClamped(to: 0...1)
                liveNormalized = newNorm
                applyNormalized(newNorm)

                let detent = detentIndex(for: newNorm)
                if detent != lastDetentIndex {
                    lastDetentIndex = detent
                    HapticManager.dialDetent(major: detent % 5 == 0)
                }
                resetAutoDismiss()
            }
            .onEnded { _ in
                liveNormalized = nil
            }
    }

    /// Number of visual/haptic detents across the full 0...1 range for this parameter.
    private var totalDetents: Int {
        switch param {
        case .iso:     return CaptureSettings.isoStops.count - 1
        case .shutter: return CaptureSettings.shutterStops.count - 1
        case .wb:      return 60
        case .focus:   return 50
        }
    }

    private func detentIndex(for norm: CGFloat) -> Int {
        Int((norm * CGFloat(totalDetents)).rounded())
    }

    // MARK: - Parameter info (mirrors the values shown on the top-bezel chip)

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
