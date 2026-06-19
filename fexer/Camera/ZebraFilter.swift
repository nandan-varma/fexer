import CoreImage

final class ZebraFilter: CIFilter {
    var inputImage: CIImage?
    var inputOverThreshold: Float = 0.95
    var inputUnderThreshold: Float = 0.02
    var inputTime: Float = 0.0
    var inputStripeWidth: Float = 12.0

    private static let kernel: CIKernel = {
        let source = """
        kernel vec4 zebraStripes(sampler src, float overThreshold, float underThreshold,
                                 float time, float stripeWidth) {
            vec2 d = destCoord();
            vec4 s = sample(src, samplerTransform(src, d));
            float luma = dot(s.rgb, vec3(0.299, 0.587, 0.114));
            if (luma > overThreshold || luma < underThreshold) {
                float stripe = mod(d.x + d.y + time, stripeWidth * 2.0);
                vec4 warningColor = luma > overThreshold
                                     ? vec4(1.0, 0.0, 0.0, 1.0)
                                     : vec4(0.0, 0.4, 1.0, 1.0);
                return stripe < stripeWidth ? warningColor : vec4(0.0, 0.0, 0.0, 1.0);
            }
            return s;
        }
        """
        guard let k = CIKernel.compileCIKL(source)
        else { fatalError("CIKernel 'zebraStripes' failed to compile") }
        return k
    }()

    override var outputImage: CIImage? {
        guard let input = inputImage else { return nil }
        return Self.kernel.apply(
            extent: input.extent,
            roiCallback: { _, rect in rect },
            arguments: [input, inputOverThreshold, inputUnderThreshold, inputTime, inputStripeWidth]
        )
    }
}
