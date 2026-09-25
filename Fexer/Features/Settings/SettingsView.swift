import SwiftUI

struct SettingsView: View {
    @Bindable var preferences: PreferenceStore
    let capabilities: CameraCapabilities
    @Bindable var library: LibraryModel
    @Binding var ratio: FrameRatio
    @Environment(\.dismiss) private var dismiss
    @State private var confirmReset = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Capture") {
                    Picker("Format", selection: $preferences.value.format) {
                        ForEach(PhotoFormat.allCases.filter { $0 != .raw || capabilities.supportsRAW }) { format in
                            Text(format.rawValue).tag(format)
                        }
                    }
                    if capabilities.supportsProRAW {
                        Toggle("Apple ProRAW", isOn: $preferences.value.proRAW).disabled(preferences.value.format != .raw)
                    }
                    if capabilities.supportsLivePhoto {
                        Toggle("Live Photo", isOn: $preferences.value.livePhoto).disabled(preferences.value.format == .raw)
                    }
                    Picker("Self-timer", selection: $preferences.value.timerSeconds) { Text("Off").tag(0); Text("3 seconds").tag(3); Text("10 seconds").tag(10) }
                    Toggle("Haptic feedback", isOn: $preferences.value.haptics)
                }
                Section("Viewfinder") {
                    Picker("Aspect ratio", selection: $ratio) { ForEach(FrameRatio.allCases) { Text($0.rawValue).tag($0) } }
                    Picker("Grid", selection: $preferences.value.grid) { ForEach(GridStyle.allCases) { Text($0.rawValue).tag($0) } }
                    Picker("Exposure monitor", selection: $preferences.value.monitor) { ForEach(Monitor.allCases) { Text($0.rawValue).tag($0) } }
                    Toggle("Level", isOn: $preferences.value.level)
                    Toggle("Focus peaking", isOn: $preferences.value.peaking)
                    Toggle("Zebras", isOn: $preferences.value.zebras)
                    Toggle("False color", isOn: $preferences.value.falseColor)
                }
                Section {
                    Toggle("Review after capture", isOn: $preferences.value.reviewAfterCapture)
                    Toggle("Save to Photos", isOn: $preferences.value.saveToPhotos)
                    Toggle("Tag location", isOn: $preferences.value.location)
                } header: { Text("After capture") } footer: { Text("Fexer always keeps your originals on this device. Photos access is used only to save finished captures there.") }
                Section("Video") {
                    Toggle("4K", isOn: $preferences.value.video4K)
                    Picker("Frame rate", selection: $preferences.value.videoFPS) { Text("30 fps").tag(30); Text("60 fps").tag(60) }
                }
                Section("Burst, interval & trails") {
                    Stepper("Burst count: \(preferences.value.burstCount)", value: $preferences.value.burstCount, in: 2...30)
                    Stepper("Interval: \(Int(preferences.value.intervalSeconds))s", value: $preferences.value.intervalSeconds, in: 2...60)
                    Stepper("Light trails: \(Int(preferences.value.trailSeconds))s", value: $preferences.value.trailSeconds, in: 1...30)
                }
                Section("Library") {
                    LabeledContent("Captures", value: "\(library.items.count)")
                    let pending = library.items.filter(\.needsPhotosSave)
                    if !pending.isEmpty {
                        Button("Save \(pending.count) to Photos") {
                            Task { await Diagnostics.time("settings.bulkExport (\(pending.count) items)") { for item in pending { await library.export(item) } } }
                        }
                    }
                }
                Section {
                    Button("Reset all settings", role: .destructive) { confirmReset = true }
                } footer: { Text(Diagnostics.buildDescription) }
            }
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Reset all settings to their defaults?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Reset", role: .destructive) { preferences.reset() }
            }
        }
        .tint(Theme.accent).preferredColorScheme(.dark)
    }
}
