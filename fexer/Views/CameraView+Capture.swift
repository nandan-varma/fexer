import SwiftUI
import AVFoundation
import CoreImage
import CoreLocation
import Photos
import UIKit
import OSLog

extension CameraView {

    // Thread-safe box so onLivePhotoMovie and the save Task share the URL without data races.
    nonisolated final class MovieURLBox: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: Optional<URL>.none)
        var url: URL? {
            get { lock.withLock { $0 } }
            set { lock.withLock { $0 = newValue } }
        }
    }

    // MARK: - Capture flow

    func captureAction() {
        if cameraViewModel.isTimerActive {
            cameraViewModel.cancelTimer()
            return
        }
        if cameraViewModel.activeMode == .selfTimer && selfTimerDelay > 0 {
            HapticManager.light()
            cameraViewModel.startTimerCapture(delay: Double(selfTimerDelay), repeatCount: selfTimerRepeat) { performCapture() }
        } else {
            performCapture()
        }
    }

    func startVideoRecording() {
        let location = appState.permissionsManager.currentLocation
        let styleName = stylesManager.activeStyle?.name
        cameraManager.startRecording(location: location, styleName: styleName)
    }

    func performCapture() {
        if cameraViewModel.activeMode == .video {
            if cameraManager.isRecording {
                cameraManager.stopRecording()
                recordingStartDate = nil
            } else {
                startVideoRecording()
                recordingStartDate = Date()
            }
            HapticManager.medium()
            return
        }
        if cameraViewModel.activeMode == .longExposure {
            performLongExposureCapture()
            return
        }
        // Screen flash for front-facing camera (no hardware flash on front)
        let isFront = cameraManager.currentDevice?.position == .front
        if isFront && cameraManager.flashMode != .off,
           let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            let screen = scene.screen
            let originalBrightness = screen.brightness
            screen.brightness = 1.0
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                screen.brightness = originalBrightness
            }
        }
        HapticManager.shutter()
        triggerShutterFlash()
        let delegate = makeCaptureDelegate()
        activeDelegates[delegate.id] = delegate
        if isWBBracketEnabled {
            cameraManager.capturePhotoBracketedWB(kStep: Float(wbBracketKStep), captureFormat: cameraManager.captureSettings.captureFormat, flash: cameraManager.flashMode, delegate: delegate)
            return
        }
        if isBracketingEnabled {
            cameraManager.capturePhotoBracketed(evStep: Float(bracketEVStep), delegate: delegate)
        } else {
            cameraManager.capturePhoto(delegate: delegate)
        }
    }

    func triggerCameraFlip() {
        // Fade to black to cover the camera-swap artifact, then fade back as new preview appears
        withAnimation(.easeOut(duration: 0.12)) { cameraFlipOpacity = 1 }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            withAnimation(.easeIn(duration: 0.28)) { cameraFlipOpacity = 0 }
        }
    }

    func triggerShutterFlash() {
        shutterFlashOpacity = 1
        Task { @MainActor in
            // Sleep one display frame so SwiftUI renders opacity=1 before starting the fade
            try? await Task.sleep(nanoseconds: 16_700_000)
            withAnimation(.easeOut(duration: 0.25)) {
                shutterFlashOpacity = 0
            }
        }
    }

    func performLongExposureCapture() {
        guard !cameraManager.processor.isLongExposureCapturing else { return }
        HapticManager.shutter()
        triggerShutterFlash()
        let location = appState.permissionsManager.currentLocation
        let captureFilter = stylesManager.makeCaptureFilter()
        let capturedCropRatio = cropRatio
        let capturedWatermark = watermarkText

        cameraManager.processor.beginLongExposureCapture(duration: longExposureDuration) { ciImage in
            Task { @MainActor in
                await self.saveLongExposureImage(
                    ciImage, filter: captureFilter,
                    cropRatio: capturedCropRatio, watermark: capturedWatermark,
                    location: location
                )
            }
        }
    }

    func saveLongExposureImage(_ ciImage: CIImage, filter: LUTFilter?,
                               cropRatio: CropRatio, watermark: String,
                               location: CLLocation?) async {
        var out = ciImage
        if let f = filter {
            f.inputImage = out
            out = f.outputImage ?? out
        }
        // Crop in CI space — free transform on the lazy CIImage graph, no extra decode/encode
        if cropRatio != .full, let aspect = cropRatio.portraitAspect {
            out = CaptureImagePipeline.centerCropped(out, toAspect: aspect)
        }
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
              var cg = CIContext.shared.createCGImage(out, from: out.extent, format: .RGBA8, colorSpace: sRGB)
        else { return }

        // Apply watermark onto the rendered CGImage — no second JPEG decode needed
        if !watermark.isEmpty {
            cg = CaptureImagePipeline.watermarked(cg, text: watermark)
        }

        guard let jpeg = UIImage(cgImage: cg).jpegData(compressionQuality: 0.95) else { return }

        let assetID: String? = await withCheckedContinuation { cont in
            var capturedID: String?
            PHPhotoLibrary.shared().performChanges({
                let req = PHAssetCreationRequest.forAsset()
                req.addResource(with: .photo, data: jpeg, options: nil)
                req.location = location
                capturedID = req.placeholderForCreatedAsset?.localIdentifier
            }) { success, error in
                if let error { Logger.camera.error("Long exposure save: \(error.localizedDescription)") }
                cont.resume(returning: success ? capturedID : nil)
            }
        }

        HapticManager.light()
        lastCapturedThumb = UIImage(data: jpeg)?.preparingThumbnail(of: CGSize(width: 200, height: 200))
        let photo = CapturedPhoto(
            jpegData: jpeg,
            captureSettings: cameraManager.captureSettings,
            location: location,
            assetLocalIdentifier: assetID
        )
        capturedPhoto = photo
        if showReviewAfterShot {
            withAnimation(.easeInOut(duration: 0.3)) { showReview = true }
        }
    }

    // MARK: - Capture delegate

    func makeCaptureDelegate() -> CapturePhotoDelegate {
        let captureLocation = appState.permissionsManager.currentLocation
        let activeStyle = stylesManager.activeStyle
        let styleIntensity = stylesManager.styleIntensity
        let captureSettings = cameraManager.captureSettings
        let captureFilter = stylesManager.makeCaptureFilter()
        let capturedCropRatio = cropRatio
        let capturedWatermark = watermarkText
        let isAnamorphic = cameraManager.processor.isAnamorphicDesqueezeEnabled
        let isPortraitMode = cameraViewModel.activeMode == .portrait
        let movieBox = MovieURLBox()
        let onShowReview: (CapturedPhoto) -> Void = { [self] photo in
            capturedPhoto = photo
            if showReviewAfterShot {
                withAnimation(.easeInOut(duration: 0.3)) { showReview = true }
            }
        }
        let onThumbGenerated: (UIImage?) -> Void = { [self] thumb in
            if let thumb { lastCapturedThumb = thumb }
        }

        let delegate = CapturePhotoDelegate(
            onProcessed: { photo, shouldShowReview in
                guard let rawData = photo.fileDataRepresentation() else {
                    Logger.camera.error("fileDataRepresentation returned nil")
                    return
                }
                // Return immediately so AVFoundation fires didFinishCaptureFor (and clears
                // isCapturing) as soon as the sensor is done — not after post-processing.
                Task.detached(priority: .userInitiated) {
                    let depthData: AVDepthData? = isPortraitMode ? photo.depthData : nil
                    let processedData = CaptureImagePipeline.process(
                        rawData: rawData,
                        options: CaptureImagePipeline.Options(
                            isRaw: photo.isRawPhoto,
                            captureFilter: captureFilter,
                            isAnamorphic: isAnamorphic,
                            cropRatio: capturedCropRatio,
                            watermark: capturedWatermark,
                            activeStyle: activeStyle,
                            depthData: depthData
                        )
                    )

                    // Generate gallery-button thumbnail for all (non-RAW) captures
                    if !photo.isRawPhoto {
                        let thumb = UIImage(data: processedData)?.preparingThumbnail(of: CGSize(width: 200, height: 200))
                        await MainActor.run { onThumbGenerated(thumb) }
                    }

                    guard shouldShowReview else {
                        saveToPhotoLibrary(data: processedData, photo: photo,
                                           location: captureLocation, livePhotoMovieURL: movieBox.url)
                        return
                    }

                    // For review captures: save first to get the asset identifier for delete support
                    let assetID: String? = await withCheckedContinuation { cont in
                        saveToPhotoLibrary(data: processedData, photo: photo,
                                           location: captureLocation, livePhotoMovieURL: movieBox.url) { id in
                            cont.resume(returning: id)
                        }
                    }
                    await MainActor.run {
                        let captured = CapturedPhoto(
                            jpegData: processedData,
                            captureSettings: captureSettings,
                            appliedStyle: activeStyle,
                            styleIntensity: styleIntensity,
                            location: captureLocation,
                            exifMetadata: photo.metadata,
                            assetLocalIdentifier: assetID
                        )
                        onShowReview(captured)
                    }
                }
            },
            onCaptureDone: { [cameraManager] delegateID in
                cameraManager.clearCaptureGuard()
                Task { @MainActor [self] in
                    activeDelegates.removeValue(forKey: delegateID)
                }
            }
        )
        delegate.onLivePhotoMovie = { movieBox.url = $0 }
        return delegate
    }
}
