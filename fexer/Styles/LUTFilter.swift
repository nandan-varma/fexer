import CoreImage

final class LUTFilter: CIFilter {
    var inputImage: CIImage?
    var inputIntensity: Float = 1.0

    private var lutData: NSData?
    private var lutDimension: Int = 33
    private var styleName: String = ""

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

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

        guard let lutFilter = CIFilter(name: "CIColorCubeWithColorSpace",
                                        parameters: [
                                            "inputImage": input,
                                            "inputCubeDimension": lutDimension,
                                            "inputCubeData": lut,
                                            "inputColorSpace": colorSpace
                                        ]),
              let lutOutput = lutFilter.outputImage
        else { return input }

        if inputIntensity >= 0.999 { return lutOutput }

        // Blend between original and LUT-applied at the given intensity
        guard let blendFilter = CIFilter(name: "CIDissolveTransition",
                                          parameters: [
                                            "inputImage": input,
                                            "inputTargetImage": lutOutput,
                                            "inputTime": inputIntensity
                                          ]),
              let blended = blendFilter.outputImage
        else { return lutOutput }

        return blended
    }
}
