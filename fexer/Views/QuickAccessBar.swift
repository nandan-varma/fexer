import SwiftUI
import AVFoundation

struct QuickAccessBar: View {
    @Environment(AppState.self) private var appState
    let cameraManager: CameraManager

    @AppStorage("showGrid")             private var showGrid             = false
    @AppStorage("showHistogram")        private var showHistogram        = true
    @AppStorage("showFocusPeaking")     private var showFocusPeaking     = false
    @AppStorage("showZebra")            private var showZebra            = false
    @AppStorage("showLevelIndicator")   private var showLevelIndicator   = false
    @AppStorage("showFalseColor")       private var showFalseColor       = false
    @AppStorage("isBracketingEnabled")  private var isBracketingEnabled  = false
    @AppStorage("selfTimerDelay")       private var selfTimerDelay: Int  = 0
    @AppStorage("defaultCaptureFormat") private var defaultFormat        = "JPEG"

    var body: some View {
        GeometryReader { geo in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(appState.quickAccessItems) { item in
                        itemButton(for: item)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(minWidth: geo.size.width, alignment: .center)
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
            ZStack(alignment: .topTrailing) {
                Image(systemName: iconName(for: item))
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(active ? Color.yellow : Color.white.opacity(0.6))
                    .contentTransition(.symbolEffect(.replace))
                    .animation(.easeInOut(duration: 0.15), value: active)
                    .frame(width: 44, height: 38)
                    .background(
                        active ? Color.yellow.opacity(0.18) : Color.white.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
                    .animation(.easeInOut(duration: 0.15), value: active)

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
        default:
            return item.systemImageName
        }
    }

    private func isActive(_ item: QuickAccessItem) -> Bool {
        switch item {
        case .flash:          return cameraManager.flashMode != .off
        case .timer:          return selfTimerDelay > 0
        case .grid:           return showGrid
        case .histogram:      return showHistogram
        case .flipCamera:     return false
        case .focusPeaking:   return showFocusPeaking
        case .zebra:          return showZebra
        case .levelIndicator: return showLevelIndicator
        case .livePhoto:      return cameraManager.isLivePhotoEnabled
        case .format:         return defaultFormat != "JPEG"
        case .falseColor:     return showFalseColor
        case .bracketAEB:     return isBracketingEnabled
        case .afMode:         return cameraManager.captureSettings.focusMode == .continuousAutoFocus
        }
    }

    private func badge(for item: QuickAccessItem) -> String? {
        switch item {
        case .flash:   return cameraManager.flashMode == .auto ? "A" : nil
        case .timer:   return selfTimerDelay > 0 ? "\(selfTimerDelay)s" : nil
        case .format:  return defaultFormat != "JPEG" ? defaultFormat : nil
        case .afMode:
            if !cameraManager.captureSettings.isAutoFocus { return "M" }
            return cameraManager.captureSettings.focusMode == .continuousAutoFocus ? "C" : "S"
        default:       return nil
        }
    }

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
            let fmts = ["JPEG", "RAW", "RAW+JPEG"]
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
        }
    }
}
