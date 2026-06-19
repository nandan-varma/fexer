import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) var appState
    @Bindable var cameraManager: CameraManager
    @Bindable var stylesManager: StylesManager

    var body: some View {
        NavigationStack {
            Form {
                CameraSection(cameraManager: cameraManager)
                CaptureSection()
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
    @AppStorage("defaultCaptureFormat") private var defaultFormat = "JPEG"
    @AppStorage("isProRAWEnabled")      private var isProRAW = false
    @AppStorage("isLocationEnabled")    private var isLocationEnabled = true

    var body: some View {
        Section {
            Picker(selection: $defaultFormat) {
                ForEach(["JPEG", "RAW", "RAW+JPEG"], id: \.self) { Text($0) }
            } label: {
                Label("Format", systemImage: "camera.aperture")
            }

            Toggle(isOn: $isProRAW) {
                Label("ProRAW", systemImage: "sparkles")
            }
            .disabled(!cameraManager.isProRAWSupported)

            Toggle(isOn: $isLocationEnabled) {
                Label("Save Location", systemImage: "location.fill")
            }
        } header: {
            Text("Camera")
        } footer: {
            if cameraManager.isProRAWSupported {
                Text("Location is embedded in EXIF metadata.")
            } else {
                Text("ProRAW is not supported on this device (requires iPhone 12 Pro or later). Location is embedded in EXIF metadata.")
            }
        }
    }
}

// MARK: - Capture

private struct CaptureSection: View {
    @AppStorage("volumeButtonBehavior") private var volumeButtonBehavior = "Shutter"
    @AppStorage("selfTimerDelay")       private var selfTimerDelay: Int = 0
    @AppStorage("isBracketingEnabled")  private var isBracketingEnabled = false
    @AppStorage("bracketEVStep")        private var bracketEVStep: Double = 1.0

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
        }
    }
}

// MARK: - Viewfinder

private struct ViewfinderSection: View {
    @AppStorage("showHistogram")      private var showHistogram      = true
    @AppStorage("showLevelIndicator") private var showLevelIndicator = false
    @AppStorage("showGrid")           private var showGrid           = false
    @AppStorage("gridType")           private var gridType           = "Thirds"
    @AppStorage("cropRatio")          private var cropRatioRaw       = CropRatio.full.rawValue

    var body: some View {
        Section {
            Toggle(isOn: $showHistogram) {
                Label("Histogram", systemImage: "chart.bar.fill")
            }

            Toggle(isOn: $showLevelIndicator) {
                Label("Horizon Level", systemImage: "level")
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
    @AppStorage("showFocusPeaking")  private var showFocusPeaking  = false
    @AppStorage("focusPeakingColor") private var focusPeakingColor: String = "red"
    @AppStorage("showZebra")         private var showZebra         = false
    @AppStorage("showFalseColor")    private var showFalseColor    = false

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

            Toggle(isOn: $showFalseColor) {
                Label("False Color", systemImage: "thermometer.medium")
            }
        } header: {
            Text("Analysis Tools")
        } footer: {
            Text("Focus peaking highlights in-focus edges. Zebra marks overexposed regions. False color maps luminance to a diagnostic palette.")
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
    @AppStorage("showShootingModes") private var showShootingModes = false
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
