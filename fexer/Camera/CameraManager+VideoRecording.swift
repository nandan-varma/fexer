import AVFoundation
import CoreImage
import CoreLocation
import Photos
import UIKit
import OSLog

extension CameraManager {

    // MARK: - Video Recording

    func startRecording(location: CLLocation? = nil, styleName: String? = nil) {
        // Snapshot @MainActor settings before crossing to sessionQueue.
        let captureSnap = captureSettings
        let proResOK = isProResRecordingSupported
        sessionQueue.async { [self] in
            pendingRecordingLocation = location
            pendingRecordingStyleName = styleName
            guard !isWaitingToRecord && assetWriter == nil else { return }
            isWaitingToRecord = true
            processor.onProcessedFrame = { [weak self, captureSnap, proResOK] ciImage, time in
                guard let self else { return }
                if self.isWaitingToRecord {
                    self.isWaitingToRecord = false
                    self.setupAssetWriter(firstImage: ciImage, startTime: time,
                                         captureSettings: captureSnap, proResOK: proResOK)
                } else {
                    self.appendVideoFrame(ciImage, time: time)
                }
            }
            audioOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        }
        Task { @MainActor in UIApplication.shared.isIdleTimerDisabled = true }
    }

    func stopRecording() {
        sessionQueue.async { [self] in
            isWaitingToRecord = false
            processor.onProcessedFrame = nil
            audioOutput.setSampleBufferDelegate(nil, queue: nil)
            guard let writer = assetWriter else { return }
            videoWriterInput?.markAsFinished()
            audioWriterInput?.markAsFinished()
            assetWriter = nil
            videoWriterInput = nil
            audioWriterInput = nil
            pixelBufferAdaptor = nil
            let outputURL = writer.outputURL
            let savedLocation = pendingRecordingLocation
            pendingRecordingLocation = nil
            pendingRecordingStyleName = nil
            writer.finishWriting {
                guard writer.status == .completed else {
                    Logger.camera.error("Video writing failed: \(writer.error?.localizedDescription ?? "unknown")")
                    return
                }
                PHPhotoLibrary.shared().performChanges({
                    let request = PHAssetCreationRequest.forAsset()
                    let options = PHAssetResourceCreationOptions()
                    options.shouldMoveFile = true
                    request.addResource(with: .video, fileURL: outputURL, options: options)
                    request.location = savedLocation
                }, completionHandler: { _, error in
                    if let error { Logger.camera.error("Video save failed: \(error.localizedDescription)") }
                })
            }
            Task { @MainActor in
                self.isRecording = false
                self.recordingDuration = 0
                self.stopRecordingTimer()
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
    }

    @MainActor
    func startRecordingTimer() {
        recordingTimer?.invalidate()
        recordingDuration = 0
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.recordingDuration += 1
        }
    }

    @MainActor
    func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
    }

    func setupAssetWriter(firstImage: CIImage, startTime: CMTime,
                          captureSettings: CaptureSettings, proResOK: Bool) {
        let extent = firstImage.extent
        let width = Int(extent.width)
        let height = Int(extent.height)
        let settings = captureSettings.videoSettings
        let fps = settings.frameRate

        let codec = settings.codec
        let useProRes = codec == .proRes && proResOK
        let fileExt  = useProRes ? "mov" : "mp4"
        let fileType = useProRes ? AVFileType.mov : AVFileType.mp4

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExt)

        guard let writer = try? AVAssetWriter(url: url, fileType: fileType) else {
            Logger.camera.error("Failed to create AVAssetWriter")
            return
        }

        // Video codec — ProRes skips compression properties (uses its own quality tiers)
        let codecType: AVVideoCodecType = codec == .h264 ? .h264 :
                                          useProRes ? .proRes422HQ : .hevc
        var videoOutputSettings: [String: Any] = [
            AVVideoCodecKey: codecType,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        if codecType != .proRes422HQ {
            videoOutputSettings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: settings.videoBitRate,
                AVVideoMaxKeyFrameIntervalKey: fps,
                AVVideoExpectedSourceFrameRateKey: fps
            ] as [String: Any]
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoOutputSettings)
        videoInput.expectsMediaDataInRealTime = true

        let pixelAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: pixelAttrs
        )

        // Audio input — AAC at sample rate and bitrate scaled to resolution
        let audioOutputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: settings.audioSampleRate,
            AVEncoderBitRateKey: settings.audioBitRate
        ]
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioOutputSettings)
        audioInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
            Logger.camera.error("Cannot add inputs to AVAssetWriter")
            return
        }
        writer.add(videoInput)
        writer.add(audioInput)
        writer.metadata = makeVideoMetadata(
            settings: captureSettings,
            location: pendingRecordingLocation,
            styleName: pendingRecordingStyleName
        )
        writer.startWriting()
        writer.startSession(atSourceTime: startTime)

        assetWriter = writer
        videoWriterInput = videoInput
        audioWriterInput = audioInput
        pixelBufferAdaptor = adaptor

        appendVideoFrame(firstImage, time: startTime)

        Task { @MainActor in
            self.isRecording = true
            self.startRecordingTimer()
        }
        Logger.camera.info("Video recording started: \(width)×\(height) \(fps)fps \(codecType.rawValue)")
    }

    func makeVideoMetadata(
        settings: CaptureSettings,
        location: CLLocation?,
        styleName: String?
    ) -> [AVMetadataItem] {
        var items: [AVMutableMetadataItem] = []

        func item(identifier: AVMetadataIdentifier, value: NSObject & NSCopying) -> AVMutableMetadataItem {
            let i = AVMutableMetadataItem()
            i.identifier = identifier
            i.value = value
            i.extendedLanguageTag = "und"
            return i
        }

        items.append(item(identifier: .quickTimeMetadataCreationDate,
                          value: iso8601Formatter.string(from: Date()) as NSString))
        items.append(item(identifier: .quickTimeMetadataMake,  value: "Apple" as NSString))
        items.append(item(identifier: .quickTimeMetadataModel, value: deviceModel as NSString))
        items.append(item(identifier: .quickTimeMetadataSoftware, value: "fexer" as NSString))

        if let location {
            let lat = location.coordinate.latitude
            let lon = location.coordinate.longitude
            let iso6709: String
            if location.verticalAccuracy >= 0 {
                iso6709 = String(format: "%+.4f%+.5f%+.0f/", lat, lon, location.altitude)
            } else {
                iso6709 = String(format: "%+.4f%+.5f/", lat, lon)
            }
            items.append(item(identifier: .quickTimeMetadataLocationISO6709, value: iso6709 as NSString))
        }

        func custom(key: String, value: NSObject & NSCopying) -> AVMutableMetadataItem {
            let i = AVMutableMetadataItem()
            i.keySpace = .quickTimeMetadata
            i.key = key as NSString
            i.value = value
            return i
        }
        items.append(custom(key: "com.fexer.camera.iso",
                            value: Int(settings.isoValue) as NSNumber))
        items.append(custom(key: "com.fexer.camera.shutterSpeed",
                            value: CaptureSettings.formatShutterSpeed(
                                CMTimeGetSeconds(settings.shutterSpeed)) as NSString))
        items.append(custom(key: "com.fexer.camera.whiteBalanceKelvin",
                            value: Int(settings.whiteBalance) as NSNumber))
        items.append(custom(key: "com.fexer.camera.whiteBalanceTint",
                            value: Int(settings.whiteBalanceTint) as NSNumber))
        items.append(custom(key: "com.fexer.camera.aperture",
                            value: String(format: "f/%.1f", settings.lensAperture) as NSString))
        if let name = styleName {
            items.append(custom(key: "com.fexer.style", value: name as NSString))
        }
        return items
    }

    func appendVideoFrame(_ ciImage: CIImage, time: CMTime) {
        guard let input = videoWriterInput,
              let adaptor = pixelBufferAdaptor,
              let pool = adaptor.pixelBufferPool,
              input.isReadyForMoreMediaData else { return }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        guard let pixelBuffer = pb else { return }
        CIContext.shared.render(ciImage, to: pixelBuffer)
        adaptor.append(pixelBuffer, withPresentationTime: time)
    }

    /// Checks if the current device supports ProRes recording.
    var isProResRecordingSupported: Bool {
        guard let device = currentDevice else { return false }
        return device.formats.contains { format in
            let sub = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            return sub == kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange ||
                   sub == kCVPixelFormatType_422YpCbCr10BiPlanarFullRange
        }
    }
}

// MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

extension CameraManager: AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        // Write to asset when recording
        if let input = audioWriterInput,
           input.isReadyForMoreMediaData,
           assetWriter?.status == .writing {
            input.append(sampleBuffer)
        }

        // Compute RMS audio level for the VU meter (~10fps update cadence)
        guard let channelData = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        // Use the contiguous segment length, not totalLength — the returned pointer only
        // covers the first segment of a non-contiguous block buffer.
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(channelData, atOffset: 0,
                                    lengthAtOffsetOut: &length, totalLengthOut: nil,
                                    dataPointerOut: &dataPointer)
        guard let ptr = dataPointer, length > 0 else { return }
        let sampleCount = length / MemoryLayout<Int16>.size
        let int16Ptr = UnsafeRawPointer(ptr).bindMemory(to: Int16.self, capacity: sampleCount)
        var sumSq: Float = 0
        for i in 0..<sampleCount {
            let s = Float(int16Ptr[i]) / Float(Int16.max)
            sumSq += s * s
        }
        let rms = sampleCount > 0 ? sqrt(sumSq / Float(sampleCount)) : 0
        Task { @MainActor in self.audioLevel = self.audioLevel * 0.7 + rms * 0.3 }
    }
}
