import Foundation
import Observation

struct Preferences: Codable, Equatable, Sendable {
    var format: PhotoFormat = .heif
    var flash: FlashSetting = .off
    var timerSeconds = 0
    var livePhoto = false
    var proRAW = false
    var grid: GridStyle = .off
    var monitor: Monitor = .off
    var peaking = false
    var zebras = false
    var falseColor = false
    var level = false
    var haptics = true
    var saveToPhotos = true
    var location = false
    var reviewAfterCapture = false
    var video4K = false
    var videoFPS = 30
    var burstCount = 10
    var intervalSeconds: Double = 5
    var trailSeconds: Double = 4
    var presets: [CapturePreset] = []
}

@MainActor @Observable
final class PreferenceStore {
    var value: Preferences { didSet { persist() } }
    private let defaults: UserDefaults
    private static let key = "fexer.preferences.v2"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key) {
            do { value = try JSONDecoder().decode(Preferences.self, from: data) }
            catch {
                Diagnostics.report(error, operation: "Load preferences")
                value = Preferences()
            }
        } else {
            // Migrate only preferences with equivalent behavior in the new app.
            var migrated = Preferences()
            migrated.grid = defaults.bool(forKey: "showGrid") ? .thirds : .off
            migrated.haptics = true
            migrated.reviewAfterCapture = defaults.bool(forKey: "showReviewAfterShot")
            migrated.format = PhotoFormat(rawValue: defaults.string(forKey: "defaultCaptureFormat") ?? "") ?? .heif
            value = migrated
        }
    }

    func reset() { value = Preferences() }

    private func persist() {
        do { defaults.set(try JSONEncoder().encode(value), forKey: Self.key) }
        catch { Diagnostics.report(error, operation: "Save preferences") }
    }
}
