import SwiftUI

@main
struct FexerApp: App {
    @State private var camera: CameraModel

    @MainActor init() {
        // A struct's stored properties can't be assigned from inside a closure (even a
        // non-escaping one) — build the model inside the timed closure and assign it after.
        let model: CameraModel = Diagnostics.time("app.init (process start to first view)") {
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
            return CameraModel(service: service, frames: frames, library: library, preferences: preferences)
        }
        _camera = State(initialValue: model)
    }

    var body: some Scene {
        WindowGroup { CameraView(model: camera) }
    }
}
