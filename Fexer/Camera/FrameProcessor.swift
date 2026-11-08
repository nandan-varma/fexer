import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Synchronization

struct ScopeData: Sendable {
    var histogram = [Double](repeating: 0, count: 64)
    var waveform = [Double](repeating: 0, count: 64 * 64)
    var vectorscope = [Double](repeating: 0, count: 64 * 64)
}

struct PreviewOptions: Sendable {
    var recipe = RenderRecipe()
    var monitor: Monitor = .off
    var peaking = false
    var zebras = false
    var falseColor = false
}

/// A one-frame mailbox provides backpressure: a slow display replaces, never queues, frames.
final class FrameProcessor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, Sendable {
    struct Snapshot: Sendable {
        var image: CIImage?
        var raw: CIImage?
        var scopes = ScopeData()
        var sequence = 0
        var previousImage: CIImage?
        var transitionStartedAt: Date?
        var transitionID: UInt64 = 0
        var isHolding = false
        var warmupFrames = 0
    }
    private let mailbox = Mutex(Snapshot())
    private let configuration = Mutex(PreviewOptions())
    func snapshot() -> Snapshot { mailbox.withLock { $0 } }
    func setOptions(_ options: PreviewOptions) { configuration.withLock { $0 = options } }
    func clear() { mailbox.withLock { $0 = Snapshot() } }

    /// Keep the last stable image on screen while AVFoundation reconfigures the capture path.
    /// The token prevents an older, slower switch from releasing a newer transition.
    func beginTransition() -> UInt64 {
        mailbox.withLock { snapshot in
            snapshot.transitionID &+= 1
            if !snapshot.isHolding { snapshot.previousImage = snapshot.image }
            snapshot.isHolding = true
            snapshot.warmupFrames = 0
            snapshot.transitionStartedAt = nil
            return snapshot.transitionID
        }
    }

    func finishTransition(_ id: UInt64) {
        mailbox.withLock { snapshot in
            guard snapshot.transitionID == id else { return }
            snapshot.isHolding = false
            snapshot.warmupFrames = 2
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        publish(CIImage(cvPixelBuffer: buffer))
    }

    func publish(_ source: CIImage) {
        autoreleasepool {
            guard !mailbox.withLock({ $0.isHolding }) else { return }
            let options = configuration.withLock { $0 }
            var image = ImagePipeline.apply(source, recipe: options.recipe, geometry: false)
            if options.falseColor {
                image = source.applyingFilter("CIFalseColor", parameters: [
                    "inputColor0": CIColor(red: 0.05, green: 0.15, blue: 0.8),
                    "inputColor1": CIColor(red: 1, green: 0.25, blue: 0.05)
                ])
            }
            if options.peaking {
                let edges = source.applyingFilter("CIEdges", parameters: ["inputIntensity": 4])
                    .applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.5])
                let color = CIImage(color: CIColor(red: 1, green: 0.35, blue: 0.15)).cropped(to: source.extent)
                image = color.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: edges])
            }
            if options.zebras {
                let mask = source.applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.95])
                let stripes = CIFilter.stripesGenerator()
                stripes.color0 = CIColor(red: 1, green: 0.3, blue: 0.1)
                stripes.color1 = .black
                stripes.width = 10
                if let pattern = stripes.outputImage?.transformed(by: .init(rotationAngle: .pi / 4)).cropped(to: source.extent) {
                    image = pattern.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: mask])
                }
            }
            let sequence = mailbox.withLock { $0.sequence + 1 }
            let scopes = options.monitor != .off && sequence % 6 == 0 ? Self.analyze(source) : nil
            mailbox.withLock {
                guard !$0.isHolding else { return }
                if $0.warmupFrames > 1 {
                    $0.warmupFrames -= 1
                    return
                }
                if $0.warmupFrames == 1 {
                    $0.warmupFrames = 0
                    $0.transitionStartedAt = .now
                } else if let started = $0.transitionStartedAt,
                          Date.now.timeIntervalSince(started) >= 0.24 {
                    $0.previousImage = nil
                    $0.transitionStartedAt = nil
                }
                $0.image = image
                $0.raw = source
                $0.sequence = sequence
                if let scopes { $0.scopes = scopes }
            }
        }
    }

    static func analyze(_ source: CIImage) -> ScopeData {
        guard source.extent.width > 0, source.extent.height > 0 else { return ScopeData() }
        let image = ImagePipeline.normalized(source).transformed(by: .init(scaleX: 64 / source.extent.width, y: 64 / source.extent.height))
        var pixels = [UInt8](repeating: 0, count: 64 * 64 * 4)
        ImagePipeline.context.render(image, toBitmap: &pixels, rowBytes: 256,
                                     bounds: CGRect(x: 0, y: 0, width: 64, height: 64), format: .RGBA8, colorSpace: ImagePipeline.colorSpace)
        return scopeData(pixels)
    }

    static func scopeData(_ pixels: [UInt8]) -> ScopeData {
        var data = ScopeData()
        guard pixels.count == 64 * 64 * 4 else { return data }
        for index in 0..<(64 * 64) {
            let r = Double(pixels[index * 4]) / 255
            let g = Double(pixels[index * 4 + 1]) / 255
            let b = Double(pixels[index * 4 + 2]) / 255
            let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
            let bin = Int((luma * 63).bounded(0...63))
            data.histogram[bin] += 1
            data.waveform[(index % 64) * 64 + bin] += 1
            let cb = Int((((b - luma) / 1.8556 + 0.5) * 63).bounded(0...63))
            let cr = Int(((0.5 - (r - luma) / 1.5748) * 63).bounded(0...63))
            data.vectorscope[cr * 64 + cb] += 1
        }
        let peak = max(data.histogram.max() ?? 1, 1)
        data.histogram = data.histogram.map { $0 / peak }
        data.waveform = data.waveform.map { min($0 / 6, 1) }
        data.vectorscope = data.vectorscope.map { min(log1p($0) / 5, 1) }
        return data
    }
}
