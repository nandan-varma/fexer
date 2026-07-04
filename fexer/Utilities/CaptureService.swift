import Photos
import AVFoundation
import UniformTypeIdentifiers
import OSLog

nonisolated func saveToPhotoLibrary(data: Data, photo: AVCapturePhoto, location: CLLocation?,
                        livePhotoMovieURL: URL? = nil,
                        completion: ((String?) -> Void)? = nil) {
    let save = {
        var capturedID: String?
        PHPhotoLibrary.shared().performChanges({
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.uniformTypeIdentifier = photo.isRawPhoto
                ? AVFileType.dng.rawValue
                : UTType.jpeg.identifier
            request.addResource(with: .photo, data: data, options: options)
            if let movieURL = livePhotoMovieURL {
                let movOpts = PHAssetResourceCreationOptions()
                movOpts.shouldMoveFile = true
                request.addResource(with: .pairedVideo, fileURL: movieURL, options: movOpts)
            }
            request.location = location
            capturedID = request.placeholderForCreatedAsset?.localIdentifier
        }) { success, error in
            if let error { Logger.camera.error("Photo save failed: \(error.localizedDescription)") }
            completion?(success ? capturedID : nil)
        }
    }

    let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
    if status == .notDetermined {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { granted in
            if granted == .authorized || granted == .limited {
                save()
            } else {
                completion?(nil)
            }
        }
    } else if status == .authorized || status == .limited {
        save()
    } else {
        Logger.camera.error("Photo library access denied — cannot save")
        completion?(nil)
    }
}
