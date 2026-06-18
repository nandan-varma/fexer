import SwiftUI

// Portrait lock: system checks this before presenting any controller.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        .portrait
    }
}

@main
struct fexerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
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
                .environment(appState)
        case .settings:
            CameraView()
                .environment(appState)
        }
    }
}
