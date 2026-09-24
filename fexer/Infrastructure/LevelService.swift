import CoreMotion
import Observation

@MainActor @Observable
final class LevelService {
    private let manager = CMMotionManager()
    private(set) var roll: Double = 0

    func setEnabled(_ enabled: Bool) {
        guard enabled, manager.isDeviceMotionAvailable else {
            manager.stopDeviceMotionUpdates()
            roll = 0
            return
        }
        guard !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 30
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            // Roll of the phone held upright in portrait, measured against gravity.
            self.roll = atan2(motion.gravity.x, -motion.gravity.y)
        }
    }
}
