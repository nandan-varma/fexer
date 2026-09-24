import SwiftUI

struct ManualControls: View {
    @Bindable var model: CameraModel
    @Environment(\.dismiss) private var dismiss
    @State private var presetName = ""
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Manual exposure", isOn: $model.controls.manualExposure).disabled(!model.capabilities.supportsManualExposure)
                    if model.controls.manualExposure {
                        ValueSlider(title: "ISO", value: $model.controls.iso, range: model.capabilities.isoRange, display: "\(Int(model.controls.iso))")
                        ValueSlider(title: "Shutter", value: Binding(get: { log2(model.controls.shutter.bounded(model.capabilities.shutterRange)) }, set: { model.controls.shutter = pow(2, $0) }), range: log2(model.capabilities.shutterRange.lowerBound)...log2(model.capabilities.shutterRange.upperBound), display: CameraText.shutter(model.controls.shutter))
                    } else {
                        ValueSlider(title: "Exposure compensation", value: $model.controls.exposureBias, range: model.capabilities.exposureRange, display: String(format: "%+.1f EV", model.controls.exposureBias))
                        Toggle("Lock auto exposure", isOn: $model.controls.exposureLocked)
                    }
                } header: { Text("Exposure") } footer: { Text("Auto is a good starting point. Manual values are limited to what this lens supports.") }
                Section("Focus") {
                    Toggle("Manual focus", isOn: $model.controls.manualFocus).disabled(!model.capabilities.supportsManualFocus)
                    if model.controls.manualFocus { ValueSlider(title: "Near → far", value: $model.controls.focus, range: 0...1, display: model.controls.focus.formatted(.percent.precision(.fractionLength(0)))) }
                    Toggle("Focus peaking", isOn: $model.preferences.value.peaking)
                }
                Section("White balance") {
                    Toggle("Manual white balance", isOn: $model.controls.manualWhiteBalance)
                    if model.controls.manualWhiteBalance {
                        ValueSlider(title: "Temperature", value: $model.controls.temperature, range: 2500...10000, display: "\(Int(model.controls.temperature)) K")
                        ValueSlider(title: "Tint", value: $model.controls.tint, range: -150...150, display: "\(Int(model.controls.tint))")
                    }
                }
                Section("Camera") {
                    ValueSlider(title: "Zoom", value: $model.controls.zoom, range: model.capabilities.zoomRange, display: String(format: "%.1f×", model.controls.zoom))
                    if model.capabilities.supportsTorch { Toggle("Continuous light", isOn: $model.controls.torch) }
                    ForEach(model.capabilities.lenses) { lens in
                        Button { Task { await model.selectLens(lens) } } label: {
                            HStack { Text(lens.name); Spacer(); if model.capabilities.activeLensID == lens.id { Image(systemName: "checkmark") } }
                        }
                    }
                }
                Section("Presets") {
                    ForEach(model.preferences.value.presets) { preset in
                        Button(preset.name) { model.controls = preset.controls; model.recipe = preset.recipe }
                    }.onDelete { model.preferences.value.presets.remove(atOffsets: $0) }
                    HStack {
                        TextField("Preset name", text: $presetName)
                        Button("Save") {
                            model.preferences.value.presets.append(.init(name: String(presetName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40)), controls: model.controls, recipe: model.recipe))
                            presetName = ""
                        }.disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.preferences.value.presets.count >= 20)
                    }
                }
                Button("Reset camera to auto") { model.controls = CameraControls() }
            }
            .navigationTitle("Camera controls").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.tint(Theme.accent).preferredColorScheme(.dark)
    }
}

struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var display: String? = nil
    var onEditingChanged: (Bool) -> Void = { _ in }
    var body: some View {
        VStack(spacing: 8) {
            HStack { Text(title); Spacer(); Text(display ?? String(format: "%+.2f", value)).monospacedDigit().foregroundStyle(Theme.accent) }
                .font(.subheadline)
            Slider(value: $value, in: range, onEditingChanged: onEditingChanged).accessibilityLabel(title)
        }.padding(.vertical, 4)
    }
}
