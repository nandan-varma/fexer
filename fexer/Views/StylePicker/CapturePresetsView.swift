import SwiftUI
import AVFoundation

/// Sheet for managing named capture presets (save / apply / delete).
struct CapturePresetsView: View {
    @Environment(\.dismiss) private var dismiss
    var cameraManager: CameraManager
    var stylesManager: StylesManager
    @State private var manager = CapturePresetsManager.shared
    @State private var showSaveSheet = false
    @State private var newPresetName = ""

    var body: some View {
        NavigationStack {
            List {
                if manager.presets.isEmpty {
                    Text("No presets saved yet.\nTap Save Current to capture your settings.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .listRowBackground(Color.clear)
                }
                ForEach(manager.presets) { preset in
                    presetRow(preset)
                }
                .onDelete { manager.presets.remove(atOffsets: $0); manager.presets.forEach { manager.save($0) } }
            }
            .navigationTitle("Presets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save Current") { showSaveSheet = true }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Save Preset", isPresented: $showSaveSheet) {
                TextField("Preset name", text: $newPresetName)
                Button("Save") {
                    guard !newPresetName.isEmpty else { return }
                    let preset = manager.snapshotPreset(
                        from: cameraManager.captureSettings,
                        name: newPresetName,
                        styleName: stylesManager.activeStyle?.name
                    )
                    manager.save(preset)
                    newPresetName = ""
                }
                Button("Cancel", role: .cancel) { newPresetName = "" }
            } message: {
                Text("Name this combination of ISO, shutter, WB, and style.")
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func presetRow(_ preset: CapturePreset) -> some View {
        Button {
            applyPreset(preset)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(preset.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                HStack(spacing: 12) {
                    if preset.isAutoISO {
                        Text("ISO auto")
                    } else {
                        Text("ISO \(Int(preset.isoValue))")
                    }
                    if preset.isAutoShutter {
                        Text("SS auto")
                    } else {
                        Text(CaptureSettings.formatShutterSpeed(preset.shutterSpeedSeconds))
                    }
                    if preset.isAutoWhiteBalance {
                        Text("WB auto")
                    } else {
                        Text("\(Int(preset.whiteBalanceKelvin))K")
                    }
                    if preset.exposureCompensation != 0 {
                        let sign = preset.exposureCompensation > 0 ? "+" : ""
                        Text("\(sign)\(String(format: "%.1f", preset.exposureCompensation)) EV")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let style = preset.styleName {
                    Text(style)
                        .font(.caption2)
                        .foregroundStyle(.yellow.opacity(0.8))
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func applyPreset(_ preset: CapturePreset) {
        // Auto / manual ISO
        if preset.isAutoISO {
            cameraManager.setAutoExposure()
        } else {
            let dur = CMTime(seconds: preset.shutterSpeedSeconds, preferredTimescale: 1_000_000)
            cameraManager.setManualExposure(iso: preset.isoValue, duration: dur)
        }
        // White balance
        if preset.isAutoWhiteBalance {
            cameraManager.setAutoWhiteBalance()
        } else {
            cameraManager.setWhiteBalance(kelvin: preset.whiteBalanceKelvin, tint: preset.whiteBalanceTint)
        }
        // EV compensation
        cameraManager.setExposureCompensation(preset.exposureCompensation)
    }
}
