import CoreImage

final class FocusPeakingFilter: CIFilter {
    var inputImage: CIImage?
    var inputThreshold: Float = 0.50
    var inputHighlightColor: CIColor = CIColor(red: 1, green: 0.2, blue: 0.2, alpha: 0.9)

    override var outputImage: CIImage? {
        guard let input = inputImage else { return nil }

        // CIEdges runs Apple's Sobel operator on GPU. inputIntensity scales the
        // output magnitude; 5× makes soft focus edges detectable at the default
        // threshold of 0.50 without overcrowding well-focused shots.
        let edges = input.applyingFilter("CIEdges",
                                         parameters: ["inputIntensity": NSNumber(value: 5.0)])

        let mask = edges.applyingFilter("CIColorThreshold",
                                         parameters: ["inputThreshold": NSNumber(value: inputThreshold)])

        let highlight = CIImage(color: inputHighlightColor).cropped(to: input.extent)

        return highlight.applyingFilter("CIBlendWithMask", parameters: [
            "inputBackgroundImage": input,
            "inputMaskImage": mask
        ])
    }
}
