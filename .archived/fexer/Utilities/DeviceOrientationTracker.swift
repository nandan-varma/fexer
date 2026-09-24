import SwiftUI
import UIKit

@Observable
final class DeviceOrientationTracker {
    static let shared = DeviceOrientationTracker()

    var rotationAngle: Double = 0

    private var observer: NSObjectProtocol?

    private init() {}

    func start() {
        guard observer == nil else { return }
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        observer = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            let angle: Double
            switch UIDevice.current.orientation {
            case .landscapeLeft:      angle = 90
            case .landscapeRight:     angle = -90
            case .portraitUpsideDown: angle = 180
            default:                  angle = 0
            }
            self?.rotationAngle = angle
        }
    }

    func stop() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }
}
