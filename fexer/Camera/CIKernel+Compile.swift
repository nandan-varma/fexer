import CoreImage

extension CIKernel {
    static func compileMetal(_ source: String) -> CIKernel? {
        do {
            return try CIKernel.kernels(withMetalString: source).first
        } catch {
            assertionFailure("CI Metal kernel compilation failed: \(error)")
            return nil
        }
    }
}
