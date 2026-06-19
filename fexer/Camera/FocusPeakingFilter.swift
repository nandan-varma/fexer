import CoreImage

final class FocusPeakingFilter: CIFilter {
    var inputImage: CIImage?
    var inputHighlightColor: CIColor = CIColor(red: 1, green: 0.2, blue: 0.2, alpha: 0.9)

    // Tuning: CIEdges intensity controls how bright blurry edges appear.
    // At 4.0, only sharp/in-focus transitions produce output above the 0.5 mask threshold;
    // soft out-of-focus gradients stay below it and show nothing.
    private static let edgeIntensity: Double = 4.0
    private static let maskThreshold: Double = 0.5

    override var outputImage: CIImage? {
        guard let input = inputImage else { return nil }
        let extent = input.extent

        // CIEdges computes gradient magnitude per-channel: sharp transitions → bright,
        // blurry transitions (out-of-focus areas) → dim. This is the right discriminator
        // for focus peaking — sharpness, not contrast.
        let edges = input.applyingFilter("CIEdges", parameters: [
            kCIInputIntensityKey: NSNumber(value: Self.edgeIntensity)
        ])

        // Hard threshold: pixels bright enough to represent genuine in-focus sharpness
        // become white (pass), soft/blurry areas become black (suppress).
        let mask = edges.applyingFilter("CIColorThreshold", parameters: [
            "inputThreshold": NSNumber(value: Self.maskThreshold)
        ])

        // Composite the highlight colour only where the mask is white.
        let highlight = CIImage(color: inputHighlightColor).cropped(to: extent)
        return highlight.applyingFilter("CIBlendWithMask", parameters: [
            "inputBackgroundImage": input,
            "inputMaskImage": mask
        ])
    }
}
