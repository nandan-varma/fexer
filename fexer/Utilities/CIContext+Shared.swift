import CoreImage
import Metal
import OSLog

extension CIContext {
    private static let sharedInstance: CIContext = {
        let log = Logger(subsystem: "com.nandanvarma.fexer", category: "camera")
        guard let device = MTLCreateSystemDefaultDevice() else {
            log.error("Metal unavailable — falling back to software CIContext")
            return CIContext(options: [.useSoftwareRenderer: true])
        }
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else {
            log.error("sRGB color space unavailable — falling back to software CIContext")
            return CIContext(mtlDevice: device, options: [.useSoftwareRenderer: false])
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
