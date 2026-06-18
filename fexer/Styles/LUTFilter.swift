import CoreImage

final class LUTFilter: CIFilter {
    var inputImage: CIImage?
    var inputIntensity: Float = 1.0

    private var lutData: NSData?
    private var lutDimension: Int = 33
    private var styleName: String = ""

    // Cached filter instances — created once, parameters updated per frame
    private lazy var colorCubeFilter: CIFilter = CIFilter(name: "CIColorCubeWithColorSpace")!
    private lazy var dissolveFilter: CIFilter  = CIFilter(name: "CIDissolveTransition")!
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    func setStyle(name: String, data: NSData, dimension: Int) {
        // Only update if style changed — keeps GPU texture cached by pointer identity
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

        colorCubeFilter.setValue(input, forKey: "inputImage")
        colorCubeFilter.setValue(lutDimension, forKey: "inputCubeDimension")
        colorCubeFilter.setValue(lut, forKey: "inputCubeData")
        colorCubeFilter.setValue(LUTFilter.sRGB, forKey: "inputColorSpace")

        guard let lutOutput = colorCubeFilter.outputImage else { return input }

        if inputIntensity >= 0.999 { return lutOutput }

        // Blend between original and LUT-applied at the given intensity
        dissolveFilter.setValue(input, forKey: "inputImage")
        dissolveFilter.setValue(lutOutput, forKey: "inputTargetImage")
        dissolveFilter.setValue(inputIntensity, forKey: "inputTime")

        return dissolveFilter.outputImage ?? lutOutput
    }
}
