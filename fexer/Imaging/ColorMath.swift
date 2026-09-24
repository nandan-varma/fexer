import Foundation

enum ColorMath {
    static func curve(_ values: [Double], at input: Double) -> Double {
        guard values.count == 5 else { return input }
        let position = input.bounded(0...1) * 4
        let index = min(Int(position), 3)
        return values[index] + (values[index + 1] - values[index]) * (position - Double(index))
    }

    static func rgbToHSL(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let high = max(r, g, b), low = min(r, g, b), delta = high - low
        let light = (high + low) / 2
        guard delta > 0.00001 else { return (0, 0, light) }
        let saturation = delta / max(1 - abs(2 * light - 1), 0.00001)
        let hue: Double
        if high == r { hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
        else if high == g { hue = (b - r) / delta + 2 }
        else { hue = (r - g) / delta + 4 }
        return ((hue / 6 + 1).truncatingRemainder(dividingBy: 1), saturation, light)
    }

    static func hslToRGB(_ hue: Double, _ saturation: Double, _ light: Double) -> (Double, Double, Double) {
        let h = ((hue.truncatingRemainder(dividingBy: 1)) + 1).truncatingRemainder(dividingBy: 1)
        let chroma = (1 - abs(2 * light - 1)) * saturation
        let secondary = chroma * (1 - abs((h * 6).truncatingRemainder(dividingBy: 2) - 1))
        let offset = light - chroma / 2
        let channels: (Double, Double, Double)
        switch Int(h * 6) {
        case 0: channels = (chroma, secondary, 0)
        case 1: channels = (secondary, chroma, 0)
        case 2: channels = (0, chroma, secondary)
        case 3: channels = (0, secondary, chroma)
        case 4: channels = (secondary, 0, chroma)
        default: channels = (chroma, 0, secondary)
        }
        return (channels.0 + offset, channels.1 + offset, channels.2 + offset)
    }

    static func adjustmentCube(_ recipe: EditRecipe) -> CubeLUT? {
        let state = recipe.validated
        let identity: [Double] = [0, 0.25, 0.5, 0.75, 1]
        guard state.colors.contains(where: { $0 != ColorBand() }) || state.curves.contains(where: { $0 != identity }) else { return nil }
        let centers: [Double] = [0, 1 / 12, 1 / 6, 1 / 3, 0.5, 2 / 3, 0.78, 0.92]
        let dimension = 17
        var floats: [Float] = []
        floats.reserveCapacity(dimension * dimension * dimension * 4)
        for blue in 0..<dimension {
            for green in 0..<dimension {
                for red in 0..<dimension {
                    var r = curve(state.curves[1], at: Double(red) / 16)
                    var g = curve(state.curves[2], at: Double(green) / 16)
                    var b = curve(state.curves[3], at: Double(blue) / 16)
                    r = curve(state.curves[0], at: r)
                    g = curve(state.curves[0], at: g)
                    b = curve(state.curves[0], at: b)
                    var (h, s, l) = rgbToHSL(r, g, b)
                    let originalHue = h
                    for (index, band) in state.colors.enumerated() {
                        let distance = abs(originalHue - centers[index])
                        let weight = max(0, 1 - min(distance, 1 - distance) / 0.12)
                        h += band.hue / 360 * weight
                        s += band.saturation * weight
                        l += band.luminance * weight * 0.5
                    }
                    (r, g, b) = hslToRGB(h, s.bounded(0...1), l.bounded(0...1))
                    floats.append(contentsOf: [Float(r.bounded(0...1)), Float(g.bounded(0...1)), Float(b.bounded(0...1)), 1])
                }
            }
        }
        return CubeLUT(dimension: dimension, rgba: floats.withUnsafeBytes { Data($0) })
    }
}
