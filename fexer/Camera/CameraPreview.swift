import CoreImage
import MetalKit
import SwiftUI

struct CameraPreview: UIViewRepresentable {
    let frames: FrameProcessor
    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.framebufferOnly = false
        view.isOpaque = true
        view.clearColor = MTLClearColorMake(0.04, 0.04, 0.04, 1)
        view.preferredFramesPerSecond = 30
        view.enableSetNeedsDisplay = false
        view.delegate = context.coordinator
        context.coordinator.setup(view.device)
        return view
    }
    func updateUIView(_ view: MTKView, context: Context) {}
    static func dismantleUIView(_ view: MTKView, coordinator: Coordinator) { view.isPaused = true; view.delegate = nil }
    func makeCoordinator() -> Coordinator { Coordinator(frames) }

    @MainActor final class Coordinator: NSObject, MTKViewDelegate {
        let frames: FrameProcessor
        var queue: (any MTLCommandQueue)?
        var context: CIContext?
        init(_ frames: FrameProcessor) { self.frames = frames }
        func setup(_ device: (any MTLDevice)?) {
            guard let device else { return }
            queue = device.makeCommandQueue()
            context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        }
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
        func draw(in view: MTKView) {
            guard let source = frames.snapshot().image, let drawable = view.currentDrawable,
                  let buffer = queue?.makeCommandBuffer(), let context else { return }
            let size = view.drawableSize
            guard size.width > 0, size.height > 0 else { return }
            let scale = max(size.width / source.extent.width, size.height / source.extent.height)
            var image = ImagePipeline.normalized(source).transformed(by: .init(scaleX: scale, y: scale))
            image = image.transformed(by: .init(translationX: (size.width - image.extent.width) / 2, y: (size.height - image.extent.height) / 2))
            context.render(image, to: drawable.texture, commandBuffer: buffer, bounds: CGRect(origin: .zero, size: size), colorSpace: ImagePipeline.colorSpace)
            buffer.present(drawable)
            buffer.commit()
        }
    }
}

struct CompositionGrid: View {
    let style: GridStyle
    var body: some View {
        Canvas { context, size in
            var path = Path()
            if style == .diagonal {
                path.move(to: .zero); path.addLine(to: CGPoint(x: size.width, y: size.height))
                path.move(to: CGPoint(x: size.width, y: 0)); path.addLine(to: CGPoint(x: 0, y: size.height))
            } else if style != .off {
                let stops: [Double] = style == .thirds ? [1 / 3, 2 / 3] : [0.382, 0.618]
                for stop in stops {
                    path.move(to: CGPoint(x: size.width * stop, y: 0)); path.addLine(to: CGPoint(x: size.width * stop, y: size.height))
                    path.move(to: CGPoint(x: 0, y: size.height * stop)); path.addLine(to: CGPoint(x: size.width, y: size.height * stop))
                }
            }
            context.stroke(path, with: .color(.white.opacity(0.5)), lineWidth: 0.5)
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct LevelIndicator: View {
    let roll: Double
    private var isLevel: Bool { abs(roll) < 0.017 }
    var body: some View {
        Rectangle()
            .fill(isLevel ? Theme.accent : .white)
            .frame(width: 90, height: 1.5)
            .rotationEffect(.radians(roll))
            .shadow(radius: 2)
            .animation(.easeOut(duration: 0.1), value: roll)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct ScopeView: View {
    let frames: FrameProcessor
    let monitor: Monitor
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
            Canvas { context, size in
                let data = frames.snapshot().scopes
                if monitor == .histogram {
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: size.height))
                    for (index, value) in data.histogram.enumerated() {
                        path.addLine(to: CGPoint(x: Double(index) / 63 * size.width, y: size.height * (1 - value)))
                    }
                    path.addLine(to: CGPoint(x: size.width, y: size.height)); path.closeSubpath()
                    context.fill(path, with: .color(Theme.accent.opacity(0.85)))
                } else {
                    let values = monitor == .waveform ? data.waveform : data.vectorscope
                    for index in values.indices where values[index] > 0 {
                        let x = monitor == .waveform ? index / 64 : index % 64
                        let y = monitor == .waveform ? 63 - index % 64 : index / 64
                        let rect = CGRect(x: Double(x) / 64 * size.width, y: Double(y) / 64 * size.height, width: size.width / 64 + 0.5, height: size.height / 64 + 0.5)
                        context.fill(Path(rect), with: .color(Theme.accent.opacity(values[index])))
                    }
                }
            }
        }.padding(8).frame(width: 116, height: 65).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityLabel(monitor.rawValue + " exposure monitor")
    }
}
