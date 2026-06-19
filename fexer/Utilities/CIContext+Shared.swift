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

    /// Pre-compiles the Metal `plane_color` pipeline that CI uses when rendering to a
    /// texture. Without this, the first `draw(in:)` call blocks the MTKView render loop
    /// for ~2.5 s while the GPU driver compiles the shader. Call once at app launch on
    /// a background thread.
    static func warmUpPipeline() {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let device = MTLCreateSystemDefaultDevice(),
                  let queue = device.makeCommandQueue(),
                  let commandBuffer = queue.makeCommandBuffer(),
                  let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else { return }

            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
            desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
            guard let texture = device.makeTexture(descriptor: desc) else { return }

            let dummy = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1))
                .cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
            shared.render(dummy,
                          to: texture,
                          commandBuffer: commandBuffer,
                          bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                          colorSpace: sRGB)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
        }
    }
}
