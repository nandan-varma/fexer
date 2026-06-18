import AVFoundation
import Photos
import CoreLocation
import CoreMotion
import Observation

@Observable
final class PermissionsManager: NSObject {
    var cameraStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    var photoLibraryStatus: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)
    var locationStatus: CLAuthorizationStatus = .notDetermined
    var motionAvailable: Bool = CMMotionManager().isDeviceMotionAvailable

    private let locationManager = CLLocationManager()

    override init() {
        super.init()
        locationManager.delegate = self
        locationStatus = locationManager.authorizationStatus
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

    func requestPhotoLibraryAccess() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        await MainActor.run {
            photoLibraryStatus = status
        }
    }

    func requestLocationAccess() {
        locationManager.requestWhenInUseAuthorization()
    }

    func requestAllPermissions() async {
        await requestCameraAccess()
        await requestPhotoLibraryAccess()
        requestLocationAccess()
    }
}

extension PermissionsManager: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        locationStatus = manager.authorizationStatus
    }
}
