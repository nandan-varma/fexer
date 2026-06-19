import CoreImage

final class FocusPeakingFilter: CIFilter {
    var inputImage: CIImage?
    var inputThreshold: Float = 0.50
    var inputHighlightColor: CIColor = CIColor(red: 1, green: 0.2, blue: 0.2, alpha: 0.9)

    // CIKernel (not CIColorKernel) — neighbour sampling requires the general-purpose kernel.
    private static let kernel: CIKernel = {
        guard let url = Bundle.main.url(forResource: "default", withExtension: "metallib"),
              let data = try? Data(contentsOf: url),
              let k = try? CIKernel(functionName: "focusPeaking", fromMetalLibraryData: data)
        else { fatalError("CIKernel 'focusPeaking' not found in Metal library") }
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
            arguments: [CISampler(image: input), inputThreshold, colorVec]
        )
    }
}
