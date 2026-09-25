import Foundation
import Observation

/// Extended 4K/60fps recording can heat the device to the point iOS force-stops the capture
/// session outright. A pro camera app surfaces the warning signs before that happens instead of
/// leaving the user to wonder why recording just stopped. No user-facing enable/disable — this
/// is always-on whenever the camera is active, same as the thermal state itself.
@MainActor @Observable
final class ThermalMonitor {
    private(set) var state: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    private var observer: NSObjectProtocol?

    func start() {
        guard observer == nil else { return }
        state = ProcessInfo.processInfo.thermalState
        observer = NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.update() }
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    private func update() {
        let new = ProcessInfo.processInfo.thermalState
        guard new != state else { return }
        state = new
        Diagnostics.camera.notice("Thermal state changed to \(String(describing: new), privacy: .public)")
    }
}
