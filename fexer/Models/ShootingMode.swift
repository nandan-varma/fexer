import Foundation

enum ShootingMode: String, CaseIterable, Identifiable {
    case photo = "Photo"
    case video = "Video"
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
        case .video: return "video.fill"
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
    case full      = "Full"
    case r16_9     = "16:9"
    case r4_3      = "4:3"
    case r3_2      = "3:2"
    case r1_1      = "1:1"
    case r4_5      = "4:5"
    /// Anamorphic 2.39:1 widescreen (portrait: 100/239 ≈ 0.418 width/height)
    case r239_100  = "2.39:1"

    var id: String { rawValue }

    /// Portrait width/height fraction (nil = show full sensor, no fixed ratio).
    var portraitAspect: CGFloat? {
        switch self {
        case .full:     return nil
        case .r16_9:    return 9.0 / 16.0
        case .r4_3:     return 3.0 / 4.0
        case .r3_2:     return 2.0 / 3.0
        case .r1_1:     return 1.0
        case .r4_5:     return 4.0 / 5.0
        case .r239_100: return 100.0 / 239.0
        }
    }

    /// Height of each letterbox bar (top and bottom) in points for the given view size.
    /// When using `.full`, `imageAspect` (width/height of the camera sensor) must be provided.
    func letterboxBarHeight(viewSize: CGSize, imageAspect: CGFloat? = nil) -> CGFloat {
        let contentH: CGFloat
        if self == .full {
            guard let aspect = imageAspect, aspect > 0 else { return 0 }
            let viewAspect = viewSize.width / viewSize.height
            guard viewAspect < aspect else { return 0 }
            contentH = viewSize.width / aspect
        } else {
            guard let aspect = portraitAspect else { return 0 }
            contentH = viewSize.width / aspect
        }
        return max(0, (viewSize.height - contentH) / 2)
    }
}

enum MeteringMode: String, CaseIterable {
    case matrix = "Matrix"
    case center = "Center"
    case spot   = "Spot"
    case highlightWeighted = "Highlight"

    var next: MeteringMode {
        let all = MeteringMode.allCases
        return all[((all.firstIndex(of: self) ?? 0) + 1) % all.count]
    }

    var systemImage: String {
        switch self {
        case .matrix: return "square.grid.3x3"
        case .center: return "circle.and.line.horizontal"
        case .spot:   return "scope"
        case .highlightWeighted: return "sun.max"
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
    case falseColor = "FalseColor"
    case bracketAEB = "Bracket"
    case afMode = "AFMode"
    case wbBracket   = "WBBracket"
    case waveform    = "Waveform"
    case vectorscope = "Vectorscope"

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
        case .falseColor: return "camera.filters"
        case .bracketAEB: return "plusminus"
        case .afMode: return "viewfinder.circle"
        case .wbBracket:   return "thermometer.sun"
        case .waveform:    return "waveform"
        case .vectorscope: return "circle.grid.cross"
        }
    }
}

/// Named white-balance presets with fixed Kelvin temperature and tint values.
enum WBPreset: String, CaseIterable, Identifiable {
    case auto        = "Auto"
    case daylight    = "Day"
    case cloudy      = "Cloud"
    case shade       = "Shade"
    case tungsten    = "Bulb"
    case fluorescent = "Fluor"
    case flash       = "Flash"

    var id: String { rawValue }

    /// Returns nil for Auto (use device auto-WB), otherwise a fixed Kelvin value.
    var kelvin: Float? {
        switch self {
        case .auto:         return nil
        case .daylight:     return 5600
        case .cloudy:       return 6500
        case .shade:        return 7500
        case .tungsten:     return 3200
        case .fluorescent:  return 4000
        case .flash:        return 5500
        }
    }

    var tint: Float {
        switch self {
        case .auto:         return 0
        case .daylight:     return 0
        case .cloudy:       return 5
        case .shade:        return 10
        case .tungsten:     return -8
        case .fluorescent:  return 20
        case .flash:        return -3
        }
    }

    var systemImage: String {
        switch self {
        case .auto:         return "a.circle"
        case .daylight:     return "sun.max"
        case .cloudy:       return "cloud.sun"
        case .shade:        return "house"
        case .tungsten:     return "lightbulb"
        case .fluorescent:  return "lightbulb.led"
        case .flash:        return "bolt"
        }
    }

    var kelvinLabel: String {
        guard let k = kelvin else { return "AUTO" }
        return "\(Int(k))K"
    }
}
