import SwiftUI

/// Presented as a small, background-interactive sheet so the live viewfinder stays visible
/// (and tappable-to-focus) above it — pro controls are only useful if you can watch their effect.
struct ManualControls: View {
    @Bindable var model: CameraModel
    @Environment(\.dismiss) private var dismiss
    @State private var category: Category = .exposure
    @State private var presetName = ""

    enum Category: String, CaseIterable, Identifiable {
        case exposure = "Exposure", focus = "Focus", whiteBalance = "WB", camera = "Camera"
        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("Camera controls").font(.subheadline.weight(.semibold))
                Spacer()
                Button("Reset") { model.controls = CameraControls() }
                    .font(.subheadline).disabled(model.controls == CameraControls())
                Button("Done") { dismiss() }.font(.subheadline.weight(.semibold))
            }
            Picker("Control", selection: $category) {
                ForEach(Category.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            ScrollView {
                VStack(spacing: 16) {
                    switch category {
                    case .exposure: exposurePane
                    case .focus: focusPane
                    case .whiteBalance: whiteBalancePane
                    case .camera: cameraPane
                    }
                }.padding(.bottom, 12)
            }
        }
        .padding(.horizontal, 18).padding(.top, 12)
        .background(Theme.background)
        .foregroundStyle(.white)
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
    }

    private var exposurePane: some View {
        VStack(spacing: 14) {
            Toggle("Manual exposure", isOn: $model.controls.manualExposure).disabled(!model.capabilities.supportsManualExposure)
            if model.controls.manualExposure {
                ValueSlider(title: "ISO", value: $model.controls.iso, range: model.capabilities.isoRange, display: "\(Int(model.controls.iso))")
                ValueSlider(title: "Shutter", value: Binding(
                    get: { log2(model.controls.shutter.bounded(model.capabilities.shutterRange)) },
                    set: { model.controls.shutter = pow(2, $0) }
                ), range: log2(model.capabilities.shutterRange.lowerBound)...log2(model.capabilities.shutterRange.upperBound), display: CameraText.shutter(model.controls.shutter))
            } else {
                ValueSlider(title: "Exposure compensation", value: $model.controls.exposureBias, range: model.capabilities.exposureRange, display: String(format: "%+.1f EV", model.controls.exposureBias))
                Toggle("Lock auto exposure", isOn: $model.controls.exposureLocked)
            }
            hint("Auto is a good starting point. Manual values are limited to what this lens supports.")
        }
    }

    private var focusPane: some View {
        VStack(spacing: 14) {
            Toggle("Manual focus", isOn: $model.controls.manualFocus).disabled(!model.capabilities.supportsManualFocus)
            if model.controls.manualFocus {
                ValueSlider(title: "Near → far", value: $model.controls.focus, range: 0...1, display: model.controls.focus.formatted(.percent.precision(.fractionLength(0))))
            }
            Toggle("Focus peaking", isOn: $model.preferences.value.peaking)
            hint(model.controls.manualFocus
                 ? "Drag while watching the viewfinder above — peaking highlights the sharpest edges."
                 : "Turn on focus peaking to see which edges are sharp while you drag.")
        }
    }

    private var whiteBalancePane: some View {
        VStack(spacing: 14) {
            Toggle("Manual white balance", isOn: $model.controls.manualWhiteBalance)
            if model.controls.manualWhiteBalance {
                ValueSlider(title: "Temperature", value: $model.controls.temperature, range: 2500...10000, display: "\(Int(model.controls.temperature)) K")
                ValueSlider(title: "Tint", value: $model.controls.tint, range: -150...150, display: "\(Int(model.controls.tint))")
            } else {
                hint("Auto white balance adapts to the scene. Switch to manual to hold a fixed color temperature.")
            }
        }
    }

    private var cameraPane: some View {
        VStack(spacing: 14) {
            ValueSlider(title: "Zoom", value: $model.controls.zoom, range: model.capabilities.zoomRange, display: String(format: "%.1f×", model.controls.zoom))
            if model.capabilities.supportsTorch { Toggle("Continuous light", isOn: $model.controls.torch) }
            if model.capabilities.lenses.count > 1 {
                HStack(spacing: 8) {
                    ForEach(model.capabilities.lenses) { lens in
                        Button { Task { await model.selectLens(lens) } } label: {
                            Text(lens.name).font(.footnote.weight(.semibold)).padding(.horizontal, 12).frame(minHeight: 36)
                                .background(model.capabilities.activeLensID == lens.id ? Theme.accent.opacity(0.25) : Theme.surface, in: Capsule())
                        }.tint(model.capabilities.activeLensID == lens.id ? Theme.accent : .white)
                    }
                    Spacer(minLength: 0)
                }
            }
            Divider().overlay(Theme.muted.opacity(0.3))
            presetsSection
        }
    }

    private var presetsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Presets").font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
            if model.preferences.value.presets.isEmpty {
                hint("Save the current exposure, focus, and white balance as a preset to reapply later.")
            }
            ForEach(model.preferences.value.presets) { preset in
                HStack {
                    Button(preset.name) { model.controls = preset.controls; model.recipe = preset.recipe }
                    Spacer()
                    Button { model.preferences.value.presets.removeAll { $0.id == preset.id } } label: {
                        Image(systemName: "trash").foregroundStyle(.red)
                    }.accessibilityLabel("Delete \(preset.name)")
                }
            }
            HStack {
                TextField("Preset name", text: $presetName).textFieldStyle(.roundedBorder)
                Button("Save") {
                    model.preferences.value.presets.append(.init(name: String(presetName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40)), controls: model.controls, recipe: model.recipe))
                    presetName = ""
                }.disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.preferences.value.presets.count >= 20)
            }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.caption2).foregroundStyle(Theme.muted).frame(maxWidth: .infinity, alignment: .leading)
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
