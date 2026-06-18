import SwiftUI

@main
struct fexerApp: App {
    @State private var appState = AppState.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
        }
    }
}

struct RootView: View {
    @Environment(AppState.self) var appState

    var body: some View {
        switch appState.currentScreen {
        case .camera:
            CameraView()
                .environment(appState)
        case .gallery:
            GalleryView()
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button {
                            appState.currentScreen = .camera
                        } label: {
                            Image(systemName: "camera")
                        }
                    }
                }
        case .settings:
            Text("Settings")
        }
    }
}
