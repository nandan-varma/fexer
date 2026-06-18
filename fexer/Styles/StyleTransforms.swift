import Foundation

struct StyleParams {
    var saturation: Float32 = 1.0     // 0=B&W, 1=normal, >1=vivid
    var contrast: Float32 = 1.0       // pivot at 0.5 in sRGB
    var exposure: Float32 = 0         // stops
    var warmth: Float32 = 0           // -1=cool, +1=warm
    var tint: Float32 = 0             // -1=green, +1=magenta
    var shadowLift: Float32 = 0       // lifts blacks 0–0.15
    // Per-channel additive in shadow / highlight regions
    var shadowR: Float32 = 0, shadowG: Float32 = 0, shadowB: Float32 = 0
    var highlightR: Float32 = 0, highlightG: Float32 = 0, highlightB: Float32 = 0
    // Custom luminance weights for B&W (only used when saturation == 0)
    var bwR: Float32 = 0.2126, bwG: Float32 = 0.7152, bwB: Float32 = 0.0722
}

enum StyleTransforms {

    // MARK: - Per-style parameter tables

    static func params(for style: PhotoStyle) -> StyleParams {
        switch style.name {
        // ── Film ─────────────────────────────────────────────────────────────────
        case "Portra 400":
            return StyleParams(saturation: 0.88, contrast: 0.90, exposure: 0.05,
                               warmth: 0.35, shadowLift: 0.04,
                               shadowR: 0.02, highlightR: 0.015, highlightB: -0.01)
        case "Tri-X BW":
            return StyleParams(saturation: 0, contrast: 1.20, exposure: 0,
                               bwR: 0.30, bwG: 0.59, bwB: 0.11)
        case "Velvia 50":
            return StyleParams(saturation: 1.35, contrast: 1.12, exposure: -0.10,
                               warmth: 0.18, shadowB: -0.01)
        case "Provia 100":
            return StyleParams(saturation: 0.98, contrast: 1.02, exposure: 0,
                               warmth: 0.10, shadowLift: 0.02)
        case "HP5 BW":
            return StyleParams(saturation: 0, contrast: 1.05, exposure: 0.05,
                               shadowLift: 0.025,
                               bwR: 0.22, bwG: 0.70, bwB: 0.08)
        case "Gold 200":
            return StyleParams(saturation: 1.08, contrast: 0.95, exposure: 0.10,
                               warmth: 0.55, shadowLift: 0.05,
                               shadowR: 0.025, shadowG: 0.01, shadowB: -0.02,
                               highlightR: 0.02, highlightB: -0.01)
        case "Agfa Vista":
            return StyleParams(saturation: 1.05, contrast: 1.00, exposure: 0,
                               warmth: 0.12, shadowLift: 0.06,
                               shadowG: 0.015, shadowB: 0.01)
        // ── Genre ─────────────────────────────────────────────────────────────────
        case "Street":
            return StyleParams(saturation: 0.78, contrast: 1.18, exposure: -0.08,
                               warmth: -0.18)
        case "Portrait Warm":
            return StyleParams(saturation: 0.90, contrast: 0.88, exposure: 0.08,
                               warmth: 0.45, shadowLift: 0.05,
                               highlightR: 0.01, highlightB: -0.01)
        case "Landscape":
            return StyleParams(saturation: 1.18, contrast: 1.08, exposure: -0.05,
                               warmth: 0.08,
                               shadowB: 0.018, highlightG: 0.01)
        case "Astro":
            return StyleParams(saturation: 0.90, contrast: 1.28, exposure: -0.45,
                               warmth: -0.15, shadowB: 0.03)
        case "Golden Hour":
            return StyleParams(saturation: 1.08, contrast: 0.95, exposure: 0.15,
                               warmth: 0.65, shadowLift: 0.07,
                               shadowR: 0.03, shadowG: 0.01,
                               highlightR: 0.025, highlightG: 0.01, highlightB: -0.02)
        case "Macro":
            return StyleParams(saturation: 0.94, contrast: 0.88, exposure: 0.05,
                               warmth: 0.14, shadowLift: 0.04)
        case "Architecture":
            return StyleParams(saturation: 0.82, contrast: 1.08, exposure: 0,
                               warmth: -0.22, shadowLift: 0.03,
                               shadowB: 0.01, highlightB: 0.005)
        // ── Mood ─────────────────────────────────────────────────────────────────
        case "Cinematic":
            return StyleParams(saturation: 0.88, contrast: 1.05, exposure: -0.08,
                               warmth: 0.08, shadowLift: 0.04,
                               shadowR: -0.04, shadowG: 0.01, shadowB: 0.06,
                               highlightR: 0.04, highlightG: 0.01, highlightB: -0.03)
        case "Faded Matte":
            return StyleParams(saturation: 0.72, contrast: 0.82, exposure: 0,
                               warmth: 0.05, shadowLift: 0.12)
        case "Punchy":
            return StyleParams(saturation: 1.20, contrast: 1.20, exposure: 0,
                               warmth: 0.10)
        case "Dreamy":
            return StyleParams(saturation: 0.68, contrast: 0.80, exposure: 0.10,
                               warmth: -0.08, shadowLift: 0.12,
                               highlightB: 0.018)
        case "Noir BW":
            return StyleParams(saturation: 0, contrast: 1.32, exposure: -0.12,
                               bwR: 0.25, bwG: 0.65, bwB: 0.10)
        case "Warm Fade":
            return StyleParams(saturation: 0.82, contrast: 0.86, exposure: 0.05,
                               warmth: 0.38, shadowLift: 0.10,
                               shadowR: 0.03, shadowG: 0.01, shadowB: -0.01)
        case "Cool Mist":
            return StyleParams(saturation: 0.62, contrast: 0.83, exposure: 0.05,
                               warmth: -0.32, shadowLift: 0.08,
                               shadowB: 0.02, highlightB: 0.02)
        default:
            return StyleParams()
        }
    }

    // MARK: - Transform

    static func apply(_ p: StyleParams, r: Float32, g: Float32, b: Float32) -> (Float32, Float32, Float32) {
        var r = r, g = g, b = b

        // 1. Exposure (stops)
        if p.exposure != 0 {
            let f = pow(2.0, p.exposure)
            r *= f; g *= f; b *= f
        }

        // 2. Shadow lift (raises blacks, reduces dynamic range at bottom)
        if p.shadowLift > 0 {
            let l = p.shadowLift
            r = r * (1 - l) + l
            g = g * (1 - l) + l
            b = b * (1 - l) + l
        }

        // 3. Contrast (S-curve approximated as linear stretch around 0.5)
        if p.contrast != 1.0 {
            r = (r - 0.5) * p.contrast + 0.5
            g = (g - 0.5) * p.contrast + 0.5
            b = (b - 0.5) * p.contrast + 0.5
        }

        // 4. Saturation / B&W desaturation
        if p.saturation == 0 {
            let luma = p.bwR * r + p.bwG * g + p.bwB * b
            r = luma; g = luma; b = luma
        } else if p.saturation != 1.0 {
            let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
            r = luma + (r - luma) * p.saturation
            g = luma + (g - luma) * p.saturation
            b = luma + (b - luma) * p.saturation
        }

        // 5. Warmth (shifts red–blue balance)
        if p.warmth != 0 {
            r += p.warmth * 0.07
            g += p.warmth * 0.015
            b -= p.warmth * 0.09
        }

        // 6. Tint (shifts green–magenta balance)
        if p.tint != 0 {
            r += p.tint * 0.03
            g -= p.tint * 0.04
            b += p.tint * 0.01
        }

        // 7. 3-way color grading in shadow / highlight regions
        let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let sw = max(0, 1 - luma * 4)          // 1 at black → 0 at luma 0.25
        let hw = max(0, (luma - 0.75) * 4)     // 0 at luma 0.75 → 1 at white
        r += sw * p.shadowR + hw * p.highlightR
        g += sw * p.shadowG + hw * p.highlightG
        b += sw * p.shadowB + hw * p.highlightB

        return (max(0, min(1, r)), max(0, min(1, g)), max(0, min(1, b)))
    }
}
