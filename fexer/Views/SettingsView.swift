import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) var appState
    @Bindable var cameraManager: CameraManager
    @Bindable var stylesManager: StylesManager

    // Capture
    @AppStorage("defaultCaptureFormat") private var defaultFormat = "JPEG"
    @AppStorage("isProRAWEnabled")      private var isProRAW = false
    @AppStorage("isLocationEnabled")    private var isLocationEnabled = true
    @AppStorage("volumeButtonBehavior") private var volumeButtonBehavior = "Shutter"
    @AppStorage("isBracketingEnabled")  private var isBracketingEnabled = false
    @AppStorage("bracketEVStep")        private var bracketEVStep: Double = 1.0
    @AppStorage("selfTimerDelay")       private var selfTimerDelay: Int = 0

    // Viewfinder overlays (shared keys with CameraView)
    @AppStorage("showHistogram")      private var showHistogram      = true
    @AppStorage("showGrid")           private var showGrid           = false
    @AppStorage("gridType")           private var gridType           = "Thirds"
    @AppStorage("showFocusPeaking")   private var showFocusPeaking   = false
    @AppStorage("showZebra")          private var showZebra          = false
    @AppStorage("showLevelIndicator") private var showLevelIndicator = false
    @AppStorage("showFalseColor")     private var showFalseColor     = false

    // Crop ratio
    @AppStorage("cropRatio")          private var cropRatioRaw       = CropRatio.full.rawValue

    // Interface visibility
    @AppStorage("showStylePicker")    private var showStylePicker    = false
    @AppStorage("showShootingModes")  private var showShootingModes  = false
    @AppStorage("showGallery")        private var showGallery        = true

    // Watermark
    @AppStorage("watermarkText") private var watermarkText = ""

    var body: some View {
        NavigationStack {
            Form {
                // MARK: Capture
                Section("Capture") {
                    Picker("Default Format", selection: $defaultFormat) {
                        ForEach(["JPEG", "RAW", "RAW+JPEG"], id: \.self) { Text($0) }
                    }
                    Toggle("ProRAW (iPhone 12 Pro+)", isOn: $isProRAW)
                    Toggle("Save Location", isOn: $isLocationEnabled)
                    Picker("Volume Button", selection: $volumeButtonBehavior) {
                        ForEach(["Shutter", "Zoom", "Disabled"], id: \.self) { Text($0) }
                    }
                    Toggle("Exposure Bracketing (AEB)", isOn: $isBracketingEnabled)
                    if isBracketingEnabled {
                        Picker("Bracket Step", selection: $bracketEVStep) {
                            Text("±⅓ EV").tag(0.333)
                            Text("±⅔ EV").tag(0.667)
                            Text("±1 EV").tag(1.0)
                            Text("±2 EV").tag(2.0)
                        }
                        .pickerStyle(.menu)
                    }
                    Picker("Self-Timer", selection: $selfTimerDelay) {
                        Text("Off").tag(0)
                        Text("2 s").tag(2)
                        Text("5 s").tag(5)
                        Text("10 s").tag(10)
                    }
                    .pickerStyle(.menu)
                }

                // MARK: Viewfinder overlays
                Section("Viewfinder") {
                    Toggle("Histogram", isOn: $showHistogram)
                    Toggle("Level Indicator", isOn: $showLevelIndicator)

                    Toggle("Grid", isOn: $showGrid)
                    if showGrid {
                        Picker("Grid Style", selection: $gridType) {
                            ForEach(GridType.allCases.filter { $0 != .none }, id: \.rawValue) {
                                Text($0.rawValue).tag($0.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    Toggle("Focus Peaking", isOn: $showFocusPeaking)
                    Toggle("Zebra Stripes", isOn: $showZebra)
                    Toggle("False Color", isOn: $showFalseColor)

                    Picker("Crop Ratio", selection: $cropRatioRaw) {
                        ForEach(CropRatio.allCases) { ratio in
                            Text(ratio.rawValue).tag(ratio.rawValue)
                        }
                    }
                }

                // MARK: Interface
                Section("Interface") {
                    Toggle("Style Picker", isOn: $showStylePicker)
                    Toggle("Shooting Modes", isOn: $showShootingModes)
                    Toggle("Gallery Button", isOn: $showGallery)
                }

                // MARK: Styles
                Section("Styles") {
                    Toggle("Smart Styles (AI)", isOn: Binding(
                        get: { stylesManager.isSmartStylesEnabled },
                        set: { stylesManager.isSmartStylesEnabled = $0 }
                    ))
                    if let active = stylesManager.activeStyle {
                        HStack {
                            Text("Current Style")
                            Spacer()
                            Text(active.name).foregroundStyle(.secondary)
                        }
                    }
                }

                // MARK: Quick Access Bar
                Section {
                    ForEach(appState.quickAccessItems) { item in
                        HStack {
                            Image(systemName: item.systemImageName)
                                .frame(width: 28)
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

                    let available = QuickAccessItem.allCases.filter {
                        !appState.quickAccessItems.contains($0)
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
                            Label("Add Item", systemImage: "plus.circle")
                        }
                    }
                } header: {
                    Text("Quick Access Bar")
                } footer: {
                    Text("Drag to reorder · Swipe to remove")
                }

                // MARK: Watermark
                Section("Watermark") {
                    TextField("Watermark text (empty = none)", text: $watermarkText)
                        .autocorrectionDisabled()
                }

                // MARK: About
                Section("About") {
                    HStack {
                        Text("fexer")
                        Spacer()
                        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"
                        Text(version).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Build")
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "–")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .preferredColorScheme(.dark)
            .toolbar { EditButton() }
        }
    }
}
