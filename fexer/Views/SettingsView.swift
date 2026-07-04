import AVFoundation
import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) var appState
    @Bindable var cameraManager: CameraManager
    @Bindable var stylesManager: StylesManager

    var body: some View {
        NavigationStack {
            Form {
                CameraSection(cameraManager: cameraManager)
                CamerasInfoSection(cameraManager: cameraManager)
                CaptureSection()
                VideoSection(cameraManager: cameraManager)
                ViewfinderSection()
                AnalysisSection()
                StylesSection(stylesManager: stylesManager)
                InterfaceSection()
                QuickAccessSection(appState: appState)
                WatermarkSection()
                AboutSection()
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .preferredColorScheme(.dark)
            .toolbar { EditButton() }
        }
    }
}

// MARK: - Camera

private struct CameraSection: View {
    @Bindable var cameraManager: CameraManager
    @AppStorage("defaultCaptureFormat")  private var defaultFormat      = "HEIF"
    @AppStorage("isProRAWEnabled")       private var isProRAW           = false
    @AppStorage("isLocationEnabled")     private var isLocationEnabled  = true
    @AppStorage("isOpticalZoomLocked")   private var isOpticalZoomLocked = false

    var body: some View {
        Section {
            Picker(selection: $defaultFormat) {
                ForEach(["HEIF", "JPEG", "RAW", "RAW+JPEG"], id: \.self) { Text($0) }
            } label: {
                Label("Format", systemImage: "camera.aperture")
            }

            Toggle(isOn: $isProRAW) {
                Label("ProRAW", systemImage: "sparkles")
            }
            .disabled(!cameraManager.isProRAWSupported)

            Toggle(isOn: $isOpticalZoomLocked) {
                Label("Lock to Optical Zoom", systemImage: "lock.circle")
            }

            Toggle(isOn: $isLocationEnabled) {
                Label("Save Location", systemImage: "location.fill")
            }
        } header: {
            Text("Camera")
        } footer: {
            if !cameraManager.isProRAWSupported {
                Text("ProRAW requires iPhone 12 Pro or later. Lock to Optical Zoom snaps zoom to native focal lengths only.")
            } else {
                Text("Lock to Optical Zoom snaps zoom to native focal lengths only. Location is embedded in EXIF metadata.")
            }
        }
    }
}

// MARK: - Cameras Info

private struct CamerasInfoSection: View {
    @Bindable var cameraManager: CameraManager

    private func positionLabel(_ position: AVCaptureDevice.Position) -> String {
        switch position {
        case .back:  return "Back"
        case .front: return "Front"
        default:     return "External"
        }
    }

    private func cameraLabel(_ device: AVCaptureDevice) -> String {
        switch device.deviceType {
        case .builtInWideAngleCamera:    return "\(positionLabel(device.position)) Wide"
        case .builtInUltraWideCamera:    return "\(positionLabel(device.position)) Ultra Wide"
        case .builtInTelephotoCamera:    return "\(positionLabel(device.position)) Telephoto"
        case .builtInTrueDepthCamera:    return "Front (TrueDepth)"
        case .builtInLiDARDepthCamera:   return "Back LiDAR"
        default:                         return device.localizedName
        }
    }

    var body: some View {
        if !cameraManager.discoveredCameras.isEmpty {
            Section {
                ForEach(cameraManager.discoveredCameras, id: \.uniqueID) { camera in
                    let maxFPS = CameraManager.maxSupportedFPS(for: camera)
                    HStack {
                        Text(cameraLabel(camera))
                        Spacer()
                        Text("max \(maxFPS) fps")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
            } header: {
                Text("Available Cameras")
            }
        }
    }
}

// MARK: - Capture

private struct CaptureSection: View {
    @AppStorage("volumeButtonBehavior") private var volumeButtonBehavior = "Shutter"
    @AppStorage("selfTimerDelay")       private var selfTimerDelay: Int   = 0
    @AppStorage("selfTimerRepeat")      private var selfTimerRepeat: Int  = 1
    @AppStorage("isBracketingEnabled")  private var isBracketingEnabled  = false
    @AppStorage("bracketEVStep")        private var bracketEVStep: Double = 1.0
    @AppStorage("isWBBracketEnabled")   private var isWBBracketEnabled   = false
    @AppStorage("wbBracketKStep")       private var wbBracketKStep: Double = 500.0
    @AppStorage("burstCount")           private var burstCount: Int       = 10
    @AppStorage("isTrapFocusEnabled")   private var isTrapFocusEnabled   = false
    @AppStorage("showReviewAfterShot")  private var showReviewAfterShot  = false

    var body: some View {
        Section("Capture") {
            Picker(selection: $volumeButtonBehavior) {
                ForEach(["Shutter", "Zoom", "Disabled"], id: \.self) { Text($0) }
            } label: {
                Label("Volume Button", systemImage: "button.programmable")
            }

            Picker(selection: $selfTimerDelay) {
                Text("Off").tag(0)
                Text("2 s").tag(2)
                Text("5 s").tag(5)
                Text("10 s").tag(10)
            } label: {
                Label("Self-Timer", systemImage: "timer")
            }
            .pickerStyle(.menu)

            if selfTimerDelay > 0 {
                Picker(selection: $selfTimerRepeat) {
                    Text("1×").tag(1)
                    Text("3×").tag(3)
                    Text("5×").tag(5)
                    Text("10×").tag(10)
                    Text("∞").tag(0)
                } label: {
                    Label("Timer Repeats", systemImage: "repeat")
                }
                .pickerStyle(.menu)
            }

            Toggle(isOn: $isBracketingEnabled) {
                Label("Auto Exposure Bracketing", systemImage: "plusminus")
            }

            if isBracketingEnabled {
                Picker(selection: $bracketEVStep) {
                    Text("±⅓ EV").tag(0.333)
                    Text("±⅔ EV").tag(0.667)
                    Text("±1 EV").tag(1.0)
                    Text("±2 EV").tag(2.0)
                } label: {
                    Label("Bracket Step", systemImage: "plusminus.circle")
                }
                .pickerStyle(.menu)
            }

            Toggle(isOn: $isWBBracketEnabled) {
                Label("White Balance Bracketing", systemImage: "thermometer.medium")
            }

            if isWBBracketEnabled {
                Picker(selection: $wbBracketKStep) {
                    Text("±250 K").tag(250.0)
                    Text("±500 K").tag(500.0)
                    Text("±1000 K").tag(1000.0)
                } label: {
                    Label("WB Step", systemImage: "thermometer.variable")
                }
                .pickerStyle(.menu)
            }

            Stepper("Burst Frames: \(burstCount)",
                    value: $burstCount, in: 3...30, step: 1)

            Toggle(isOn: $isTrapFocusEnabled) {
                Label("Trap Focus", systemImage: "scope")
            }

            Toggle(isOn: $showReviewAfterShot) {
                Label("Preview After Shot", systemImage: "photo.on.rectangle")
            }
        }
    }
}

// MARK: - Video

private struct VideoSection: View {
    @Bindable var cameraManager: CameraManager
    @AppStorage("videoResolution")    private var videoResolutionRaw: String  = VideoResolution.hd1080p.rawValue
    @AppStorage("videoFrameRate")     private var videoFrameRate: Int         = 30
    @AppStorage("stabilizationMode")  private var stabilizationModeRaw: String = StabilizationMode.auto.rawValue
    @AppStorage("videoColorSpace")    private var videoColorSpaceRaw: String  = VideoColorSpace.sRGB.rawValue
    @AppStorage("isHDREnabled")       private var isHDREnabled                = false

    private var stabilizationMode: StabilizationMode { StabilizationMode(rawValue: stabilizationModeRaw) ?? .auto }
    private var videoColorSpace: VideoColorSpace { VideoColorSpace(rawValue: videoColorSpaceRaw) ?? .sRGB }
    private var availableColorSpaces: [VideoColorSpace] {
        cameraManager.isAppleLogSupported ? VideoColorSpace.allCases : [.sRGB, .p3, .hlg]
    }
    private var resolution: VideoResolution { VideoResolution(rawValue: videoResolutionRaw) ?? .hd1080p }

    var body: some View {
        Section {
            Picker(selection: $videoResolutionRaw) {
                ForEach(VideoResolution.allCases) { res in
                    Text(res.rawValue).tag(res.rawValue)
                }
            } label: {
                Label("Resolution", systemImage: "video.fill")
            }

            Picker(selection: $videoFrameRate) {
                ForEach(cameraManager.supportedFrameRates(for: resolution), id: \.self) { fps in
                    Text("\(fps) fps").tag(fps)
                }
            } label: {
                Label("Frame Rate", systemImage: "film.fill")
            }
            .pickerStyle(.menu)

            Picker(selection: $stabilizationModeRaw) {
                ForEach(StabilizationMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode.rawValue)
                }
            } label: {
                Label("Stabilization", systemImage: "hand.raised.slash")
            }
            .pickerStyle(.menu)

            Picker(selection: $videoColorSpaceRaw) {
                ForEach(availableColorSpaces) { cs in
                    Text(cs.rawValue).tag(cs.rawValue)
                }
            } label: {
                Label("Color Space", systemImage: "circle.hexagongrid.fill")
            }
            .pickerStyle(.menu)

            if cameraManager.isHDRFormatSupported {
                Toggle(isOn: $isHDREnabled) {
                    Label("HDR", systemImage: "sun.max.fill")
                }
            }
        } header: {
            Text("Video")
        } footer: {
            Text("Frame rate and resolution can also be changed live in the camera view.")
        }
    }
}

// MARK: - Viewfinder

private struct ViewfinderSection: View {
    @AppStorage("showHistogram")      private var showHistogram      = true
    @AppStorage("showWaveform")       private var showWaveform       = false
    @AppStorage("showVectorscope")    private var showVectorscope    = false
    @AppStorage("showLevelIndicator") private var showLevelIndicator = false
    @AppStorage("showEVIndicator")    private var showEVIndicator    = false
    @AppStorage("showGrid")           private var showGrid           = false
    @AppStorage("gridType")           private var gridType           = "Thirds"
    @AppStorage("cropRatio")          private var cropRatioRaw       = CropRatio.full.rawValue

    var body: some View {
        Section {
            Toggle(isOn: $showHistogram) {
                Label("Histogram", systemImage: "chart.bar.fill")
            }

            Toggle(isOn: $showWaveform) {
                Label("Waveform", systemImage: "waveform")
            }

            Toggle(isOn: $showVectorscope) {
                Label("Vectorscope", systemImage: "circle.dotted")
            }

            Toggle(isOn: $showLevelIndicator) {
                Label("Horizon Level", systemImage: "level")
            }

            Toggle(isOn: $showEVIndicator) {
                Label("EV Meter", systemImage: "plusminus.circle")
            }

            Toggle(isOn: $showGrid) {
                Label("Grid", systemImage: "grid")
            }

            if showGrid {
                Picker(selection: $gridType) {
                    ForEach(GridType.allCases.filter { $0 != .none }, id: \.rawValue) {
                        Text($0.rawValue).tag($0.rawValue)
                    }
                } label: {
                    Label("Grid Style", systemImage: "square.grid.3x3")
                }
                .pickerStyle(.menu)
            }

            Picker(selection: $cropRatioRaw) {
                ForEach(CropRatio.allCases) { ratio in
                    Text(ratio.rawValue).tag(ratio.rawValue)
                }
            } label: {
                Label("Crop Ratio", systemImage: "crop")
            }
        } header: {
            Text("Viewfinder")
        }
    }
}

// MARK: - Analysis Tools

private struct AnalysisSection: View {
    @AppStorage("showFocusPeaking")   private var showFocusPeaking   = false
    @AppStorage("focusPeakingColor")  private var focusPeakingColor: String = "red"
    @AppStorage("showZebra")          private var showZebra          = false
    @AppStorage("zebraHighThreshold") private var zebraHighThreshold: Double = 95.0
    @AppStorage("zebraLowThreshold")  private var zebraLowThreshold: Double  = 2.0
    @AppStorage("showFalseColor")     private var showFalseColor     = false

    var body: some View {
        Section {
            Toggle(isOn: $showFocusPeaking) {
                Label("Focus Peaking", systemImage: "scope")
            }

            if showFocusPeaking {
                HStack {
                    Label("Peaking Color", systemImage: "paintpalette")
                    Spacer()
                    peakingColorSwatches
                }
            }

            Toggle(isOn: $showZebra) {
                Label("Zebra Stripes", systemImage: "rectangle.split.2x1.fill")
            }

            if showZebra {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("High (overexposure)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(zebraHighThreshold.rounded()))%")
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundStyle(.red)
                    }
                    Slider(value: $zebraHighThreshold, in: 70...100, step: 1)
                        .tint(.red)

                    HStack {
                        Text("Low (underexposure)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(zebraLowThreshold.rounded()))%")
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundStyle(.blue)
                    }
                    Slider(value: $zebraLowThreshold, in: 0...15, step: 1)
                        .tint(.blue)
                }
                .padding(.vertical, 4)
            }

            Toggle(isOn: $showFalseColor) {
                Label("False Color", systemImage: "thermometer.medium")
            }
        } header: {
            Text("Analysis Tools")
        } footer: {
            Text("Focus peaking highlights in-focus edges. Zebra marks clipping zones — threshold lines also appear on the waveform monitor. False color maps luminance to a diagnostic palette.")
        }
    }

    private var peakingColorSwatches: some View {
        HStack(spacing: 8) {
            ForEach(["red", "green", "white", "yellow"], id: \.self) { name in
                let color: Color = switch name {
                case "red":    .red
                case "green":  .green
                case "white":  .white
                case "yellow": .yellow
                default:       .white
                }
                Button {
                    focusPeakingColor = name
                } label: {
                    ZStack {
                        Circle().fill(color).frame(width: 26, height: 26)
                        if focusPeakingColor == name {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(name == "white" ? .black : .black)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Styles

private struct StylesSection: View {
    @Bindable var stylesManager: StylesManager
    @AppStorage("showStylePicker") private var showStylePicker = false

    var body: some View {
        Section("Styles") {
            Toggle(isOn: Binding(
                get: { stylesManager.isSmartStylesEnabled },
                set: { stylesManager.isSmartStylesEnabled = $0 }
            )) {
                Label("Smart Styles (AI)", systemImage: "sparkle")
            }

            Toggle(isOn: $showStylePicker) {
                Label("Show Style Picker", systemImage: "wand.and.stars")
            }

            if let active = stylesManager.activeStyle {
                HStack {
                    Label("Active Style", systemImage: "camera.filters")
                    Spacer()
                    Text(active.name).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Interface

private struct InterfaceSection: View {
    @AppStorage("showShootingModes") private var showShootingModes = true
    @AppStorage("showGallery")       private var showGallery       = true

    var body: some View {
        Section("Interface") {
            Toggle(isOn: $showShootingModes) {
                Label("Shooting Modes", systemImage: "list.bullet.below.rectangle")
            }
            Toggle(isOn: $showGallery) {
                Label("Gallery Button", systemImage: "photo.stack")
            }
        }
    }
}

// MARK: - Quick Access Bar

private struct QuickAccessSection: View {
    var appState: AppState

    private var available: [QuickAccessItem] {
        QuickAccessItem.allCases.filter { !appState.quickAccessItems.contains($0) }
    }

    var body: some View {
        Section {
            ForEach(appState.quickAccessItems) { item in
                HStack(spacing: 12) {
                    Image(systemName: item.systemImageName)
                        .frame(width: 24)
                        .foregroundStyle(.yellow)
                    Text(item.rawValue)
                }
            }
            .onMove { from, to in
                appState.quickAccessItems.move(fromOffsets: from, toOffset: to)
                appState.saveQuickAccessItems()
            }
            .onDelete { offsets in
                appState.quickAccessItems.remove(atOffsets: offsets)
                appState.saveQuickAccessItems()
            }

            if !available.isEmpty {
                Menu {
                    ForEach(available) { item in
                        Button {
                            appState.quickAccessItems.append(item)
                            appState.saveQuickAccessItems()
                        } label: {
                            Label(item.rawValue, systemImage: item.systemImageName)
                        }
                    }
                } label: {
                    Label("Add Item", systemImage: "plus.circle.fill")
                        .foregroundStyle(.yellow)
                }
            }
        } header: {
            Text("Quick Access Bar")
        } footer: {
            Text("Drag to reorder · Swipe left to remove")
        }
    }
}

// MARK: - Watermark

private struct WatermarkSection: View {
    @AppStorage("watermarkText") private var watermarkText = ""

    var body: some View {
        Section {
            HStack {
                Label("Text", systemImage: "textformat")
                TextField("None", text: $watermarkText)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Watermark")
        } footer: {
            Text("Embedded in each photo. Leave empty to disable.")
        }
    }
}

// MARK: - About

private struct AboutSection: View {
    var body: some View {
        Section("About") {
            HStack {
                Label("Version", systemImage: "info.circle")
                Spacer()
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Label("Build", systemImage: "hammer")
                Spacer()
                Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "–")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
