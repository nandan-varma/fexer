import CoreLocation
import Observation

@MainActor @Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private(set) var location: GeoTag?
    private(set) var denied = false
    private var enabled = false
    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }
    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        guard enabled else { manager.stopUpdatingLocation(); location = nil; return }
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        else { updateAuthorization() }
    }
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.updateAuthorization() }
    }
    private func updateAuthorization() {
        denied = manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted
        if enabled, manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            manager.startUpdatingLocation()
        } else { manager.stopUpdatingLocation(); location = nil }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last, latest.horizontalAccuracy >= 0, abs(latest.timestamp.timeIntervalSinceNow) < 60 else { return }
        let tag = GeoTag(latitude: latest.coordinate.latitude, longitude: latest.coordinate.longitude,
                          altitude: latest.verticalAccuracy >= 0 ? latest.altitude : nil)
        Task { @MainActor in
            guard self.enabled else { return }
            self.location = tag
        }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        Diagnostics.report(error, operation: "Read location")
    }
}
