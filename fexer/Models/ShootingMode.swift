import Foundation

enum ShootingMode: String, CaseIterable, Identifiable {
    case photo = "Photo"
    case portrait = "Portrait"
    case longExposure = "Long Exp"
    case night = "Night"
    case burst = "Burst"
    case selfTimer = "Timer"
    case timelapse = "Timelapse"
    case anamorphic = "Anamorphic"

    var id: String { rawValue }

    var systemImageName: String {
        switch self {
        case .photo: return "camera"
        case .portrait: return "person.crop.square"
        case .longExposure: return "timelapse"
        case .night: return "moon.stars"
        case .burst: return "square.stack.3d.up"
        case .selfTimer: return "timer"
        case .timelapse: return "clock.arrow.2.circlepath"
        case .anamorphic: return "film"
        }
    }
}

enum GridType: String, CaseIterable {
    case none = "None"
    case thirds = "Thirds"
    case phi = "Phi"
    case square = "Square"
    case diagonal = "Diagonal"
}

enum QuickAccessItem: String, CaseIterable, Identifiable {
    case flash = "Flash"
    case timer = "Timer"
    case grid = "Grid"
    case histogram = "Histogram"
    case flipCamera = "Flip"
    case focusPeaking = "Peaking"
    case zebra = "Zebra"
    case levelIndicator = "Level"
    case livePhoto = "Live"
    case format = "Format"

    var id: String { rawValue }

    var systemImageName: String {
        switch self {
        case .flash: return "bolt"
        case .timer: return "timer"
        case .grid: return "grid"
        case .histogram: return "waveform.path.ecg"
        case .flipCamera: return "arrow.triangle.2.circlepath.camera"
        case .focusPeaking: return "scope"
        case .zebra: return "strikethrough"
        case .levelIndicator: return "level"
        case .livePhoto: return "livephoto"
        case .format: return "doc.badge.gearshape"
        }
    }
}
