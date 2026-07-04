import CoreImage
import OSLog

extension CIKernel {
    static func compileMetal(_ source: String) -> CIKernel? {
        do {
            return try CIKernel.kernels(withMetalString: source).first
        } catch {
            Logger(subsystem: "com.nandanvarma.fexer", category: "camera").error(
                "CI Metal kernel compilation failed: \(error.localizedDescription)")
            assertionFailure("CI Metal kernel compilation failed: \(error)")
            return nil
        }
    }
}
