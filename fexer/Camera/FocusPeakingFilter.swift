import CoreImage
import OSLog

final class FocusPeakingFilter: CIFilter {
    var inputImage: CIImage?
    // Lower threshold catches gradual curved-surface edges; raise to reduce noise in busy shots.
    var inputThreshold: Float = 0.08
    var inputHighlightColor: CIColor = CIColor(red: 1, green: 0.2, blue: 0.2, alpha: 0.9)

    // Laplacian kernel [-1,-1,-1; -1,8,-1; -1,-1,-1] applied to luminance.
    // Unlike Sobel (first derivative), the Laplacian is the second derivative and is
    // rotation-invariant — it responds equally to edges on curved surfaces (cups, faces)
    // and straight lines (text), which is what real camera focus peaking does.
    private static let kernel: CIKernel? = {
        let source = """
        #include <CoreImage/CoreImage.h>
        using namespace metal;

        [[stitchable]] float4 focusPeaking(
            coreimage::sampler src,
            float threshold,
            float4 highlightColor
        ) {
            float2 c = src.coord();

            // Sample 3x3 neighborhood at 1-pixel offsets in working space.
            float3 luma = float3(0.2126, 0.7152, 0.0722);
            float l00 = dot(src.sample(c + float2(-1,-1)).rgb, luma);
            float l10 = dot(src.sample(c + float2( 0,-1)).rgb, luma);
            float l20 = dot(src.sample(c + float2( 1,-1)).rgb, luma);
            float l01 = dot(src.sample(c + float2(-1, 0)).rgb, luma);
            float l11 = dot(src.sample(c               ).rgb, luma);
            float l21 = dot(src.sample(c + float2( 1, 0)).rgb, luma);
            float l02 = dot(src.sample(c + float2(-1, 1)).rgb, luma);
            float l12 = dot(src.sample(c + float2( 0, 1)).rgb, luma);
            float l22 = dot(src.sample(c + float2( 1, 1)).rgb, luma);

            // Laplacian: rotation-invariant sharpness measure.
            float sharpness = abs(-l00 - l10 - l20
                                  -l01 + 8.0*l11 - l21
                                  -l02 - l12 - l22);

            float4 original = src.sample(c);
            if (sharpness <= threshold) {
                return original;
            }
            // Fade in the highlight proportional to how far above threshold we are,
            // so strongly-focused edges glow brighter than borderline ones.
            float alpha = highlightColor.a * clamp((sharpness - threshold) / threshold, 0.0, 1.0);
            return mix(original, float4(highlightColor.rgb, 1.0), alpha);
        }
        """
        guard let k = CIKernel.compileMetal(source) else {
            Logger(subsystem: "com.nandanvarma.fexer", category: "camera")
                .error("CIKernel 'focusPeaking' failed to compile — focus peaking unavailable")
            return nil
        }
        return k
    }()

    override var outputImage: CIImage? {
        guard let input = inputImage, let kernel = Self.kernel else { return inputImage }
        let color = CIVector(
            x: CGFloat(inputHighlightColor.red),
            y: CGFloat(inputHighlightColor.green),
            z: CGFloat(inputHighlightColor.blue),
            w: CGFloat(inputHighlightColor.alpha)
        )
        return kernel.apply(
            extent: input.extent,
            // 3x3 kernel needs 1 extra pixel of input on every side.
            roiCallback: { _, rect in rect.insetBy(dx: -1, dy: -1) },
            arguments: [CISampler(image: input), NSNumber(value: inputThreshold), color]
        )
    }
}
