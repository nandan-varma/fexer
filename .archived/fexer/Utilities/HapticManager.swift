import CoreHaptics
import UIKit

/// Thin wrapper around UIFeedbackGenerator that lazy-creates each generator
/// only on first use. All public methods are guarded by an availability
/// check so they are no-ops on devices without haptic support.
final class HapticManager {
    static let shared = HapticManager()

    /// Whether CoreHaptics is available on this device.
    static var isAvailable: Bool {
        CHHapticEngine.capabilitiesForHardware().supportsHaptics
    }

    /// Eagerly warm up the generator caches. Must be called after the app is
    /// in the foreground (e.g., from `onAppear`), not during `App.init()`.
    /// Runs synchronously on the calling thread.
    static func warmUp() {
        dispatchPrecondition(condition: .onQueue(.main))
        let s = shared
        _ = s.impactRigid
        _ = s.impactMedium
        _ = s.impactLight
        _ = s.notification
        _ = s.selection
    }

    // Lazy generators — all access must happen from the main thread.
    // warmUp() is called from onAppear so these are always initialized on main.
    private lazy var impactRigid = UIImpactFeedbackGenerator(style: .rigid)
    private lazy var impactMedium = UIImpactFeedbackGenerator(style: .medium)
    private lazy var impactLight = UIImpactFeedbackGenerator(style: .light)
    private lazy var notification = UINotificationFeedbackGenerator()
    private lazy var selection = UISelectionFeedbackGenerator()

    private init() {}

    static func shutter() {
        guard isAvailable else { return }
        dispatchPrecondition(condition: .onQueue(.main))
        shared.impactRigid.impactOccurred()
    }

    static func focusLocked() {
        guard isAvailable else { return }
        dispatchPrecondition(condition: .onQueue(.main))
        shared.notification.notificationOccurred(.success)
    }

    static func selectionChanged() {
        guard isAvailable else { return }
        dispatchPrecondition(condition: .onQueue(.main))
        shared.selection.selectionChanged()
    }

    static func light() {
        guard isAvailable else { return }
        dispatchPrecondition(condition: .onQueue(.main))
        shared.impactLight.impactOccurred()
    }

    static func medium() {
        guard isAvailable else { return }
        dispatchPrecondition(condition: .onQueue(.main))
        shared.impactMedium.impactOccurred()
    }

    static func error() {
        guard isAvailable else { return }
        dispatchPrecondition(condition: .onQueue(.main))
        shared.notification.notificationOccurred(.error)
    }

    /// Sharp mechanical "click" for a rotary-dial detent — `.rigid` impact with tunable
    /// intensity so major (labeled) detents feel firmer than intermediate ones. Uses the
    /// pre-warmed `impactRigid` generator directly rather than a hand-rolled CHHapticEngine:
    /// generators are reliable under rapid repeated fire (many detents/sec during a fast
    /// drag) where starting/restarting a raw engine per-event is not.
    static func dialDetent(major: Bool) {
        guard isAvailable else { return }
        dispatchPrecondition(condition: .onQueue(.main))
        shared.impactRigid.impactOccurred(intensity: major ? 1.0 : 0.55)
    }
}
