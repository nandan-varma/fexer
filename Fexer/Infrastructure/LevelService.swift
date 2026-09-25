import CoreMotion
import Observation

@MainActor @Observable
final class LevelService {
    // Same reasoning as LocationService: CMMotionManager() connects to a system daemon on
    // construction — deferred until the level indicator is actually turned on (off by default).
    private var manager: CMMotionManager?
    private(set) var roll: Double = 0

    func setEnabled(_ enabled: Bool) {
        guard enabled else {
            manager?.stopDeviceMotionUpdates()
            roll = 0
            return
        }
        let manager = self.manager ?? {
            let created = Diagnostics.time("level.createManager") { CMMotionManager() }
            self.manager = created
            return created
        }()
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 30
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            // Roll of the phone held upright in portrait, measured against gravity.
            self.roll = atan2(motion.gravity.x, -motion.gravity.y)
        }
    }
}
