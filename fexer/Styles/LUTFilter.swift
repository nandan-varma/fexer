import CoreImage

final class LUTFilter: CIFilter {
    var inputImage: CIImage?
    var inputIntensity: Float = 1.0

    // Set true when the active style has saturation == 0 — skips dissolve so no color bleeds back in
    var isBW: Bool = false

    // Per-frame adjustment deltas applied after the LUT (0 = no change from style default)
    var adjExposure: Float = 0      // EV stops, -1.5 … +1.5
    var adjContrast: Float = 0      // delta around 1.0, -0.5 … +0.5
    var adjSaturation: Float = 0    // delta around 1.0, -1.0 … +1.0 (ignored for BW)
    var adjWarmth: Float = 0        // -1 = cool, +1 = warm

    private var lutData: NSData?
    private var lutDimension: Int = 33
    private var styleName: String = ""

    private lazy var colorCubeFilter: CIFilter    = CIFilter(name: "CIColorCubeWithColorSpace")!
    private lazy var dissolveFilter: CIFilter      = CIFilter(name: "CIDissolveTransition")!
    private lazy var exposureFilter: CIFilter      = CIFilter(name: "CIExposureAdjust")!
    private lazy var colorControlsFilter: CIFilter = CIFilter(name: "CIColorControls")!
    private lazy var tempTintFilter: CIFilter      = CIFilter(name: "CITemperatureAndTint")!

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    // D65 reference neutral for CITemperatureAndTint
    private static let neutralD65 = CIVector(x: 6500, y: 0)

    func setStyle(name: String, data: NSData, dimension: Int) {
        if name != styleName {
            lutData = data
            lutDimension = dimension
            styleName = name
        }
    }

    func clearStyle() {
        lutData = nil
        styleName = ""
    }

    override var outputImage: CIImage? {
        guard let input = inputImage else { return nil }
        guard let lut = lutData, inputIntensity > 0.001 else { return input }

        colorCubeFilter.setValue(input,          forKey: "inputImage")
        colorCubeFilter.setValue(lutDimension,   forKey: "inputCubeDimension")
        colorCubeFilter.setValue(lut,            forKey: "inputCubeData")
        colorCubeFilter.setValue(LUTFilter.sRGB, forKey: "inputColorSpace")

        guard let lutOutput = colorCubeFilter.outputImage else { return input }

        // B&W styles bypass the dissolve entirely — blending color back in causes the BW bleed.
        // Non-BW styles blend at styleIntensity to allow partial application.
        var blended: CIImage
        if isBW || inputIntensity >= 0.999 {
            blended = lutOutput
        } else {
            dissolveFilter.setValue(input,          forKey: "inputImage")
            dissolveFilter.setValue(lutOutput,      forKey: "inputTargetImage")
            dissolveFilter.setValue(inputIntensity, forKey: "inputTime")
            blended = dissolveFilter.outputImage ?? lutOutput
        }

        // Post-LUT adjustments
        var result = blended

        if adjExposure != 0 {
            exposureFilter.setValue(result,      forKey: "inputImage")
            exposureFilter.setValue(adjExposure, forKey: "inputEV")
            result = exposureFilter.outputImage ?? result
        }

        let targetSat = isBW ? 1.0 : Float(1.0 + adjSaturation)
        if adjContrast != 0 || (!isBW && adjSaturation != 0) {
            colorControlsFilter.setValue(result,                 forKey: "inputImage")
            colorControlsFilter.setValue(targetSat,             forKey: "inputSaturation")
            colorControlsFilter.setValue(0.0,                   forKey: "inputBrightness")
            colorControlsFilter.setValue(1.0 + adjContrast,     forKey: "inputContrast")
            result = colorControlsFilter.outputImage ?? result
        }

        // CITemperatureAndTint: inputTargetNeutral > 6500 warms; < 6500 cools.
        if adjWarmth != 0 {
            let targetTemp = CGFloat(6500 + adjWarmth * 3000)
            tempTintFilter.setValue(result,                                  forKey: "inputImage")
            tempTintFilter.setValue(LUTFilter.neutralD65,                    forKey: "inputNeutral")
            tempTintFilter.setValue(CIVector(x: targetTemp, y: 0),          forKey: "inputTargetNeutral")
            result = tempTintFilter.outputImage ?? result
        }

        return result
    }
}
