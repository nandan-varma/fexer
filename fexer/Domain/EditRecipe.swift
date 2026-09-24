import Foundation

/// Versioned, lossless editing instructions. Original bytes are immutable.
struct EditRecipe: Codable, Hashable, Sendable {
    var version = 1
    var styleID = "original"
    var intensity: Double = 1
    var exposure: Double = 0
    var contrast: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    var saturation: Double = 0
    var vibrance: Double = 0
    var warmth: Double = 0
    var sharpness: Double = 0
    var vignette: Double = 0
    var ratio: FrameRatio = .original
    var quarterTurns = 0
    var flipped = false
    var straighten: Double = 0
    var cropZoom: Double = 1
    var cropX: Double = 0.5
    var cropY: Double = 0.5
    var colors: [ColorBand] = Array(repeating: ColorBand(), count: 8)
    var curves: [[Double]] = Array(repeating: [0, 0.25, 0.5, 0.75, 1], count: 4)
    var importedCube: CubeLUT?

    var isModified: Bool { self != EditRecipe() }

    var validated: EditRecipe {
        var copy = self
        copy.intensity = intensity.bounded(0...1, fallback: 1)
        for parameter in Adjustment.allCases {
            copy[keyPath: parameter.keyPath] = self[keyPath: parameter.keyPath].bounded(parameter.range)
        }
        copy.quarterTurns = ((quarterTurns % 4) + 4) % 4
        copy.straighten = straighten.bounded(-45...45)
        copy.cropZoom = cropZoom.bounded(1...6, fallback: 1)
        copy.cropX = cropX.bounded(0...1, fallback: 0.5)
        copy.cropY = cropY.bounded(0...1, fallback: 0.5)
        copy.colors = (0..<8).map { index in
            index < colors.count ? colors[index].validated : ColorBand()
        }
        copy.curves = (0..<4).map { channel in
            (0..<5).map { point in
                guard channel < curves.count, point < curves[channel].count else { return Double(point) / 4 }
                return curves[channel][point].bounded(0...1, fallback: Double(point) / 4)
            }
        }
        return copy
    }
}

struct ColorBand: Codable, Hashable, Sendable {
    var hue: Double = 0
    var saturation: Double = 0
    var luminance: Double = 0
    var validated: ColorBand {
        .init(hue: hue.bounded(-60...60), saturation: saturation.bounded(-1...1), luminance: luminance.bounded(-1...1))
    }
}

enum Adjustment: String, CaseIterable, Identifiable, Sendable {
    case exposure = "Exposure", highlights = "Highlights", shadows = "Shadows", contrast = "Contrast"
    case saturation = "Saturation", vibrance = "Vibrance", warmth = "Warmth", sharpness = "Sharpness", vignette = "Vignette"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .exposure: "plusminus.circle"
        case .highlights: "sun.max"
        case .shadows: "circle.lefthalf.filled"
        case .contrast: "circle.righthalf.filled"
        case .saturation: "drop"
        case .vibrance: "sparkles"
        case .warmth: "thermometer.medium"
        case .sharpness: "triangle"
        case .vignette: "circle.dotted"
        }
    }
    var range: ClosedRange<Double> {
        switch self {
        case .exposure: -3...3
        case .contrast: -0.5...0.5
        case .sharpness, .vignette: 0...1
        default: -1...1
        }
    }
    var keyPath: WritableKeyPath<EditRecipe, Double> {
        switch self {
        case .exposure: \.exposure
        case .highlights: \.highlights
        case .shadows: \.shadows
        case .contrast: \.contrast
        case .saturation: \.saturation
        case .vibrance: \.vibrance
        case .warmth: \.warmth
        case .sharpness: \.sharpness
        case .vignette: \.vignette
        }
    }
}

/// Bounded undo history avoids retaining rendered images or an entry for every slider frame.
struct EditHistory: Sendable {
    private(set) var past: [EditRecipe] = []
    private(set) var future: [EditRecipe] = []
    mutating func record(_ previous: EditRecipe, replacing current: EditRecipe) {
        guard previous != current else { return }
        past.append(previous)
        if past.count > 50 { past.removeFirst(past.count - 50) }
        future.removeAll()
    }
    mutating func undo(_ current: EditRecipe) -> EditRecipe {
        guard let previous = past.popLast() else { return current }
        future.append(current)
        return previous
    }
    mutating func redo(_ current: EditRecipe) -> EditRecipe {
        guard let next = future.popLast() else { return current }
        past.append(current)
        return next
    }
}
