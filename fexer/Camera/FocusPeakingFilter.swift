import CoreImage

final class FocusPeakingFilter: CIFilter {
    var inputImage: CIImage?
    var inputThreshold: Float = 0.50
    var inputHighlightColor: CIColor = CIColor(red: 1, green: 0.2, blue: 0.2, alpha: 0.9)

    // CIKernel (not CIColorKernel) — neighbor sampling requires the general-purpose kernel.
    // CIColorKernel enforces single-pixel isolation and rejects kernels that read neighbors.
    private static let kernel: CIKernel? = {
        let source = """
        kernel vec4 focusPeaking(sampler src, float threshold, vec4 highlightColor) {
            vec2 d = destCoord();
            vec3 luma = vec3(0.2126, 0.7152, 0.0722);

            float l00 = dot(sample(src, samplerTransform(src, d + vec2(-1.0,-1.0))).rgb, luma);
            float l10 = dot(sample(src, samplerTransform(src, d + vec2( 0.0,-1.0))).rgb, luma);
            float l20 = dot(sample(src, samplerTransform(src, d + vec2( 1.0,-1.0))).rgb, luma);
            float l01 = dot(sample(src, samplerTransform(src, d + vec2(-1.0, 0.0))).rgb, luma);
            float l21 = dot(sample(src, samplerTransform(src, d + vec2( 1.0, 0.0))).rgb, luma);
            float l02 = dot(sample(src, samplerTransform(src, d + vec2(-1.0, 1.0))).rgb, luma);
            float l12 = dot(sample(src, samplerTransform(src, d + vec2( 0.0, 1.0))).rgb, luma);
            float l22 = dot(sample(src, samplerTransform(src, d + vec2( 1.0, 1.0))).rgb, luma);

            float gx = -l00 + l20 - 2.0*l01 + 2.0*l21 - l02 + l22;
            float gy = -l00 - 2.0*l10 - l20 + l02 + 2.0*l12 + l22;
            float mag = sqrt(gx*gx + gy*gy);

            vec4 center = sample(src, samplerTransform(src, d));
            float alpha = smoothstep(threshold * 0.5, threshold, mag) * highlightColor.a;
            return mix(center, vec4(highlightColor.rgb, 1.0), alpha);
        }
        """
        return CIKernel(source: source)
    }()

    override var outputImage: CIImage? {
        guard let input = inputImage, let kernel = Self.kernel else { return inputImage }

        let colorVec = CIVector(x: CGFloat(inputHighlightColor.red),
                                y: CGFloat(inputHighlightColor.green),
                                z: CGFloat(inputHighlightColor.blue),
                                w: CGFloat(inputHighlightColor.alpha))

        return kernel.apply(
            extent: input.extent,
            roiCallback: { _, rect in rect.insetBy(dx: -1, dy: -1) },
            arguments: [CISampler(image: input), inputThreshold, colorVec]
        )
    }
}
