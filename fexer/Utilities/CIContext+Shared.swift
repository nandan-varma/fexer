import CoreImage
import Metal
import OSLog

extension CIContext {
    private static let sharedInstance: CIContext = {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not available on this device")
        }
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else {
            fatalError("sRGB color space unavailable")
        }
        return CIContext(mtlDevice: device, options: [
            .useSoftwareRenderer: false,
            .workingColorSpace: sRGB
        ])
    }()

    /// Shared Metal-backed CIContext to avoid redundant GPU context creation.
    /// Thread-safe — CIContext is thread-safe for rendering operations.
    static var shared: CIContext { sharedInstance }
}
