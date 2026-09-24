import SwiftUI

@main
struct FexerApp: App {
    @State private var camera: CameraModel

    @MainActor init() {
        let preferences = PreferenceStore()
        let store = CaptureStore(root: try! CaptureStore.applicationRoot())
        let library = LibraryModel(store: store, renderer: ImageRenderer())
        let service: any CameraOperating
        let frames: FrameProcessor
        #if targetEnvironment(simulator)
        let sample = UIImage(named: "SamplePreview")?.jpegData(compressionQuality: 0.9) ?? Data()
        if sample.isEmpty { Diagnostics.camera.error("Sample preview image failed to load from the asset catalog") }
        let simulated = SimulatedCamera(sample: sample)
        service = simulated
        frames = simulated.frames
        #else
        let real = CameraService()
        service = real
        frames = real.frames
        #endif
        _camera = State(initialValue: CameraModel(service: service, frames: frames, library: library, preferences: preferences))
    }

    var body: some Scene {
        WindowGroup { CameraView(model: camera) }
    }
}
