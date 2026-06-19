import Foundation

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

    // Crop / rotate
    var cropRect: CGRect?           // Normalized 0...1 crop rectangle; nil = full image
    var cropAspectRatio: CGFloat?   // Width / height; adapts to portrait source orientation
    var cropZoom: CGFloat = 1
    var cropCenterX: CGFloat = 0.5
    var cropCenterY: CGFloat = 0.5
    var rotationDegrees: Double = 0 // -45...+45, snaps to 0 on double-tap
    var quarterTurns: Int = 0
    var isFlippedHorizontally = false

    var isModified: Bool {
        exposure != 0 || contrast != 0 || shadows != 0 || highlights != 0
            || saturation != 0 || vibrance != 0 || warmth != 0 || sharpness != 0
            || vignette != 0 || rotationDegrees != 0 || quarterTurns != 0
            || isFlippedHorizontally || cropRect != nil || cropAspectRatio != nil
            || cropZoom != 1 || cropCenterX != 0.5 || cropCenterY != 0.5
    }
}
