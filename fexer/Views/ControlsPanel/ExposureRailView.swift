import AVFoundation
import SwiftUI

/// Left and right side-rail badges.
/// ISO·SS·WB·Focus are fixed constants. Everything below is user-customizable via Settings.
struct ExposureRailView: View {
    let cameraManager: CameraManager
    @Bindable var cameraViewModel: CameraViewModel

    @Environment(AppState.self) private var appState
    @AppStorage("isHDREnabled")    private var isHDREnabled: Bool = false
    @AppStorage("selfTimerDelay")  private var selfTimerDelay: Int = 0

    private var isLandscape: Bool { abs(DeviceOrientationTracker.shared.rotationAngle) > 45 }
    // ponytail: fixed spacing avoids layout recalc; 24pt gives ~10pt visual gap after rotation overlap
    private var railSpacing: CGFloat { isLandscape ? 24 : 10 }

    var body: some View {
        ZStack {
            // Left rail: ISO + Shutter + customizable
            VStack(spacing: railSpacing) {
                RailBadge(
                    label: "ISO",
                    value: isoString,
                    isManual: !cameraManager.captureSettings.isAutoISO,
                    isActive: cameraViewModel.activeRailParam == .iso
                ) {
                    cameraViewModel.activeRailParam = cameraViewModel.activeRailParam == .iso ? nil : .iso
                    HapticManager.light()
                }
                RailBadge(
                    label: "SS",
                    value: shutterString,
                    isManual: !cameraManager.captureSettings.isAutoShutter,
                    isActive: cameraViewModel.activeRailParam == .shutter
                ) {
                    cameraViewModel.activeRailParam = cameraViewModel.activeRailParam == .shutter ? nil : .shutter
                    HapticManager.light()
                }
                ForEach(appState.leftRailItems) { railBadge(for: $0) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.leading, 6)
            .padding(.bottom, 220)

            // Right rail: WB + Focus + customizable
            VStack(spacing: railSpacing) {
                RailBadge(
                    label: "WB",
                    value: wbString,
                    isManual: !cameraManager.captureSettings.isAutoWhiteBalance,
                    isActive: cameraViewModel.activeRailParam == .wb
                ) {
                    cameraViewModel.activeRailParam = cameraViewModel.activeRailParam == .wb ? nil : .wb
                    HapticManager.light()
                }
                if cameraManager.supportsManualFocus {
                    RailBadge(
                        label: "MF",
                        value: focusString,
                        isManual: !cameraManager.captureSettings.isAutoFocus,
                        isActive: cameraViewModel.activeRailParam == .focus
                    ) {
                        cameraViewModel.activeRailParam = cameraViewModel.activeRailParam == .focus ? nil : .focus
                        HapticManager.light()
                    }
                }
                ForEach(appState.rightRailItems) { railBadge(for: $0) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .padding(.trailing, 6)
            .padding(.bottom, 220)
        }
    }

    // MARK: - Fixed badge strings

    private var isoString: String {
        cameraManager.captureSettings.isAutoISO ? "AUTO" : "\(Int(cameraManager.captureSettings.isoValue))"
    }

    private var shutterString: String {
        cameraManager.captureSettings.isAutoShutter ? "AUTO" : cameraManager.captureSettings.shutterSpeedDisplayString
    }

    private var wbString: String {
        cameraManager.captureSettings.isAutoWhiteBalance
            ? "AUTO"
            : "\(Int(cameraManager.captureSettings.whiteBalance))K"
    }

    private var focusString: String {
        cameraManager.captureSettings.isAutoFocus
            ? "AUTO"
            : String(format: "%.2f", cameraManager.captureSettings.focusDistance)
    }

    // MARK: - Dynamic badge factory

    @ViewBuilder
    private func railBadge(for item: SideRailItem) -> some View {
        switch item {
        case .flash:
            RailBadge(
                label: "FL",
                value: flashString,
                isManual: cameraManager.flashMode != .off,
                isActive: false
            ) {
                switch cameraManager.flashMode {
                case .off:        cameraManager.flashMode = .on
                case .on:         cameraManager.flashMode = .auto
                case .auto:       cameraManager.flashMode = .off
                @unknown default: cameraManager.flashMode = .off
                }
                HapticManager.selectionChanged()
            }
        case .metering:
            RailBadge(
                label: "MTR",
                value: meteringString,
                isManual: cameraManager.captureSettings.meteringMode != .matrix,
                isActive: false
            ) {
                cameraManager.setMeteringMode(cameraManager.captureSettings.meteringMode.next)
                HapticManager.selectionChanged()
            }
        case .hdr:
            RailBadge(label: "HDR", value: isHDREnabled ? "ON" : "OFF", isManual: isHDREnabled, isActive: false) {
                isHDREnabled.toggle()
                cameraManager.setHDREnabled(isHDREnabled)
                HapticManager.selectionChanged()
            }
        case .torch:
            RailBadge(
                label: "TRH",
                value: cameraManager.captureSettings.isTorchOn ? "ON" : "OFF",
                isManual: cameraManager.captureSettings.isTorchOn,
                isActive: false
            ) {
                let on = !cameraManager.captureSettings.isTorchOn
                cameraManager.setTorch(on: on, level: cameraManager.captureSettings.torchLevel)
                HapticManager.selectionChanged()
            }
        case .timer:
            RailBadge(
                label: "TMR",
                value: selfTimerDelay > 0 ? "\(selfTimerDelay)s" : "OFF",
                isManual: selfTimerDelay > 0,
                isActive: false
            ) {
                let steps = [0, 3, 5, 10]
                selfTimerDelay = steps.first(where: { $0 > selfTimerDelay }) ?? 0
                HapticManager.selectionChanged()
            }
        }
    }

    private var flashString: String {
        switch cameraManager.flashMode {
        case .off:        return "OFF"
        case .on:         return "ON"
        case .auto:       return "AUTO"
        @unknown default: return "OFF"
        }
    }

    private var meteringString: String {
        switch cameraManager.captureSettings.meteringMode {
        case .matrix:            return "MTRX"
        case .center:            return "CNTR"
        case .spot:              return "SPOT"
        case .highlightWeighted: return "HLGT"
        }
    }
}

private struct RailBadge: View {
    let label: String
    let value: String
    let isManual: Bool
    let isActive: Bool
    let onTap: () -> Void

    private var angle: Double { DeviceOrientationTracker.shared.rotationAngle }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 2) {
                Text(label)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(isManual ? Color.yellow.opacity(0.8) : Color.white.opacity(0.45))
                    .tracking(0.5)
                Text(value)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(isManual ? Color.yellow : Color.white.opacity(0.7))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .frame(minWidth: 44)
            .background(badgeBackground, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isActive ? Color.yellow.opacity(0.5) : Color.white.opacity(0.1), lineWidth: 0.5)
            )
            .rotationEffect(.degrees(angle))
            .animation(.spring(response: 0.35, dampingFraction: 0.75), value: angle)
        }
        .buttonStyle(.plain)
    }

    private var badgeBackground: Color {
        if isActive { return Color.yellow.opacity(0.18) }
        if isManual { return Color.white.opacity(0.08) }
        return Color.black.opacity(0.35)
    }
}
