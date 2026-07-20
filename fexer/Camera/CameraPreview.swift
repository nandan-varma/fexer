import AVFoundation
import CoreImage
import MetalKit
import SwiftUI

/// MTKView-based camera preview that renders the CI filter pipeline output
/// at continuous 60fps. Handles tap-to-focus, pinch-to-zoom, and brightness swipe.
struct CameraPreview: UIViewRepresentable {
    let cameraManager: CameraManager
    var cropRatio: CropRatio = .full
    var onTapToFocus: ((CGPoint, CGPoint) -> Void)?
    var onDoubleTap: (() -> Void)?
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
        // Gesture recognizers deferred via setupGestures to avoid
        // "Assuming sourceView is not nil" (they need the view in the hierarchy).
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        // Re-arm the draw loop on every SwiftUI update — iOS may suspend it
        // when the view is covered (e.g. by the splash screen).
        uiView.isPaused = false
        context.coordinator.cropRatio = cropRatio
        context.coordinator.onTapToFocus = onTapToFocus
        context.coordinator.onDoubleTap = onDoubleTap
        context.coordinator.onPinchZoom = onPinchZoom
        context.coordinator.onSwipeBrightness = onSwipeBrightness
        context.coordinator.setupGesturesIfNeeded(on: uiView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(cameraManager: cameraManager)
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        let cameraManager: CameraManager
        var cropRatio: CropRatio = .full
        var onTapToFocus: ((CGPoint, CGPoint) -> Void)?
        var onDoubleTap: (() -> Void)?
        var onPinchZoom: ((CGFloat, CGFloat) -> Void)?
        var onSwipeBrightness: ((CGFloat) -> Void)?

        private var lastPinchScale: CGFloat = 1.0
        private var panIsVerticalRight = false
        private var gesturesSetup = false

        /// Adds gesture recognizers on the first call. Must be called when the view
        /// is already in the window hierarchy to suppress "Assuming sourceView is not nil".
        func setupGesturesIfNeeded(on view: MTKView) {
            guard !gesturesSetup else { return }
            gesturesSetup = true

            // Double-tap must be registered first so single-tap can require it to fail.
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
            doubleTap.numberOfTapsRequired = 2
            view.addGestureRecognizer(doubleTap)

            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
            // Wait for double-tap to fail before firing; prevents 350ms swallow of single taps.
            tap.require(toFail: doubleTap)
            view.addGestureRecognizer(tap)

            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch))
            view.addGestureRecognizer(pinch)
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
            pan.minimumNumberOfTouches = 1
            pan.maximumNumberOfTouches = 1
            view.addGestureRecognizer(pan)
        }

        // Optional so Metal or colorspace unavailability degrades gracefully instead of crashing.
        private let mtlDevice: MTLDevice? = MTLCreateSystemDefaultDevice()
        private let sRGB: CGColorSpace? = CGColorSpace(name: CGColorSpace.sRGB)
        private var cachedBlackBG: CIImage?
        private var cachedBlackBGSize: CGSize = .zero

        private lazy var ciContext = CIContext.shared

        private lazy var commandQueue: MTLCommandQueue? = mtlDevice?.makeCommandQueue()

        init(cameraManager: CameraManager) {
            self.cameraManager = cameraManager
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable,
                  let commandQueue,
                  let commandBuffer = commandQueue.makeCommandBuffer(),
                  let image = cameraManager.processor.getLatestImage(),
                  let sRGB
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
                guard let bg = cachedBlackBG else { return }
                let composite = centered.composited(over: bg)

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

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            onDoubleTap?()
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view else { return }
            let point = gesture.location(in: view)
            let size = view.bounds.size

            // Ignore taps in letterbox bar areas.
            let barH = previewBarHeight(viewSize: size)
            guard point.y >= barH && point.y <= size.height - barH else { return }

            // Map screen tap → AVFoundation focusPointOfInterest (portrait, 90° rotated delivery).
            // x axis: screen-Y → sensor row (mapped from active area in .full letterbox mode).
            // y axis: screen-X → sensor column; front camera flips due to landscape-left native orientation.
            let avX: CGFloat
            if cropRatio == .full && barH > 0 {
                let activeHeight = size.height - 2 * barH
                avX = (point.y - barH) / max(activeHeight, 1)
            } else {
                avX = point.y / size.height
            }
            let isFront = cameraManager.currentDevice?.position == .front
            let avY: CGFloat = isFront ? point.x / size.width : 1 - point.x / size.width
            let avPoint = CGPoint(x: avX, y: avY)
            // Pass the raw view-space point so the caller never has to invert the transform.
            onTapToFocus?(avPoint, point)
        }

        /// Height of each letterbox bar in the view's points coordinate system.
        private func previewBarHeight(viewSize: CGSize) -> CGFloat {
            let imageSize = cameraManager.previewImageSize
            let imageAspect = imageSize.width > 0 && imageSize.height > 0 ? imageSize.width / imageSize.height : nil
            return cropRatio.letterboxBarHeight(viewSize: viewSize, imageAspect: imageAspect)
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
