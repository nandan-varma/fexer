import CoreImage

/// Maps luminance bands to distinct false colors for exposure monitoring.
/// Blue = crushed blacks, cyan = shadows, green = lower mids,
/// passthrough = midtones, yellow = upper mids, orange = near-clip, red = blown.
final class FalseColorFilter: CIFilter {
    var inputImage: CIImage?

    private static let kernel: CIColorKernel = {
        guard let url = Bundle.main.url(forResource: "default", withExtension: "metallib"),
              let data = try? Data(contentsOf: url),
              let k = try? CIColorKernel(functionName: "falseColor", fromMetalLibraryData: data)
        else { fatalError("CIColorKernel 'falseColor' not found in Metal library") }
        return k
    }()

    override var outputImage: CIImage? {
        guard let input = inputImage else { return nil }
        return Self.kernel.apply(extent: input.extent, arguments: [input])
    }
}
