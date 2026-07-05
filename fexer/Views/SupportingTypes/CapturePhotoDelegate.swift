import AVFoundation
import Photos
import OSLog

final class CapturePhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    let id: UUID
    private let onProcessed: (AVCapturePhoto, Bool) -> Void
    private let onCaptureDone: (UUID) -> Void
    var onLivePhotoMovie: ((URL) -> Void)?

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
            onCaptureDone(id)
            return
        }
        var shouldShowReview = true
        // RAW bytes (DNG) are not displayable as CapturedPhoto.jpegData — never review them.
        // In RAW+JPEG the JPEG callback follows and shows review; in pure RAW there is no review.
        if photo.isRawPhoto {
            shouldShowReview = false
        }
        if let auto = photo.bracketSettings
            as? AVCaptureAutoExposureBracketedStillImageSettings {
            shouldShowReview = abs(auto.exposureTargetBias) < 0.01
        } else if photo.bracketSettings != nil {
            shouldShowReview = true
        }
        onProcessed(photo, shouldShowReview)
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
        onLivePhotoMovie?(outputFileURL)
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        onCaptureDone(id)
    }
}
