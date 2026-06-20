import SwiftUI
import AVFoundation

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.shortcutItems = [
            UIApplicationShortcutItem(
                type: "com.nandanvarma.fexer.mode.video",
                localizedTitle: "Record Video",
                localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: "video.fill"),
                userInfo: nil
            ),
            UIApplicationShortcutItem(
                type: "com.nandanvarma.fexer.mode.longExposure",
                localizedTitle: "Long Exposure",
                localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: "timelapse"),
                userInfo: nil
            ),
            UIApplicationShortcutItem(
                type: "com.nandanvarma.fexer.mode.burst",
                localizedTitle: "Burst",
                localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: "square.stack.3d.up"),
                userInfo: nil
            ),
        ]
        return true
    }

    func application(
        _ application: UIApplication,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let mode: ShootingMode
        switch shortcutItem.type {
        case "com.nandanvarma.fexer.mode.video":        mode = .video
        case "com.nandanvarma.fexer.mode.longExposure": mode = .longExposure
        case "com.nandanvarma.fexer.mode.burst":        mode = .burst
        default:                                         mode = .photo
        }
        AppState.shared.pendingShootingMode = mode
        completionHandler(true)
    }

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

    init() {
        CIContext.warmUpPipeline()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
        }
    }
}

struct RootView: View {
    @Environment(AppState.self) var appState
    @State private var showSplash = true
    @State private var cameraManager = CameraManager()
    @State private var stylesManager = StylesManager()

    private var cameraStatus: AVAuthorizationStatus {
        appState.permissionsManager.cameraStatus
    }

    var body: some View {
        ZStack {
            if showSplash {
                SplashView { showSplash = false }
                    .transition(.opacity)
                    .zIndex(1)
            } else {
                mainContent
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: showSplash)
        .onAppear {
            // Pre-warm the camera session during the splash so CameraPreview
            // gets a live image the moment it appears, avoiding a black frame.
            if cameraStatus == .authorized {
                cameraManager.startSession()
            }
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        switch cameraStatus {
        case .authorized:
            authorizedContent
        case .denied, .restricted:
            CameraAccessDeniedView()
        default:
            OnboardingView(permissionsManager: appState.permissionsManager)
        }
    }

    @ViewBuilder
    private var authorizedContent: some View {
        switch appState.currentScreen {
        case .camera:
            CameraView(cameraManager: cameraManager, stylesManager: stylesManager)
                .environment(appState)
        case .gallery:
            GalleryView()
                .environment(appState)
        case .settings:
            SettingsView(cameraManager: cameraManager, stylesManager: stylesManager)
                .environment(appState)
        }
    }
}
