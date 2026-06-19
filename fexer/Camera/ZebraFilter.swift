import CoreImage

final class ZebraFilter: CIFilter {
    var inputImage: CIImage?
    var inputOverThreshold: Float = 0.95
    var inputUnderThreshold: Float = 0.02
    var inputTime: Float = 0.0
    var inputStripeWidth: Float = 12.0

    override var outputImage: CIImage? {
        guard let input = inputImage else { return nil }
        let extent = input.extent

        // Over-exposure mask: white where luminance exceeds the threshold.
        let overMask = input.applyingFilter("CIColorThreshold", parameters: [
            "inputThreshold": NSNumber(value: inputOverThreshold)
        ])

        // Under-exposure mask: white where luminance is below the threshold.
        // CIColorThreshold only detects *above* threshold, so threshold at underThreshold
        // then invert via CIColorMatrix (rgb = 1-rgb, alpha forced to 1 to avoid
        // premultiplied-alpha edge cases from CIColorInvert).
        let underMask = input
            .applyingFilter("CIColorThreshold", parameters: [
                "inputThreshold": NSNumber(value: inputUnderThreshold)
            ])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector":    CIVector(x: -1, y:  0, z:  0, w: 0),
                "inputGVector":    CIVector(x:  0, y: -1, z:  0, w: 0),
                "inputBVector":    CIVector(x:  0, y:  0, z: -1, w: 0),
                "inputAVector":    CIVector(x:  0, y:  0, z:  0, w: 0),
                "inputBiasVector": CIVector(x:  1, y:  1, z:  1, w: 1)
            ])

        // Animated diagonal stripe pattern.
        // CIStripesGenerator makes horizontal stripes; rotating -45° makes them diagonal.
        // Translating the output image in y before rotation shifts the stripe phase,
        // which is the animation. inputStripeWidth sets visual stripe width directly
        // because the 45° rotation preserves apparent stripe width.
        let stripeTransform = CGAffineTransform(translationX: 0, y: CGFloat(inputTime))
            .rotated(by: -.pi / 4)
        guard let stripeOutput = CIFilter(name: "CIStripesGenerator", parameters: [
            "inputColor0":    CIColor.white,
            "inputColor1":    CIColor.black,
            "inputWidth":     NSNumber(value: CGFloat(inputStripeWidth)),
            "inputSharpness": NSNumber(value: 1.0)
        ])?.outputImage else { return input }
        let stripes = stripeOutput.transformed(by: stripeTransform).cropped(to: extent)

        // AND each exposure mask with the stripe pattern (per-channel min = logical AND
        // for binary B&W images).
        let overStripes  = overMask.applyingFilter("CIMinimumCompositing",
                                                    parameters: ["inputBackgroundImage": stripes])
        let underStripes = underMask.applyingFilter("CIMinimumCompositing",
                                                     parameters: ["inputBackgroundImage": stripes])

        // Composite warning colors over the original using the masked stripe regions.
        let red  = CIImage(color: CIColor(red: 1,   green: 0,   blue: 0  )).cropped(to: extent)
        let blue = CIImage(color: CIColor(red: 0,   green: 0.4, blue: 1  )).cropped(to: extent)

        let withOver = red.applyingFilter("CIBlendWithMask", parameters: [
            "inputBackgroundImage": input,
            "inputMaskImage":       overStripes
        ])
        return blue.applyingFilter("CIBlendWithMask", parameters: [
            "inputBackgroundImage": withOver,
            "inputMaskImage":       underStripes
        ])
    }
}
