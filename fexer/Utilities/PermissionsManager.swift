import AVFoundation
import Photos
import CoreLocation
import CoreMotion
import Observation

@Observable
final class PermissionsManager: NSObject {
    var cameraStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    var microphoneStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    var photoLibraryStatus: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)
    var locationStatus: CLAuthorizationStatus = .notDetermined
    var motionAvailable: Bool = CMMotionManager().isDeviceMotionAvailable
    var currentLocation: CLLocation?

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
        photoLibraryStatus == .authorized
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
        currentLocation = locations.last
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
        locationStatus = manager.authorizationStatus
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }
}
