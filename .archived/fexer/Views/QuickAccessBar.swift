import AVFoundation
import SwiftUI

struct QuickAccessBar: View {
    @Environment(AppState.self) private var appState
    let cameraManager: CameraManager
    var onShowPresets: (() -> Void)?
    var onShowSettings: (() -> Void)?

    @AppStorage("showGrid")             private var showGrid             = false
    @AppStorage("showHistogram")        private var showHistogram        = true
    @AppStorage("showFocusPeaking")     private var showFocusPeaking     = false
    @AppStorage("showZebra")            private var showZebra            = false
    @AppStorage("showLevelIndicator")   private var showLevelIndicator   = false
    @AppStorage("showFalseColor")       private var showFalseColor       = false
    @AppStorage("isBracketingEnabled")  private var isBracketingEnabled  = false
    @AppStorage("selfTimerDelay")       private var selfTimerDelay: Int  = 0
    @AppStorage("defaultCaptureFormat") private var defaultFormat        = "HEIF"
    @AppStorage("isWBBracketEnabled")   private var isWBBracketEnabled   = false
    @AppStorage("showWaveform")         private var showWaveform         = false
    @AppStorage("showVectorscope")      private var showVectorscope      = false
    @AppStorage("isCleanViewActive")    private var isCleanViewActive    = false
    @AppStorage("isHDREnabled")         private var isHDREnabled         = false

    private var rotationAngle: Double { DeviceOrientationTracker.shared.rotationAngle }
    private var rotationAnimation: Animation { .spring(response: 0.35, dampingFraction: 0.75) }

    var body: some View {
        GeometryReader { geo in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    // Fixed settings button — always first, not removable
                    Button { onShowSettings?() } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.6))
                            .rotationEffect(.degrees(rotationAngle))
                            .animation(rotationAnimation, value: rotationAngle)
                            .frame(width: 44, height: 38)
                            .background(Color.white.opacity(0.06),
                                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    // Divider between fixed and scrollable sections
                    Rectangle()
                        .fill(.white.opacity(0.12))
                        .frame(width: 0.5, height: 24)
                        .padding(.horizontal, 2)

                    ForEach(appState.quickAccessItems) { item in
                        itemButton(for: item)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(minWidth: geo.size.width, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(.ultraThinMaterial.opacity(0.85))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(.white.opacity(0.06))
                    .frame(height: 0.5)
            }
        }
        .frame(height: 50)
    }

    @ViewBuilder
    private func itemButton(for item: QuickAccessItem) -> some View {
        let active = isActive(item)
        let bdg = badge(for: item)

        Button { handleTap(item) } label: {
            // Icon + badge rotate together; frame on the Image gives ZStack a defined
            // 44×38 coordinate space so .topTrailing anchors the badge correctly.
            ZStack(alignment: .topTrailing) {
                Image(systemName: iconName(for: item))
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(active ? Color.yellow : Color.white.opacity(0.6))
                    .contentTransition(.symbolEffect(.replace))
                    .animation(.easeInOut(duration: 0.15), value: active)
                    .frame(width: 44, height: 38)

                if let bdg {
                    Text(bdg)
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 2)
                        .background(.yellow, in: Capsule())
                        .offset(x: 5, y: -4)
                }
            }
            .rotationEffect(.degrees(rotationAngle))
            .animation(rotationAnimation, value: rotationAngle)
            .background(
                active ? Color.yellow.opacity(0.18) : Color.white.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .animation(.easeInOut(duration: 0.15), value: active)
        }
        .buttonStyle(.plain)
    }

    private func iconName(for item: QuickAccessItem) -> String {
        switch item {
        case .flash:
            switch cameraManager.flashMode {
            case .off:              return "bolt.slash"
            case .on:               return "bolt.fill"
            case .auto:             return "bolt.badge.automatic"
            @unknown default:       return "bolt.slash"
            }
        case .torch:
            return cameraManager.captureSettings.isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill"
        case .metering:
            return cameraManager.captureSettings.meteringMode.systemImage
        case .hdr:
            return "rays"
        default:
            return item.systemImageName
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    private func isActive(_ item: QuickAccessItem) -> Bool {
        switch item {
        case .flash:           return cameraManager.flashMode != .off
        case .torch:           return cameraManager.captureSettings.isTorchOn
        case .timer:           return selfTimerDelay > 0
        case .grid:            return showGrid
        case .histogram:       return showHistogram
        case .flipCamera:      return false
        case .focusPeaking:    return showFocusPeaking
        case .zebra:           return showZebra
        case .levelIndicator:  return showLevelIndicator
        case .livePhoto:       return cameraManager.isLivePhotoEnabled
        case .format:          return defaultFormat != "HEIF"
        case .falseColor:      return showFalseColor
        case .bracketAEB:      return isBracketingEnabled
        case .afMode:          return cameraManager.captureSettings.focusMode == .continuousAutoFocus
        case .wbBracket:       return isWBBracketEnabled
        case .waveform:        return showWaveform
        case .vectorscope:     return showVectorscope
        case .cleanView:       return isCleanViewActive
        case .opticalZoomLock: return cameraManager.captureSettings.isOpticalZoomLocked
        case .trapFocus:       return cameraManager.captureSettings.isTrapFocusEnabled
        case .presets:         return false
        case .hdr:             return isHDREnabled
        case .metering:        return cameraManager.captureSettings.meteringMode != .matrix
        }
    }

    private func badge(for item: QuickAccessItem) -> String? {
        switch item {
        case .flash:     return cameraManager.flashMode == .auto ? "A" : nil
        case .timer:     return selfTimerDelay > 0 ? "\(selfTimerDelay)s" : nil
        case .format:    return formatBadge
        case .afMode:
            if !cameraManager.captureSettings.isAutoFocus { return "M" }
            return cameraManager.captureSettings.focusMode == .continuousAutoFocus ? "C" : "S"
        case .wbBracket:       return isWBBracketEnabled ? "WB" : nil
        case .opticalZoomLock: return cameraManager.captureSettings.isOpticalZoomLocked ? "OPT" : nil
        case .metering:        return meteringBadge
        case .hdr:             return isHDREnabled ? "HDR" : nil
        default:               return nil
        }
    }

    private var formatBadge: String? {
        switch defaultFormat {
        case "HEIF":      return nil        // default — no badge needed
        case "JPEG":      return "JPG"
        case "RAW":       return "RAW"
        case "RAW+JPEG":  return "R+J"
        default:          return defaultFormat
        }
    }

    private var meteringBadge: String? {
        switch cameraManager.captureSettings.meteringMode {
        case .matrix:            return nil
        case .center:            return "CTR"
        case .spot:              return "SPT"
        case .highlightWeighted: return "HLT"
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    private func handleTap(_ item: QuickAccessItem) {
        switch item {
        case .flash:
            HapticManager.light()
            switch cameraManager.flashMode {
            case .off:        cameraManager.flashMode = .on
            case .on:         cameraManager.flashMode = .auto
            case .auto:       cameraManager.flashMode = .off
            @unknown default: cameraManager.flashMode = .off
            }
        case .torch:
            HapticManager.light()
            let newState = !cameraManager.captureSettings.isTorchOn
            cameraManager.setTorch(on: newState, level: cameraManager.captureSettings.torchLevel)
        case .timer:
            HapticManager.light()
            let steps = [0, 2, 5, 10]
            let idx = steps.firstIndex(of: selfTimerDelay) ?? 0
            selfTimerDelay = steps[(idx + 1) % steps.count]
        case .grid:
            HapticManager.light()
            showGrid.toggle()
        case .histogram:
            HapticManager.light()
            showHistogram.toggle()
        case .flipCamera:
            cameraManager.flipCamera()
            HapticManager.medium()
        case .focusPeaking:
            HapticManager.light()
            showFocusPeaking.toggle()
        case .zebra:
            HapticManager.light()
            showZebra.toggle()
        case .levelIndicator:
            HapticManager.light()
            showLevelIndicator.toggle()
        case .livePhoto:
            HapticManager.light()
            cameraManager.toggleLivePhoto()
        case .format:
            HapticManager.light()
            let fmts = ["HEIF", "JPEG", "RAW", "RAW+JPEG"]
            let idx = fmts.firstIndex(of: defaultFormat) ?? 0
            defaultFormat = fmts[(idx + 1) % fmts.count]
        case .falseColor:
            HapticManager.light()
            showFalseColor.toggle()
        case .bracketAEB:
            HapticManager.light()
            isBracketingEnabled.toggle()
        case .afMode:
            HapticManager.light()
            let next: AVCaptureDevice.FocusMode = cameraManager.captureSettings.focusMode == .continuousAutoFocus
                ? .autoFocus
                : .continuousAutoFocus
            cameraManager.setFocusMode(next)
        case .wbBracket:
            HapticManager.light()
            isWBBracketEnabled.toggle()
        case .waveform:
            HapticManager.light()
            showWaveform.toggle()
        case .vectorscope:
            HapticManager.light()
            showVectorscope.toggle()
        case .cleanView:
            HapticManager.light()
            isCleanViewActive.toggle()
        case .opticalZoomLock:
            HapticManager.light()
            cameraManager.captureSettings.isOpticalZoomLocked.toggle()
        case .trapFocus:
            HapticManager.light()
            cameraManager.captureSettings.isTrapFocusEnabled.toggle()
        case .presets:
            HapticManager.light()
            onShowPresets?()
        case .hdr:
            HapticManager.light()
            isHDREnabled.toggle()
            cameraManager.setHDREnabled(isHDREnabled)
        case .metering:
            HapticManager.light()
            cameraManager.setMeteringMode(cameraManager.captureSettings.meteringMode.next)
        }
    }
}
