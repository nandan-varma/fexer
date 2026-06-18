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

    // Viewfinder overlays (shared keys with CameraView)
    @AppStorage("showHistogram")      private var showHistogram      = true
    @AppStorage("showGrid")           private var showGrid           = false
    @AppStorage("gridType")           private var gridType           = "Thirds"
    @AppStorage("showFocusPeaking")   private var showFocusPeaking   = false
    @AppStorage("showZebra")          private var showZebra          = false
    @AppStorage("showLevelIndicator") private var showLevelIndicator = false

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
                Section("Quick Access Bar") {
                    ForEach(appState.quickAccessItems) { item in
                        HStack {
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
                        Text("1.0").foregroundStyle(.secondary)
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
        }
    }
}
