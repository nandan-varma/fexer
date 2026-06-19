import Foundation

/// Non-destructive edit adjustments applied in ReviewView before saving.
struct EditState: Equatable {
    var exposure: Float    = 0      // CIExposureAdjust inputEV, -2...+2
    var contrast: Float    = 0      // CIColorControls inputContrast delta, -0.5...+0.5
    var shadows: Float     = 0      // CIHighlightShadowAdjust inputShadowAmount, -1...+1
    var highlights: Float  = 0      // CIHighlightShadowAdjust inputHighlightAmount, -1...+1
    var saturation: Float  = 0      // CIColorControls inputSaturation delta, -1...+1
    var warmth: Float      = 0      // CITemperatureAndTint shift, -1...+1

    // Crop / rotate
    var cropRect: CGRect?           // nil = no crop (full image)
    var rotationDegrees: Double = 0 // -45...+45, snaps to 0 on double-tap

    var isModified: Bool {
        exposure != 0 || contrast != 0 || shadows != 0 || highlights != 0
            || saturation != 0 || warmth != 0 || rotationDegrees != 0 || cropRect != nil
    }
}
