import CoreImage

final class FocusPeakingFilter: CIFilter {
    var inputImage: CIImage?
    var inputHighlightColor: CIColor = CIColor(red: 1, green: 0.2, blue: 0.2, alpha: 0.9)

    // Tuning: CIEdges intensity controls how bright blurry edges appear.
    // At 4.0, only sharp/in-focus transitions produce output above the 0.5 mask threshold;
    // soft out-of-focus gradients stay below it and show nothing.
    private static let edgeIntensity: Double = 4.0
    private static let maskThreshold: Double = 0.5

    private lazy var edgesFilter = CIFilter(name: "CIEdges")
    private lazy var thresholdFilter = CIFilter(name: "CIColorThreshold")
    private lazy var blendFilter = CIFilter(name: "CIBlendWithMask")

    override var outputImage: CIImage? {
        guard let input = inputImage else { return nil }
        guard let edgesFilter, let thresholdFilter, let blendFilter else { return input }
        let extent = input.extent

        edgesFilter.setValue(input, forKey: kCIInputImageKey)
        edgesFilter.setValue(Self.edgeIntensity, forKey: kCIInputIntensityKey)
        guard let edges = edgesFilter.outputImage else { return input }

        thresholdFilter.setValue(edges, forKey: kCIInputImageKey)
        thresholdFilter.setValue(Self.maskThreshold, forKey: "inputThreshold")
        guard let mask = thresholdFilter.outputImage else { return input }

        let highlight = CIImage(color: inputHighlightColor).cropped(to: extent)
        blendFilter.setValue(highlight, forKey: kCIInputImageKey)
        blendFilter.setValue(input, forKey: "inputBackgroundImage")
        blendFilter.setValue(mask, forKey: "inputMaskImage")
        return blendFilter.outputImage ?? input
    }
}
