import CoreImage

final class ZebraFilter: CIFilter {
    var inputImage: CIImage?
    var inputOverThreshold: Float = 0.95
    var inputUnderThreshold: Float = 0.02
    var inputTime: Float = 0.0
    var inputStripeWidth: Float = 12.0

    private static let kernel: CIKernel = {
        let source = """
        #include <CoreImage/CoreImage.h>
        using namespace metal;

        [[stitchable]] float4 zebraStripes(coreimage::sampler src, float overThreshold, float underThreshold,
                                            float time, float stripeWidth) {
            float2 d = src.coord();
            float4 s = src.sample(d);
            float luma = dot(s.rgb, float3(0.299, 0.587, 0.114));
            if (luma > overThreshold || luma < underThreshold) {
                float stripe = fmod(d.x + d.y + time, stripeWidth * 2.0);
                float4 warningColor = luma > overThreshold
                                       ? float4(1.0, 0.0, 0.0, 1.0)
                                       : float4(0.0, 0.4, 1.0, 1.0);
                return stripe < stripeWidth ? warningColor : float4(0.0, 0.0, 0.0, 1.0);
            }
            return s;
        }
        """
        guard let k = CIKernel.compileMetal(source)
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
