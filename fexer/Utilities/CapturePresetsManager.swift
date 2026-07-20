import AVFoundation
import Foundation

struct CapturePreset: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var isoValue: Float
    var shutterSpeedSeconds: Double   // stored as seconds; convert to CMTime on apply
    var whiteBalanceKelvin: Float
    var whiteBalanceTint: Float
    var exposureCompensation: Float
    var isAutoISO: Bool
    var isAutoShutter: Bool
    var isAutoWhiteBalance: Bool
    var styleName: String?
}

/// Loads and saves named capture presets to UserDefaults.
@Observable
final class CapturePresetsManager {
    static let shared = CapturePresetsManager()

    var presets: [CapturePreset] = []

    private let key = "com.fexer.capturePresets"

    init() { load() }

    func save(_ preset: CapturePreset) {
        if let idx = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[idx] = preset
        } else {
            presets.append(preset)
        }
        persist()
    }

    func delete(id: UUID) {
        presets.removeAll { $0.id == id }
        persist()
    }

    func snapshotPreset(from settings: CaptureSettings, name: String, styleName: String?) -> CapturePreset {
        CapturePreset(
            name: name,
            isoValue: settings.isoValue,
            shutterSpeedSeconds: CMTimeGetSeconds(settings.shutterSpeed),
            whiteBalanceKelvin: settings.whiteBalance,
            whiteBalanceTint: settings.whiteBalanceTint,
            exposureCompensation: settings.exposureCompensation,
            isAutoISO: settings.isAutoISO,
            isAutoShutter: settings.isAutoShutter,
            isAutoWhiteBalance: settings.isAutoWhiteBalance,
            styleName: styleName
        )
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([CapturePreset].self, from: data)
        else { return }
        presets = decoded
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
