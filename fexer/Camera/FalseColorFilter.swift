import CoreImage
import OSLog

final class FalseColorFilter: CIFilter {
    var inputImage: CIImage?

    // Optional so a Metal shader compile failure degrades gracefully instead of crashing.
    private static let kernel: CIKernel? = {
        let source = """
        #include <CoreImage/CoreImage.h>
        using namespace metal;

        [[stitchable]] float4 falseColor(coreimage::sample_t s) {
            float luma = dot(s.rgb, float3(0.2126, 0.7152, 0.0722));
            if (luma < 0.04)
                return float4(0.0, 0.0, 0.7, 1.0);
            else if (luma < 0.12) {
                float t = (luma - 0.04) / 0.08;
                return mix(float4(0.0, 0.0, 0.7, 1.0), float4(0.0, 0.6, 0.85, 1.0), t);
            } else if (luma < 0.35) {
                float t = (luma - 0.12) / 0.23;
                return mix(float4(0.0, 0.6, 0.85, 1.0), float4(0.0, 0.75, 0.0, 1.0), t);
            } else if (luma < 0.55)
                return s;
            else if (luma < 0.72) {
                float t = (luma - 0.55) / 0.17;
                return mix(s, float4(1.0, 0.85, 0.0, 1.0), t * 0.75);
            } else if (luma < 0.88) {
                float t = (luma - 0.72) / 0.16;
                return mix(float4(1.0, 0.85, 0.0, 1.0), float4(1.0, 0.3, 0.0, 1.0), t);
            } else
                return float4(1.0, 0.0, 0.0, 1.0);
        }
        """
        guard let k = CIKernel.compileMetal(source) else {
            Logger(subsystem: "com.nandanvarma.fexer", category: "camera")
                .error("CIKernel 'falseColor' failed to compile — false color unavailable")
            return nil
        }
        return k
    }()

    override var outputImage: CIImage? {
        // Return the input unmodified when the kernel failed to compile.
        guard let input = inputImage, let kernel = Self.kernel else { return inputImage }
        return kernel.apply(extent: input.extent,
                            roiCallback: { _, rect in rect },
                            arguments: [input])
    }
}
