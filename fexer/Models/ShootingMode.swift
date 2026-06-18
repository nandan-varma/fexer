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

/// Portrait-oriented crop ratios for the viewfinder. "Full" shows the entire
/// sensor frame letterboxed; the others apply crop guides with black bars.
enum CropRatio: String, CaseIterable, Identifiable {
    case full  = "Full"
    case r16_9 = "16:9"
    case r4_3  = "4:3"
    case r3_2  = "3:2"
    case r1_1  = "1:1"
    case r4_5  = "4:5"

    var id: String { rawValue }

    /// Portrait width/height fraction (nil = show full sensor, no fixed ratio).
    var portraitAspect: CGFloat? {
        switch self {
        case .full:  return nil
        case .r16_9: return 9.0 / 16.0
        case .r4_3:  return 3.0 / 4.0
        case .r3_2:  return 2.0 / 3.0
        case .r1_1:  return 1.0
        case .r4_5:  return 4.0 / 5.0
        }
    }
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
