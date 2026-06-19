import CoreImage

final class ZebraFilter: CIFilter {
    var inputImage: CIImage?
    var inputOverThreshold: Float = 0.95
    var inputUnderThreshold: Float = 0.02
    var inputTime: Float = 0.0
    var inputStripeWidth: Float = 12.0

    private static let kernel: CIColorKernel = {
        guard let url = Bundle.main.url(forResource: "default", withExtension: "metallib"),
              let data = try? Data(contentsOf: url),
              let k = try? CIColorKernel(functionName: "zebraStripes", fromMetalLibraryData: data)
        else { fatalError("CIColorKernel 'zebraStripes' not found in Metal library") }
        return k
    }()

    override var outputImage: CIImage? {
        guard let input = inputImage else { return nil }
        return Self.kernel.apply(
            extent: input.extent,
            arguments: [input, inputOverThreshold, inputUnderThreshold, inputTime, inputStripeWidth]
        )
    }
}
