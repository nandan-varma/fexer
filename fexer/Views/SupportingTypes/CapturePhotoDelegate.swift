import AVFoundation
import Photos
import OSLog

final class CapturePhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    let id: UUID
    private let onProcessed: (AVCapturePhoto, Bool) -> Void
    private let onCaptureDone: (UUID) -> Void
    // Holds the Live Photo .mov URL until didFinishCapture fires
    private var livePhotoMovieURL: URL?

    init(id: UUID = UUID(),
         onProcessed: @escaping (AVCapturePhoto, Bool) -> Void,
         onCaptureDone: @escaping (UUID) -> Void) {
        self.id = id
        self.onProcessed = onProcessed
        self.onCaptureDone = onCaptureDone
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        if let error {
            Logger.camera.error("Capture error: \(error.localizedDescription)")
            return
        }
        var shouldShowReview = true
        if photo.isRawPhoto && photo.resolvedSettings.expectedPhotoCount > 1 {
            shouldShowReview = false
        }
        if let auto = photo.bracketSettings
            as? AVCaptureAutoExposureBracketedStillImageSettings {
            shouldShowReview = abs(auto.exposureTargetBias) < 0.01
        }
        onProcessed(photo, shouldShowReview)
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishRecordingLivePhotoMovieForEventualFileAt outputFileURL: URL,
                     resolvedSettings: AVCaptureResolvedPhotoSettings) {
        livePhotoMovieURL = outputFileURL
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingLivePhotoToMovieFileAt outputFileURL: URL,
                     duration: CMTime,
                     photoDisplayTime: CMTime,
                     resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        if let error {
            Logger.camera.error("Live Photo movie error: \(error.localizedDescription)")
            return
        }
        livePhotoMovieURL = outputFileURL
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        // Save Live Photo .mov paired with HEIC if available
        if let movieURL = livePhotoMovieURL {
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                let opts = PHAssetResourceCreationOptions()
                opts.shouldMoveFile = true
                // PHAssetResourceType.photo and .pairedVideo must share the same request
                request.addResource(with: .pairedVideo, fileURL: movieURL, options: opts)
            }, completionHandler: { _, err in
                if let err { Logger.camera.error("Live Photo .mov save failed: \(err.localizedDescription)") }
            })
        }
        onCaptureDone(id)
    }
}
