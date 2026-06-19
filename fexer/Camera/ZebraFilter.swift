import CoreImage

final class ZebraFilter: CIFilter {
    var inputImage: CIImage?
    var inputOverThreshold: Float = 0.95
    var inputUnderThreshold: Float = 0.02
    var inputTime: Float = 0.0
    var inputStripeWidth: Float = 12.0

    private static let kernel: CIColorKernel? = {
        let source = """
        kernel vec4 zebraStripes(sampler src, float overThreshold, float underThreshold, float time, float stripeWidth) {
            vec2 d = destCoord();
            vec4 color = sample(src, samplerTransform(src, d));
            float luma = dot(color.rgb, vec3(0.299, 0.587, 0.114));
            bool isOver  = luma > overThreshold;
            bool isUnder = luma < underThreshold;
            if (isOver || isUnder) {
                float stripe = mod(d.x + d.y + time, stripeWidth * 2.0);
                vec4 warningColor = isOver ? vec4(1.0, 0.0, 0.0, 1.0) : vec4(0.0, 0.4, 1.0, 1.0);
                vec4 altColor = vec4(0.0, 0.0, 0.0, 1.0);
                return stripe < stripeWidth ? warningColor : altColor;
            }
            return color;
        }
        """
        return CIColorKernel(source: source)
    }()

    override var outputImage: CIImage? {
        guard let input = inputImage,
              let kernel = Self.kernel
        else { return inputImage }

        return kernel.apply(
            extent: input.extent,
            arguments: [input, inputOverThreshold, inputUnderThreshold, inputTime, inputStripeWidth]
        )
    }
}
