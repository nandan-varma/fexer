import SwiftUI
import Observation

enum AppScreen {
    case camera, gallery, settings
}

@Observable
final class AppState {
    static let shared = AppState()

    var currentScreen: AppScreen = .camera
    var quickAccessItems: [QuickAccessItem] = AppState.loadQuickAccessItems()
    let permissionsManager = PermissionsManager()

    private static func loadQuickAccessItems() -> [QuickAccessItem] {
        if let saved = UserDefaults.standard.array(forKey: "quickAccessItems") as? [String] {
            return saved.compactMap { QuickAccessItem(rawValue: $0) }
        }
        return [.flash, .timer, .grid, .histogram, .flipCamera, .focusPeaking, .afMode]
    }

    func saveQuickAccessItems() {
        UserDefaults.standard.set(quickAccessItems.map(\.rawValue), forKey: "quickAccessItems")
    }
}
