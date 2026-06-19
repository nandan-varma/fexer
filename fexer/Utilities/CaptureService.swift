import Photos
import AVFoundation
import UniformTypeIdentifiers
import OSLog

func saveToPhotoLibrary(data: Data, photo: AVCapturePhoto, location: CLLocation?) {
    let save = {
        PHPhotoLibrary.shared().performChanges({
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.uniformTypeIdentifier = photo.isRawPhoto
                ? AVFileType.dng.rawValue
                : UTType.jpeg.identifier
            request.addResource(with: .photo, data: data, options: options)
            request.location = location
        }) { _, error in
            if let error { Logger.camera.error("Photo save failed: \(error.localizedDescription)") }
        }
    }

    let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
    if status == .notDetermined {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { granted in
            if granted == .authorized || granted == .limited { save() }
        }
    } else if status == .authorized || status == .limited {
        save()
    } else {
        Logger.camera.error("Photo library access denied — cannot save")
    }
}
