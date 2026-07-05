import CoreImage

final class ZebraFilter: CIFilter {
    var inputImage: CIImage?
    var inputOverThreshold: Float = 0.95
    var inputUnderThreshold: Float = 0.02
    var inputTime: Float = 0.0
    var inputStripeWidth: Float = 12.0

    // Cached CIFilter instances (all sessionQueue-only, no thread-safety concern)
    private lazy var overThresholdFilter = CIFilter(name: "CIColorThreshold")
    private lazy var underThresholdFilter = CIFilter(name: "CIColorThreshold")
    private lazy var invertFilter: CIFilter? = {
        let f = CIFilter(name: "CIColorMatrix")
        f?.setValue(CIVector(x: -1, y:  0, z:  0, w: 0), forKey: "inputRVector")
        f?.setValue(CIVector(x:  0, y: -1, z:  0, w: 0), forKey: "inputGVector")
        f?.setValue(CIVector(x:  0, y:  0, z: -1, w: 0), forKey: "inputBVector")
        f?.setValue(CIVector(x:  0, y:  0, z:  0, w: 0), forKey: "inputAVector")
        f?.setValue(CIVector(x:  1, y:  1, z:  1, w: 1), forKey: "inputBiasVector")
        return f
    }()
    private lazy var stripesGenerator: CIFilter? = {
        let f = CIFilter(name: "CIStripesGenerator")
        f?.setValue(CIColor.white, forKey: "inputColor0")
        f?.setValue(CIColor.black, forKey: "inputColor1")
        f?.setValue(1.0, forKey: "inputSharpness")
        return f
    }()
    private lazy var minCompositingA = CIFilter(name: "CIMinimumCompositing")
    private lazy var minCompositingB = CIFilter(name: "CIMinimumCompositing")
    private lazy var blendOverFilter = CIFilter(name: "CIBlendWithMask")
    private lazy var blendUnderFilter = CIFilter(name: "CIBlendWithMask")

    override var outputImage: CIImage? {
        guard let input = inputImage else { return nil }
        guard let overThresholdFilter, let underThresholdFilter, let invertFilter,
              let stripesGenerator, let minCompositingA, let minCompositingB,
              let blendOverFilter, let blendUnderFilter else { return input }
        let extent = input.extent

        // Over-exposure mask: white where luminance exceeds the threshold.
        overThresholdFilter.setValue(input, forKey: kCIInputImageKey)
        overThresholdFilter.setValue(inputOverThreshold, forKey: "inputThreshold")
        guard let overMask = overThresholdFilter.outputImage else { return input }

        // Under-exposure mask: threshold then invert.
        underThresholdFilter.setValue(input, forKey: kCIInputImageKey)
        underThresholdFilter.setValue(inputUnderThreshold, forKey: "inputThreshold")
        guard let underRaw = underThresholdFilter.outputImage else { return input }
        invertFilter.setValue(underRaw, forKey: kCIInputImageKey)
        guard let underMask = invertFilter.outputImage else { return input }

        // Animated diagonal stripe pattern.
        let stripeTransform = CGAffineTransform(translationX: 0, y: CGFloat(inputTime))
            .rotated(by: -.pi / 4)
        stripesGenerator.setValue(CGFloat(inputStripeWidth), forKey: "inputWidth")
        guard var stripes = stripesGenerator.outputImage else { return input }
        stripes = stripes.transformed(by: stripeTransform).cropped(to: extent)

        // AND each exposure mask with the stripe pattern.
        minCompositingA.setValue(overMask, forKey: kCIInputImageKey)
        minCompositingA.setValue(stripes, forKey: "inputBackgroundImage")
        guard let overStripes = minCompositingA.outputImage else { return input }
        minCompositingB.setValue(underMask, forKey: kCIInputImageKey)
        minCompositingB.setValue(stripes, forKey: "inputBackgroundImage")
        guard let underStripes = minCompositingB.outputImage else { return input }

        // Composite warning colors.
        let red  = CIImage(color: CIColor(red: 1,   green: 0,   blue: 0  )).cropped(to: extent)
        let blue = CIImage(color: CIColor(red: 0,   green: 0.4, blue: 1  )).cropped(to: extent)

        blendOverFilter.setValue(red, forKey: kCIInputImageKey)
        blendOverFilter.setValue(input, forKey: "inputBackgroundImage")
        blendOverFilter.setValue(overStripes, forKey: "inputMaskImage")
        guard let withOver = blendOverFilter.outputImage else { return input }

        blendUnderFilter.setValue(blue, forKey: kCIInputImageKey)
        blendUnderFilter.setValue(withOver, forKey: "inputBackgroundImage")
        blendUnderFilter.setValue(underStripes, forKey: "inputMaskImage")
        return blendUnderFilter.outputImage ?? input
    }
}
