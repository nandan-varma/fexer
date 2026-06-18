import SwiftUI
import MetalKit
import CoreImage

/// MTKView-based camera preview that runs the full CI filter pipeline.
struct CameraPreview: UIViewRepresentable {
    let cameraManager: CameraManager
    var onTapToFocus: ((CGPoint, CGSize) -> Void)?
    var onPinchZoom: ((CGFloat, CGFloat) -> Void)?
    var onSwipeBrightness: ((CGFloat) -> Void)?

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.framebufferOnly = false
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.preferredFramesPerSecond = 60
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.delegate = context.coordinator

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap))
        view.addGestureRecognizer(tap)

        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch))
        view.addGestureRecognizer(pinch)

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)

        cameraManager.processor.onFrameAvailable = { [weak view] in
            view?.setNeedsDisplay()
        }

        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.onTapToFocus = onTapToFocus
        context.coordinator.onPinchZoom = onPinchZoom
        context.coordinator.onSwipeBrightness = onSwipeBrightness
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(cameraManager: cameraManager)
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        let cameraManager: CameraManager
        var onTapToFocus: ((CGPoint, CGSize) -> Void)?
        var onPinchZoom: ((CGFloat, CGFloat) -> Void)?
        var onSwipeBrightness: ((CGFloat) -> Void)?

        private var lastPinchScale: CGFloat = 1.0
        private var panStartY: CGFloat = 0
        private var panIsVerticalRight = false

        private lazy var ciContext: CIContext = {
            CIContext(mtlDevice: MTLCreateSystemDefaultDevice()!,
                      options: [.useSoftwareRenderer: false])
        }()

        init(cameraManager: CameraManager) {
            self.cameraManager = cameraManager
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable,
                  let commandQueue = view.device?.makeCommandQueue(),
                  let commandBuffer = commandQueue.makeCommandBuffer(),
                  let image = cameraManager.processor.getLatestImage()
            else { return }

            let drawableSize = view.drawableSize
            let scaleX = drawableSize.width  / image.extent.width
            let scaleY = drawableSize.height / image.extent.height
            let scale  = max(scaleX, scaleY)

            let scaledImage = image
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .cropped(to: CGRect(origin: .zero, size: drawableSize))

            ciContext.render(scaledImage,
                             to: drawable.texture,
                             commandBuffer: commandBuffer,
                             bounds: CGRect(origin: .zero, size: drawableSize),
                             colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)

            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view else { return }
            let point = gesture.location(in: view)
            let size = view.bounds.size
            // Normalize to 0–1 for AVFoundation focus point
            let normalized = CGPoint(x: point.y / size.height, y: 1 - point.x / size.width)
            onTapToFocus?(normalized, size)
        }

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            if gesture.state == .began { lastPinchScale = cameraManager.currentZoomFactor }
            let newZoom = lastPinchScale * gesture.scale
            onPinchZoom?(newZoom, gesture.velocity)
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view else { return }
            let location = gesture.location(in: view)
            let translation = gesture.translation(in: view)

            if gesture.state == .began {
                panStartY = location.y
                // Only capture right-side vertical swipe for exposure comp
                panIsVerticalRight = location.x > view.bounds.width * 0.7 &&
                                     abs(translation.y) > abs(translation.x)
            }

            if panIsVerticalRight && gesture.state == .changed {
                let delta = -translation.y / view.bounds.height * 6.0 // ±3 EV range
                onSwipeBrightness?(delta)
                gesture.setTranslation(.zero, in: view)
            }
        }
    }
}
