import SwiftUI

@main
struct FexerApp: App {
    @State private var camera: CameraModel

    @MainActor init() {
        // A struct's stored properties can't be assigned from inside a closure (even a
        // non-escaping one) — build the model inside the timed closure and assign it after.
        let model: CameraModel = Diagnostics.time("app.init (process start to first view)") {
            let preferences = Diagnostics.time("app.init.preferences") { PreferenceStore() }
            let store = Diagnostics.time("app.init.captureStore") { CaptureStore(root: try! CaptureStore.applicationRoot()) }
            let library = Diagnostics.time("app.init.libraryModel") { LibraryModel(store: store, renderer: ImageRenderer()) }
            let service: any CameraOperating
            let frames: FrameProcessor
            #if targetEnvironment(simulator)
            let sample = Diagnostics.time("app.init.loadSampleImage") { UIImage(named: "SamplePreview")?.jpegData(compressionQuality: 0.9) ?? Data() }
            if sample.isEmpty { Diagnostics.camera.error("Sample preview image failed to load from the asset catalog") }
            let simulated = Diagnostics.time("app.init.simulatedCamera") { SimulatedCamera(sample: sample) }
            service = simulated
            frames = simulated.frames
            #else
            let real = Diagnostics.time("app.init.cameraService") { CameraService() }
            service = real
            frames = real.frames
            #endif
            return Diagnostics.time("app.init.cameraModel") { CameraModel(service: service, frames: frames, library: library, preferences: preferences) }
        }
        _camera = State(initialValue: model)
    }

    var body: some Scene {
        WindowGroup { CameraView(model: camera) }
    }
}
