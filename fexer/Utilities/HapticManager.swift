import UIKit

final class HapticManager {
    static let shared = HapticManager()

    private let impactRigid = UIImpactFeedbackGenerator(style: .rigid)
    private let impactMedium = UIImpactFeedbackGenerator(style: .medium)
    private let impactLight = UIImpactFeedbackGenerator(style: .light)
    private let notification = UINotificationFeedbackGenerator()
    private let selection = UISelectionFeedbackGenerator()

    private init() {
        impactRigid.prepare()
        impactMedium.prepare()
        impactLight.prepare()
        notification.prepare()
        selection.prepare()
    }

    static func shutter() {
        shared.impactRigid.impactOccurred()
        shared.impactRigid.prepare()
    }

    static func focusLocked() {
        shared.notification.notificationOccurred(.success)
        shared.notification.prepare()
    }

    static func selectionChanged() {
        shared.selection.selectionChanged()
        shared.selection.prepare()
    }

    static func light() {
        shared.impactLight.impactOccurred()
        shared.impactLight.prepare()
    }

    static func medium() {
        shared.impactMedium.impactOccurred()
        shared.impactMedium.prepare()
    }

    static func error() {
        shared.notification.notificationOccurred(.error)
        shared.notification.prepare()
    }
}
