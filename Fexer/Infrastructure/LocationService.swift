import CoreLocation
import Observation

@MainActor @Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    // Constructing CLLocationManager() connects to locationd — a real, measurable one-time cost
    // (field logs implicated this in CameraModel's stored-property init). Deferred until location
    // tagging is actually turned on (off by default), instead of paid by every launch regardless.
    private var manager: CLLocationManager?
    private(set) var location: GeoTag?
    private(set) var denied = false
    private var enabled = false
    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        guard enabled else { manager?.stopUpdatingLocation(); location = nil; return }
        let manager = self.manager ?? makeManager()
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        else { updateAuthorization() }
    }
    private func makeManager() -> CLLocationManager {
        let manager = Diagnostics.time("location.createManager") { CLLocationManager() }
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        self.manager = manager
        return manager
    }
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.updateAuthorization() }
    }
    private func updateAuthorization() {
        guard let manager else { return }
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
