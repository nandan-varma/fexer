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
        // Continuous rendering — MTKViewDelegate.draw fires at 60fps automatically.
        // enableSetNeedsDisplay = false + isPaused = false is the continuous mode.
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.preferredFramesPerSecond = 60
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.delegate = context.coordinator

        if FeatureFlags.tapToFocus {
            let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap))
            view.addGestureRecognizer(tap)
        }

        if FeatureFlags.pinchToZoom {
            let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch))
            view.addGestureRecognizer(pinch)
        }

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)

        // No onFrameAvailable needed — MTKView renders continuously.

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
        private var panIsVerticalRight = false

        private lazy var ciContext: CIContext = {
            CIContext(mtlDevice: MTLCreateSystemDefaultDevice()!,
                      options: [.useSoftwareRenderer: false])
        }()

        private lazy var commandQueue: MTLCommandQueue? = {
            MTLCreateSystemDefaultDevice()?.makeCommandQueue()
        }()

        init(cameraManager: CameraManager) {
            self.cameraManager = cameraManager
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable,
                  let commandQueue,
                  let commandBuffer = commandQueue.makeCommandBuffer(),
                  let image = cameraManager.processor.getLatestImage()
            else { return }

            let drawableSize = view.drawableSize
            let imageExtent = image.extent

            // Aspect-fill: scale so the image fully covers the drawable.
            let scaleX = drawableSize.width  / imageExtent.width
            let scaleY = drawableSize.height / imageExtent.height
            let scale  = max(scaleX, scaleY)

            let scaledImage = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

            // Center-crop: offset into the scaled image so we sample from the middle.
            let scaledExtent = scaledImage.extent
            let cropOrigin = CGPoint(
                x: scaledExtent.origin.x + (scaledExtent.width  - drawableSize.width)  / 2,
                y: scaledExtent.origin.y + (scaledExtent.height - drawableSize.height) / 2
            )
            let renderBounds = CGRect(origin: cropOrigin, size: drawableSize)

            ciContext.render(scaledImage,
                             to: drawable.texture,
                             commandBuffer: commandBuffer,
                             bounds: renderBounds,
                             colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view else { return }
            let point = gesture.location(in: view)
            let size = view.bounds.size
            // Convert to AVFoundation normalized coordinates (origin bottom-left, axes swapped for portrait)
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
            let location  = gesture.location(in: view)
            let translation = gesture.translation(in: view)

            if gesture.state == .began {
                panIsVerticalRight = location.x > view.bounds.width * 0.7 &&
                                     abs(translation.y) > abs(translation.x)
            }

            if panIsVerticalRight && gesture.state == .changed {
                let delta = -translation.y / view.bounds.height * 6.0
                onSwipeBrightness?(delta)
                gesture.setTranslation(.zero, in: view)
            }
        }
    }
}
