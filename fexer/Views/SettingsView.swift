import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) var appState
    @Bindable var cameraManager: CameraManager
    @Bindable var stylesManager: StylesManager

    @AppStorage("defaultCaptureFormat") private var defaultFormat = "JPEG"
    @AppStorage("isProRAWEnabled") private var isProRAW = false
    @AppStorage("isLocationEnabled") private var isLocationEnabled = true
    @AppStorage("volumeButtonBehavior") private var volumeButtonBehavior = "Shutter"
    @AppStorage("defaultGridType") private var defaultGridType = "Thirds"
    @AppStorage("histogramPosition") private var histogramPosition = "Top Left"
    @AppStorage("showLevelAlways") private var showLevelAlways = true
    @AppStorage("watermarkText") private var watermarkText = ""

    var body: some View {
        NavigationStack {
            Form {
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

                Section("Display") {
                    Picker("Grid", selection: $defaultGridType) {
                        ForEach(["None", "Thirds", "Phi", "Square", "Diagonal"], id: \.self) { Text($0) }
                    }

                    Picker("Histogram Position", selection: $histogramPosition) {
                        ForEach(["Top Left", "Top Right", "Draggable"], id: \.self) { Text($0) }
                    }

                    Toggle("Always Show Level", isOn: $showLevelAlways)
                }

                Section("Styles") {
                    Toggle("Smart Styles (AI)", isOn: Binding(
                        get: { stylesManager.isSmartStylesEnabled },
                        set: { stylesManager.isSmartStylesEnabled = $0 }
                    ))

                    if let active = stylesManager.activeStyle {
                        HStack {
                            Text("Current Style")
                            Spacer()
                            Text(active.name)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

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

                Section("Watermark") {
                    TextField("Watermark text (empty = none)", text: $watermarkText)
                        .autocorrectionDisabled()
                }

                Section("About") {
                    HStack {
                        Text("fexer")
                        Spacer()
                        Text("1.0")
                            .foregroundStyle(.secondary)
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
