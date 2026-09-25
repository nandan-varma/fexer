import AVFoundation
import Foundation
import Synchronization

/// AVFoundation may call delegates on its own queues. A mutex guards every mutable field.
///
/// Every callback logs its arrival time relative to `capturePhoto(with:delegate:)` being called
/// (`start`), so a device log shows the true AVFoundation-side breakdown of a capture: time to
/// shutter fire (`didCapture`), time the ISP spends on Deep Fusion/Smart HDR/etc.
/// (`didCapture` → `didFinishProcessing`), and time to "ready for another capture"
/// (`didFinishCaptureFor`, the actual gate on this app's next `capturePhoto` call).
final class PhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate, Sendable {
    private struct State {
        var processed: Data?
        var raw: Data?
        var movie: URL?
        var error: (any Error)?
        var completion: (@Sendable (Result<PhotoPayload, any Error>) -> Void)?
    }
    private let state: Mutex<State>
    private let start = ContinuousClock.now
    init(completion: @escaping @Sendable (Result<PhotoPayload, any Error>) -> Void) {
        state = Mutex(State(completion: completion))
    }
    func photoOutput(_ output: AVCapturePhotoOutput, willBeginCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        Diagnostics.mark("photo.willBeginCapture", since: start)
    }
    func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        Diagnostics.mark("photo.willCapture (shutter fires)", since: start)
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        Diagnostics.mark("photo.didCapture (sensor read out)", since: start)
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: (any Error)?) {
        Diagnostics.mark("photo.didFinishProcessing (ISP done)", since: start)
        state.withLock {
            if let error { $0.error = error; return }
            guard let bytes = photo.fileDataRepresentation() else { $0.error = AppIssue.captureFailed; return }
            if photo.isRawPhoto { $0.raw = bytes } else { $0.processed = bytes }
        }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingLivePhotoToMovieFileAt outputFileURL: URL,
                     duration: CMTime, photoDisplayTime: CMTime, resolvedSettings: AVCaptureResolvedPhotoSettings, error: (any Error)?) {
        Diagnostics.mark("photo.didFinishLivePhotoMovie", since: start)
        state.withLock {
            if let error { $0.error = error } else { $0.movie = outputFileURL }
        }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: (any Error)?) {
        Diagnostics.mark("photo.didFinishCapture (AVFoundation ready for next)", since: start)
        let result = state.withLock { value -> (Result<PhotoPayload, any Error>, (@Sendable (Result<PhotoPayload, any Error>) -> Void)?) in
            let callback = value.completion
            value.completion = nil
            if let error = error ?? value.error { return (.failure(error), callback) }
            guard let processed = value.processed else { return (.failure(AppIssue.captureFailed), callback) }
            return (.success(PhotoPayload(processed: processed, raw: value.raw, liveMovieURL: value.movie)), callback)
        }
        result.1?(result.0)
    }
}

final class MovieDelegate: NSObject, AVCaptureFileOutputRecordingDelegate, Sendable {
    let completion: @Sendable (Result<URL, any Error>) -> Void
    init(completion: @escaping @Sendable (Result<URL, any Error>) -> Void) { self.completion = completion }
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: (any Error)?) {
        if let error {
            let nsError = error as NSError
            if nsError.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool != true {
                completion(.failure(error)); return
            }
        }
        completion(.success(outputFileURL))
    }
}
