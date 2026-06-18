import SwiftUI
import MetalKit
import CoreImage

/// MTKView-based camera preview that runs the full CI filter pipeline.
struct CameraPreview: UIViewRepresentable {
    let cameraManager: CameraManager
    var cropRatio: CropRatio = .full
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
        context.coordinator.cropRatio = cropRatio
        context.coordinator.onTapToFocus = onTapToFocus
        context.coordinator.onPinchZoom = onPinchZoom
        context.coordinator.onSwipeBrightness = onSwipeBrightness
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(cameraManager: cameraManager)
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        let cameraManager: CameraManager
        var cropRatio: CropRatio = .full
        var onTapToFocus: ((CGPoint, CGSize) -> Void)?
        var onPinchZoom: ((CGFloat, CGFloat) -> Void)?
        var onSwipeBrightness: ((CGFloat) -> Void)?

        private var lastPinchScale: CGFloat = 1.0
        private var panIsVerticalRight = false

        private let mtlDevice: MTLDevice = MTLCreateSystemDefaultDevice()!
        private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        private var cachedBlackBG: CIImage?
        private var cachedBlackBGSize: CGSize = .zero

        private lazy var ciContext: CIContext = {
            CIContext(mtlDevice: mtlDevice, options: [.useSoftwareRenderer: false])
        }()

        private lazy var commandQueue: MTLCommandQueue? = {
            mtlDevice.makeCommandQueue()
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
            let imageExtent  = image.extent

            let scaleX = drawableSize.width  / imageExtent.width
            let scaleY = drawableSize.height / imageExtent.height

            if cropRatio == .full {
                // Aspect-fit: show the entire sensor output, letterboxed with black bars.
                let scale = min(scaleX, scaleY)
                let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                let dx = (drawableSize.width  - scaled.extent.width)  / 2
                let dy = (drawableSize.height - scaled.extent.height) / 2
                let centered = scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy))

                if cachedBlackBGSize != drawableSize {
                    cachedBlackBG = CIImage(color: CIColor(red: 0, green: 0, blue: 0))
                        .cropped(to: CGRect(origin: .zero, size: drawableSize))
                    cachedBlackBGSize = drawableSize
                }
                let composite = centered.composited(over: cachedBlackBG!)

                ciContext.render(composite,
                                 to: drawable.texture,
                                 commandBuffer: commandBuffer,
                                 bounds: CGRect(origin: .zero, size: drawableSize),
                                 colorSpace: sRGB)
            } else {
                // Aspect-fill: image covers the drawable; SwiftUI adds crop-guide bars.
                let scale = max(scaleX, scaleY)
                let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                let cropOrigin = CGPoint(
                    x: scaled.extent.origin.x + (scaled.extent.width  - drawableSize.width)  / 2,
                    y: scaled.extent.origin.y + (scaled.extent.height - drawableSize.height) / 2
                )
                ciContext.render(scaled,
                                 to: drawable.texture,
                                 commandBuffer: commandBuffer,
                                 bounds: CGRect(origin: cropOrigin, size: drawableSize),
                                 colorSpace: sRGB)
            }

            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view else { return }
            let point = gesture.location(in: view)
            let size = view.bounds.size

            // Ignore taps in letterbox bar areas (neither focus point nor indicator should land there)
            let barH = previewBarHeight(viewSize: size)
            guard point.y >= barH && point.y <= size.height - barH else { return }

            // Convert to AVFoundation normalized coordinates (origin bottom-left, axes swapped for portrait)
            let normalized = CGPoint(x: point.y / size.height, y: 1 - point.x / size.width)
            onTapToFocus?(normalized, size)
        }

        /// Height of each letterbox bar in the view's points coordinate system.
        private func previewBarHeight(viewSize: CGSize) -> CGFloat {
            if cropRatio == .full {
                let imageSize = cameraManager.previewImageSize
                guard imageSize.width > 0 && imageSize.height > 0 else { return 0 }
                let imageAspect = imageSize.width / imageSize.height
                let viewAspect  = viewSize.width  / viewSize.height
                guard viewAspect < imageAspect else { return 0 }
                let scaledH = viewSize.width / imageAspect
                return max(0, (viewSize.height - scaledH) / 2)
            } else {
                guard let aspect = cropRatio.portraitAspect else { return 0 }
                let contentH = viewSize.width / aspect
                return max(0, (viewSize.height - contentH) / 2)
            }
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
            let size = view.bounds.size

            if gesture.state == .began {
                let barH = previewBarHeight(viewSize: size)
                let inPreview = location.y >= barH && location.y <= size.height - barH
                panIsVerticalRight = inPreview &&
                                     location.x > size.width * 0.7 &&
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
