import Foundation

/// HSL adjustment for a single hue band (reds, oranges, yellows, greens, aquas, blues, purples, magentas).
struct HSLBand: Equatable {
    var hue: Float        = 0   // shift in degrees, -180...+180
    var saturation: Float = 0   // delta, -1...+1
    var luminance: Float  = 0   // delta, -1...+1

    nonisolated var isNonZero: Bool { hue != 0 || saturation != 0 || luminance != 0 }
}

/// Non-destructive edit adjustments applied in ReviewView before saving.
struct EditState: Equatable {
    var exposure: Float    = 0      // CIExposureAdjust inputEV, -2...+2
    var contrast: Float    = 0      // CIColorControls inputContrast delta, -0.5...+0.5
    var shadows: Float     = 0      // CIHighlightShadowAdjust inputShadowAmount, -1...+1
    var highlights: Float  = 0      // CIHighlightShadowAdjust inputHighlightAmount, -1...+1
    var saturation: Float  = 0      // CIColorControls inputSaturation delta, -1...+1
    var vibrance: Float    = 0      // CIVibrance inputAmount, -1...+1
    var warmth: Float      = 0      // CITemperatureAndTint shift, -1...+1
    var sharpness: Float   = 0      // CISharpenLuminance inputSharpness, 0...1
    var vignette: Float    = 0      // CIVignette inputIntensity, 0...1

    // HSL per-color mixer (8 hue bands)
    var hslRed:     HSLBand = HSLBand()
    var hslOrange:  HSLBand = HSLBand()
    var hslYellow:  HSLBand = HSLBand()
    var hslGreen:   HSLBand = HSLBand()
    var hslAqua:    HSLBand = HSLBand()
    var hslBlue:    HSLBand = HSLBand()
    var hslPurple:  HSLBand = HSLBand()
    var hslMagenta: HSLBand = HSLBand()

    // Per-channel tone curves: 5 control points each, x in 0…1, y in 0…1
    // Default is identity: [(0,0),(0.25,0.25),(0.5,0.5),(0.75,0.75),(1,1)]
    var curveR: [SIMD2<Float>] = EditState.identityCurve
    var curveG: [SIMD2<Float>] = EditState.identityCurve
    var curveB: [SIMD2<Float>] = EditState.identityCurve
    var curveMaster: [SIMD2<Float>] = EditState.identityCurve

    // Custom imported LUT (file URL as bookmark data)
    var importedLUTBookmark: Data? = nil

    // Crop / rotate
    var cropRect: CGRect?           // Normalized 0...1 crop rectangle; nil = full image
    var cropAspectRatio: CGFloat?   // Width / height; adapts to portrait source orientation
    var cropZoom: CGFloat = 1
    var cropCenterX: CGFloat = 0.5
    var cropCenterY: CGFloat = 0.5
    var rotationDegrees: Double = 0 // -45...+45, snaps to 0 on double-tap
    var quarterTurns: Int = 0
    var isFlippedHorizontally = false

    nonisolated var isModified: Bool {
        exposure != 0 || contrast != 0 || shadows != 0 || highlights != 0
            || saturation != 0 || vibrance != 0 || warmth != 0 || sharpness != 0
            || vignette != 0 || rotationDegrees != 0 || quarterTurns != 0
            || isFlippedHorizontally || cropRect != nil || cropAspectRatio != nil
            || cropZoom != 1 || cropCenterX != 0.5 || cropCenterY != 0.5
            || hasHSLAdjustments || hasCurveAdjustments || importedLUTBookmark != nil
    }

    nonisolated var hasHSLAdjustments: Bool {
        hslRed.isNonZero || hslOrange.isNonZero || hslYellow.isNonZero || hslGreen.isNonZero
            || hslAqua.isNonZero || hslBlue.isNonZero || hslPurple.isNonZero || hslMagenta.isNonZero
    }

    nonisolated var hasCurveAdjustments: Bool {
        curveR != EditState.identityCurve || curveG != EditState.identityCurve
            || curveB != EditState.identityCurve || curveMaster != EditState.identityCurve
    }

    nonisolated static let identityCurve: [SIMD2<Float>] = [
        SIMD2(0, 0), SIMD2(0.25, 0.25), SIMD2(0.5, 0.5), SIMD2(0.75, 0.75), SIMD2(1, 1)
    ]

    nonisolated var allHSLBands: [(String, WritableKeyPath<EditState, HSLBand>)] {
        [("Red",     \.hslRed),     ("Orange",  \.hslOrange),
         ("Yellow",  \.hslYellow),  ("Green",   \.hslGreen),
         ("Aqua",    \.hslAqua),    ("Blue",    \.hslBlue),
         ("Purple",  \.hslPurple),  ("Magenta", \.hslMagenta)]
    }
}
