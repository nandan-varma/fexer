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
    var leftRailItems: [SideRailItem] = AppState.loadRailItems(key: "leftRailItems", default: [.flash])
    var rightRailItems: [SideRailItem] = AppState.loadRailItems(key: "rightRailItems", default: [.metering])
    let permissionsManager = PermissionsManager()
    var pendingShootingMode: ShootingMode? = nil

    private static func loadQuickAccessItems() -> [QuickAccessItem] {
        if let saved = UserDefaults.standard.array(forKey: "quickAccessItems") as? [String] {
            return saved.compactMap { QuickAccessItem(rawValue: $0) }
        }
        return [.timer, .hdr, .format, .grid, .histogram, .flipCamera, .focusPeaking, .afMode, .waveform, .vectorscope]
    }

    private static func loadRailItems(key: String, default defaultItems: [SideRailItem]) -> [SideRailItem] {
        if let saved = UserDefaults.standard.array(forKey: key) as? [String] {
            return saved.compactMap { SideRailItem(rawValue: $0) }
        }
        return defaultItems
    }

    func saveQuickAccessItems() {
        UserDefaults.standard.set(quickAccessItems.map(\.rawValue), forKey: "quickAccessItems")
    }

    func saveRailItems() {
        UserDefaults.standard.set(leftRailItems.map(\.rawValue), forKey: "leftRailItems")
        UserDefaults.standard.set(rightRailItems.map(\.rawValue), forKey: "rightRailItems")
    }
}
