import CoreImage

final class FocusPeakingFilter: CIFilter {
    var inputImage: CIImage?
    var inputThreshold: Float = 0.50
    var inputHighlightColor: CIColor = CIColor(red: 1, green: 0.2, blue: 0.2, alpha: 0.9)

    private static let kernel: CIKernel = {
        let source = """
        kernel vec4 focusPeaking(sampler src, float threshold, vec4 highlightColor) {
            vec2 d = destCoord();
            vec3 lumaWeights = vec3(0.2126, 0.7152, 0.0722);

            float l00 = dot(sample(src, samplerTransform(src, d + vec2(-1.0, -1.0))).rgb, lumaWeights);
            float l10 = dot(sample(src, samplerTransform(src, d + vec2( 0.0, -1.0))).rgb, lumaWeights);
            float l20 = dot(sample(src, samplerTransform(src, d + vec2( 1.0, -1.0))).rgb, lumaWeights);
            float l01 = dot(sample(src, samplerTransform(src, d + vec2(-1.0,  0.0))).rgb, lumaWeights);
            float l21 = dot(sample(src, samplerTransform(src, d + vec2( 1.0,  0.0))).rgb, lumaWeights);
            float l02 = dot(sample(src, samplerTransform(src, d + vec2(-1.0,  1.0))).rgb, lumaWeights);
            float l12 = dot(sample(src, samplerTransform(src, d + vec2( 0.0,  1.0))).rgb, lumaWeights);
            float l22 = dot(sample(src, samplerTransform(src, d + vec2( 1.0,  1.0))).rgb, lumaWeights);

            float gx = -l00 + l20 - 2.0*l01 + 2.0*l21 - l02 + l22;
            float gy = -l00 - 2.0*l10 - l20 + l02 + 2.0*l12 + l22;
            float mag = sqrt(gx*gx + gy*gy);

            vec4 center = sample(src, samplerTransform(src, d));
            float alpha = smoothstep(threshold * 0.5, threshold, mag) * highlightColor.a;
            return mix(center, vec4(highlightColor.rgb, 1.0), alpha);
        }
        """
        guard let k = CIKernel.compileCIKL(source)
        else { fatalError("CIKernel 'focusPeaking' failed to compile") }
        return k
    }()

    override var outputImage: CIImage? {
        guard let input = inputImage else { return nil }

        let colorVec = CIVector(x: CGFloat(inputHighlightColor.red),
                                y: CGFloat(inputHighlightColor.green),
                                z: CGFloat(inputHighlightColor.blue),
                                w: CGFloat(inputHighlightColor.alpha))

        return Self.kernel.apply(
            extent: input.extent,
            roiCallback: { _, rect in rect.insetBy(dx: -1, dy: -1) },
            arguments: [input, inputThreshold, colorVec]
        )
    }
}
