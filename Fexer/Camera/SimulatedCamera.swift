#if targetEnvironment(simulator)
import CoreImage
import Foundation

/// Simulator-only fixture. Device builds always use AVFoundation.
actor SimulatedCamera: CameraOperating {
    nonisolated let frames = FrameProcessor()
    nonisolated let events: AsyncStream<CameraEvent>
    private let continuation: AsyncStream<CameraEvent>.Continuation
    private let sample: Data
    private var loop: Task<Void, Never>?

    init(sample: Data) {
        self.sample = sample
        let stream = AsyncStream.makeStream(of: CameraEvent.self, bufferingPolicy: .bufferingNewest(12))
        events = stream.stream
        continuation = stream.continuation
    }
    func start() {
        continuation.yield(.capabilities(.sample))
        continuation.yield(.phase(.ready))
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.publish()
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
        }
    }
    func stop() { loop?.cancel(); loop = nil; frames.clear(); continuation.yield(.phase(.idle)) }
    func capture(_ request: CaptureRequest) throws -> PhotoPayload {
        guard !sample.isEmpty else { throw AppIssue.decodingFailed }
        return PhotoPayload(processed: sample)
    }
    func apply(_ controls: CameraControls) {
        continuation.yield(.reading(.init(iso: controls.iso, shutter: controls.shutter, temperature: controls.temperature, focus: controls.focus, zoom: controls.zoom)))
    }
    func selectLens(_ id: String) {}
    func focus(at point: CGPoint) {}
    func setPreview(_ options: PreviewOptions) { frames.setOptions(options) }
    func recordMovie(fourK: Bool, fps: Int, onStarted: @escaping @Sendable () -> Void) throws -> URL {
        throw AppIssue("Use an iPhone for video", "The simulator displays a sample scene. Video recording requires a physical camera.")
    }
    func finishMovie() {}
    func prewarmVideo(fourK: Bool, fps: Int) {}
    func prewarmPhoto() {}
    private func publish() {
        guard let image = CIImage(data: sample, options: [.applyOrientationProperty: true]) else { return }
        let scale = min(1, 1200 / max(image.extent.width, image.extent.height))
        frames.publish(image.transformed(by: .init(scaleX: scale, y: scale)))
    }
}
#endif
