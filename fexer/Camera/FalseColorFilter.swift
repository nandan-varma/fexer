import CoreImage

/// Maps luminance bands to distinct false colors for exposure monitoring.
/// Blue = crushed blacks, cyan = shadows, green = lower mids,
/// passthrough = midtones, yellow = upper mids, orange = near-clip, red = blown.
final class FalseColorFilter: CIFilter {
    var inputImage: CIImage?

    private static let kernel: CIColorKernel? = {
        let source = """
        kernel vec4 falseColor(sampler src) {
            vec2 d = destCoord();
            vec4 c = sample(src, samplerTransform(src, d));
            float luma = dot(c.rgb, vec3(0.2126, 0.7152, 0.0722));
            vec4 out;
            if (luma < 0.04) {
                out = vec4(0.0, 0.0, 0.7, 1.0);
            } else if (luma < 0.12) {
                float t = (luma - 0.04) / 0.08;
                out = mix(vec4(0.0, 0.0, 0.7, 1.0), vec4(0.0, 0.6, 0.85, 1.0), t);
            } else if (luma < 0.35) {
                float t = (luma - 0.12) / 0.23;
                out = mix(vec4(0.0, 0.6, 0.85, 1.0), vec4(0.0, 0.75, 0.0, 1.0), t);
            } else if (luma < 0.55) {
                out = c;
            } else if (luma < 0.72) {
                float t = (luma - 0.55) / 0.17;
                out = mix(c, vec4(1.0, 0.85, 0.0, 1.0), t * 0.75);
            } else if (luma < 0.88) {
                float t = (luma - 0.72) / 0.16;
                out = mix(vec4(1.0, 0.85, 0.0, 1.0), vec4(1.0, 0.3, 0.0, 1.0), t);
            } else {
                out = vec4(1.0, 0.0, 0.0, 1.0);
            }
            return out;
        }
        """
        return CIColorKernel(source: source)
    }()

    override var outputImage: CIImage? {
        guard let input = inputImage, let kernel = Self.kernel else { return inputImage }
        return kernel.apply(extent: input.extent, arguments: [input])
    }
}
