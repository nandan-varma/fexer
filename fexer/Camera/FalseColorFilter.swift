import CoreImage

final class FalseColorFilter: CIFilter {
    var inputImage: CIImage?

    private static let kernel: CIKernel = {
        let source = """
        kernel vec4 falseColor(sampler src) {
            vec4 s = sample(src, samplerTransform(src, destCoord()));
            float luma = dot(s.rgb, vec3(0.2126, 0.7152, 0.0722));
            if (luma < 0.04)
                return vec4(0.0, 0.0, 0.7, 1.0);
            else if (luma < 0.12) {
                float t = (luma - 0.04) / 0.08;
                return mix(vec4(0.0, 0.0, 0.7, 1.0), vec4(0.0, 0.6, 0.85, 1.0), t);
            } else if (luma < 0.35) {
                float t = (luma - 0.12) / 0.23;
                return mix(vec4(0.0, 0.6, 0.85, 1.0), vec4(0.0, 0.75, 0.0, 1.0), t);
            } else if (luma < 0.55)
                return s;
            else if (luma < 0.72) {
                float t = (luma - 0.55) / 0.17;
                return mix(s, vec4(1.0, 0.85, 0.0, 1.0), t * 0.75);
            } else if (luma < 0.88) {
                float t = (luma - 0.72) / 0.16;
                return mix(vec4(1.0, 0.85, 0.0, 1.0), vec4(1.0, 0.3, 0.0, 1.0), t);
            } else
                return vec4(1.0, 0.0, 0.0, 1.0);
        }
        """
        guard let k = CIKernel.compileCIKL(source)
        else { fatalError("CIKernel 'falseColor' failed to compile") }
        return k
    }()

    override var outputImage: CIImage? {
        guard let input = inputImage else { return nil }
        return Self.kernel.apply(extent: input.extent,
                                 roiCallback: { _, rect in rect },
                                 arguments: [input])
    }
}
