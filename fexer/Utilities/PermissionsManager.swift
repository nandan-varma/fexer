import AVFoundation
import CoreLocation
import CoreMotion
import Observation
import OSLog
import Photos

@Observable
final class PermissionsManager: NSObject {
    var cameraStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    var microphoneStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    var photoLibraryStatus: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)
    var locationStatus: CLAuthorizationStatus = .notDetermined
    var currentLocation: CLLocation?

    static let isMotionAvailable: Bool = CMMotionManager().isDeviceMotionAvailable

    private let locationManager = CLLocationManager()

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationStatus = locationManager.authorizationStatus
        if locationStatus == .authorizedWhenInUse || locationStatus == .authorizedAlways {
            locationManager.startUpdatingLocation()
        }
    }

    var allGranted: Bool {
        cameraStatus == .authorized &&
        photoLibraryStatus == .authorized &&
        (microphoneStatus == .authorized || microphoneStatus == .notDetermined) &&
        (locationStatus == .authorizedWhenInUse || locationStatus == .authorizedAlways || locationStatus == .notDetermined)
    }

    func requestCameraAccess() async {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        await MainActor.run {
            cameraStatus = granted ? .authorized : .denied
        }
    }

    func requestMicrophoneAccess() async {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        await MainActor.run {
            microphoneStatus = granted ? .authorized : .denied
        }
    }

    func requestPhotoLibraryAccess() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        await MainActor.run {
            photoLibraryStatus = status
        }
    }

    func requestLocationAccess() {
        locationManager.requestWhenInUseAuthorization()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in self.currentLocation = loc }
    }

    func requestAllPermissions() async {
        await requestCameraAccess()
        await requestMicrophoneAccess()
        await requestPhotoLibraryAccess()
        requestLocationAccess()
    }
}

extension PermissionsManager: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.locationStatus = status
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                manager.startUpdatingLocation()
            }
        }
    }
}
