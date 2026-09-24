import Foundation

// These values cross actor boundaries; AVFoundation objects never enter view state.
enum CaptureMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case photo = "Photo", video = "Video", burst = "Burst", lightTrails = "Light trails", interval = "Interval"
    var id: Self { self }
}

enum PhotoFormat: String, CaseIterable, Codable, Sendable, Identifiable {
    case heif = "HEIF", jpeg = "JPEG", raw = "RAW + JPEG"
    var id: Self { self }
    var fileExtension: String { self == .heif ? "heic" : "jpg" }
}

enum FlashSetting: String, CaseIterable, Codable, Sendable, Identifiable {
    case off = "Off", auto = "Auto", on = "On"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .off: "bolt.slash"
        case .auto: "bolt.badge.automatic"
        case .on: "bolt.fill"
        }
    }
}

enum FrameRatio: String, CaseIterable, Codable, Sendable, Identifiable {
    case original = "4:3", square = "1:1", portrait = "4:5", wide = "16:9"
    var id: Self { self }
    var portraitAspect: Double {
        switch self {
        case .original: 3 / 4
        case .square: 1
        case .portrait: 4 / 5
        case .wide: 9 / 16
        }
    }
}

enum GridStyle: String, CaseIterable, Codable, Sendable, Identifiable {
    case off = "Off", thirds = "Thirds", golden = "Golden ratio", diagonal = "Diagonal"
    var id: Self { self }
}

enum Monitor: String, CaseIterable, Codable, Sendable, Identifiable {
    case off = "Off", histogram = "Histogram", waveform = "Waveform", vectorscope = "Vectorscope"
    var id: Self { self }
}

struct CameraControls: Codable, Equatable, Sendable {
    var manualExposure = false
    var iso: Double = 100
    var shutter: Double = 1 / 125
    var exposureBias: Double = 0
    var manualFocus = false
    var focus: Double = 0.5
    var manualWhiteBalance = false
    var temperature: Double = 5500
    var tint: Double = 0
    var zoom: Double = 1
    var exposureLocked = false
    var torch = false
}

struct CameraReading: Equatable, Sendable {
    var iso: Double = 100
    var shutter: Double = 1 / 125
    var temperature: Double = 5500
    var focus: Double = 0.5
    var exposureOffset: Double = 0
    var zoom: Double = 1
}

struct CameraLens: Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    let label: String
    let isFront: Bool
}

struct CameraCapabilities: Sendable, Equatable {
    var lenses: [CameraLens] = []
    var activeLensID = ""
    var supportsRAW = false
    var supportsProRAW = false
    var supportsLivePhoto = false
    var supportsFlash = false
    var supportsTorch = false
    var supportsManualExposure = false
    var supportsManualFocus = false
    var isoRange: ClosedRange<Double> = 25...3200
    var shutterRange: ClosedRange<Double> = (1 / 8000)...1
    var zoomRange: ClosedRange<Double> = 1...10
    var exposureRange: ClosedRange<Double> = -3...3
    var isFront: Bool { lenses.first { $0.id == activeLensID }?.isFront ?? false }

    static let sample = CameraCapabilities(
        lenses: [.init(id: "sample", name: "Sample camera", label: "1×", isFront: false)],
        activeLensID: "sample", supportsManualExposure: true, supportsManualFocus: true
    )
}

struct CaptureRequest: Sendable {
    var format: PhotoFormat = .heif
    var flash: FlashSetting = .off
    var livePhoto = false
    var proRAW = false
    var rotation: Double = 90
}

struct PhotoPayload: Sendable {
    var processed: Data
    var raw: Data?
    var liveMovieURL: URL?
}

struct CapturePreset: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var controls: CameraControls
    var recipe: EditRecipe
}

enum CameraPhase: Equatable, Sendable {
    case idle, starting, ready, denied, interrupted, failed(String)
}

enum CaptureActivity: Equatable, Sendable {
    case idle, countdown(Int), capturing, recording(Date), finishing, sequence(Int)
    var isIdle: Bool { self == .idle }
    var isRecording: Bool { if case .recording = self { true } else { false } }
}

enum CameraEvent: Sendable {
    case phase(CameraPhase)
    case capabilities(CameraCapabilities)
    case reading(CameraReading)
}

enum CameraText {
    static func shutter(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "–" }
        if seconds >= 1 { return seconds.formatted(.number.precision(.fractionLength(0...1))) + "s" }
        return "1/\(Int((1 / max(seconds, 0.000001)).rounded()))"
    }
}
