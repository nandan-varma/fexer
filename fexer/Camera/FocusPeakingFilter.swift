import CoreImage

final class FocusPeakingFilter: CIFilter {
    var inputImage: CIImage?
    var inputThreshold: Float = 0.15
    var inputHighlightColor: CIColor = CIColor(red: 1, green: 0.2, blue: 0.2, alpha: 0.85)

    private static let kernel: CIColorKernel? = {
        // Luminance Sobel-edge detection to identify in-focus areas.
        // Runs at half resolution (caller downscales first).
        let source = """
        kernel vec4 focusPeaking(sampler src, float threshold, vec4 highlightColor) {
            vec2 d = destCoord();
            vec4 center = sample(src, samplerTransform(src, d));
            vec4 right  = sample(src, samplerTransform(src, d + vec2(1.0, 0.0)));
            vec4 up     = sample(src, samplerTransform(src, d + vec2(0.0, 1.0)));
            float lumCenter = dot(center.rgb, vec3(0.299, 0.587, 0.114));
            float lumRight  = dot(right.rgb,  vec3(0.299, 0.587, 0.114));
            float lumUp     = dot(up.rgb,     vec3(0.299, 0.587, 0.114));
            float mag = sqrt(pow(lumRight - lumCenter, 2.0) + pow(lumUp - lumCenter, 2.0));
            if (mag > threshold) {
                return mix(center, highlightColor, highlightColor.a);
            }
            return center;
        }
        """
        return CIColorKernel(source: source)
    }()

    override var outputImage: CIImage? {
        guard let input = inputImage else { return nil }

        // Half-resolution for performance
        let scale = 0.5
        guard let small = CIFilter(name: "CILanczosScaleTransform",
                                   parameters: ["inputImage": input,
                                                "inputScale": scale,
                                                "inputAspectRatio": 1.0])?.outputImage
        else { return input }

        let colorVec = CIVector(x: CGFloat(inputHighlightColor.red),
                                y: CGFloat(inputHighlightColor.green),
                                z: CGFloat(inputHighlightColor.blue),
                                w: CGFloat(inputHighlightColor.alpha))

        guard let kernel = Self.kernel,
              let peaked = kernel.apply(extent: small.extent,
                                        arguments: [small, inputThreshold, colorVec])
        else { return input }

        // Scale back to full resolution and composite
        guard let full = CIFilter(name: "CILanczosScaleTransform",
                                  parameters: ["inputImage": peaked,
                                               "inputScale": 1.0 / scale,
                                               "inputAspectRatio": 1.0])?.outputImage
        else { return input }

        return full.composited(over: input)
    }
}
