// swiftlint:disable file_length
import AVFoundation
import CoreImage
import CoreLocation
import OSLog
import Photos
import UIKit

extension CameraManager {

    // MARK: - Video Recording

    // swiftlint:disable:next function_body_length
    func startRecording(location: CLLocation? = nil, styleName: String? = nil) {
        let t0 = CFAbsoluteTimeGetCurrent()
        Logger.camera.info("⏱ rec[0] MainActor begin")

        // Respond to the tap immediately on MainActor — shutter button switches to "stop"
        // and the timer starts right away. The actual encoder init happens asynchronously
        // on writerSetupQueue so neither sessionQueue nor MainActor ever blocks.
        recordingError = nil
        isRecording = true
        startRecordingTimer()
        UIApplication.shared.isIdleTimerDisabled = true

        Logger.camera.info("⏱ rec[1] MainActor done: \(String(format: "%.1f", (CFAbsoluteTimeGetCurrent()-t0)*1000))ms")

        let captureSnap = captureSettings
        let proResOK = isProResRecordingSupported
        // previewImageSize is the portrait-rotated frame size delivered by captureOutput.
        // Falls back to resolution-derived size if the camera hasn't warmed up yet.
        let frameSize: CGSize = previewImageSize != .zero ? previewImageSize : {
            switch captureSnap.videoSettings.resolution {
            case .uhd4K: return CGSize(width: 2160, height: 3840)
            default:     return CGSize(width: 1080, height: 1920)
            }
        }()

        Logger.camera.info("⏱ rec[2] dispatching to sessionQueue: \(String(format: "%.1f", (CFAbsoluteTimeGetCurrent()-t0)*1000))ms (frameSize=\(Int(frameSize.width))×\(Int(frameSize.height)))")

        sessionQueue.async { [self] in
            Logger.camera.info("⏱ rec[3] sessionQueue start: \(String(format: "%.0f", (CFAbsoluteTimeGetCurrent()-t0)*1000))ms")
            guard !isWaitingToRecord && !isFinishingRecording && assetWriter == nil else {
                Logger.camera.warning("⏱ rec[3] guard failed: isWaiting=\(self.isWaitingToRecord) isFinishing=\(self.isFinishingRecording) hasWriter=\(self.assetWriter != nil)")
                return
            }

            let captureDate = iso8601Formatter.string(from: Date())
            pendingRecordingLocation = location
            pendingRecordingStyleName = styleName

            // ── Fast path: use the pre-built writer if settings match ──────────────
            let prebuilt = prebuiltWriterEntry
            let settingsMatch = prebuilt.map {
                $0.fps == captureSnap.videoSettings.frameRate &&
                $0.resolution == captureSnap.videoSettings.resolution &&
                $0.codec == captureSnap.videoSettings.codec
            } ?? false

            if let prebuilt, settingsMatch {
                prebuiltWriterEntry = nil
                Logger.camera.info("⏱ rec[FAST] ✅ prebuilt writer matched — 0ms startWriting, total: \(String(format: "%.0f", (CFAbsoluteTimeGetCurrent()-t0)*1000))ms")

                // Update metadata with actual record-time values (location, style, timestamp).
                // writer.metadata can be updated after startWriting() but before startSession().
                prebuilt.components.writer.metadata = makeVideoMetadata(
                    settings: captureSnap, location: location, styleName: styleName,
                    captureDate: captureDate
                )

                isWaitingToRecord = true
                assetWriter = prebuilt.components.writer
                videoWriterInput = prebuilt.components.videoInput
                audioWriterInput = prebuilt.components.audioInput
                pixelBufferAdaptor = prebuilt.components.adaptor

                processor.onProcessedFrame = { [weak self] ciImage, time in
                    guard let self else { return }
                    if self.isWaitingToRecord {
                        Logger.camera.info("⏱ rec[FAST] first frame → startSession: \(String(format: "%.0f", (CFAbsoluteTimeGetCurrent()-t0)*1000))ms")
                        self.isWaitingToRecord = false
                        self.assetWriter?.startSession(atSourceTime: time)
                        Logger.camera.info("⏱ rec[FAST] recording live: \(String(format: "%.0f", (CFAbsoluteTimeGetCurrent()-t0)*1000))ms")
                    }
                    self.appendVideoFrame(ciImage, time: time)
                }
                audioOutput.setSampleBufferDelegate(self, queue: sessionQueue)
                // Rebuild prebuilt for the next recording while this one runs
                Task { @MainActor in self.schedulePrebuiltWriter() }
                return
            }

            // ── Slow path: build on writerSetupQueue (non-blocking, sessionQueue free) ──
            Logger.camera.info("⏱ rec[4] no prebuilt match (\(prebuilt == nil ? "nil" : "fps/res/codec mismatch")), dispatching to writerSetupQueue: \(String(format: "%.0f", (CFAbsoluteTimeGetCurrent()-t0)*1000))ms")
            let snapshotLocation = location
            let snapshotStyleName = styleName
            isWaitingToRecord = true

            // Coalescence: if schedulePrebuiltWriter is already running its startWriting()
            // on writerSetupQueue, don't queue a second build behind it — that would double
            // the wait. Instead, register a closure that the prebuilt's hop-back will call
            // immediately when it lands on sessionQueue, handing the writer straight to us.
            if isPrebuiltBuilding {
                Logger.camera.info("⏱ rec[4-COALESCE] prebuilt building — piggybacking, skipping 2nd writerSetupQueue dispatch")
                pendingRecordOnPrebuiltComplete = { [self] components in
                    guard isWaitingToRecord else {
                        components.writer.cancelWriting()
                        Logger.camera.info("⏱ rec[COALESCE] cancelled (stopRecording won the race)")
                        return
                    }
                    Logger.camera.info("⏱ rec[COALESCE] writer installed from prebuilt: \(String(format: "%.0f", (CFAbsoluteTimeGetCurrent()-t0)*1000))ms")
                    assetWriter = components.writer
                    videoWriterInput = components.videoInput
                    audioWriterInput = components.audioInput
                    pixelBufferAdaptor = components.adaptor
                    processor.onProcessedFrame = { [weak self] ciImage, time in
                        guard let self else { return }
                        if self.isWaitingToRecord {
                            Logger.camera.info("⏱ rec[COALESCE] first frame → startSession: \(String(format: "%.0f", (CFAbsoluteTimeGetCurrent()-t0)*1000))ms")
                            self.isWaitingToRecord = false
                            self.assetWriter?.startSession(atSourceTime: time)
                            Logger.camera.info("⏱ rec[COALESCE] recording live: \(String(format: "%.0f", (CFAbsoluteTimeGetCurrent()-t0)*1000))ms")
                        }
                        self.appendVideoFrame(ciImage, time: time)
                    }
                    audioOutput.setSampleBufferDelegate(self, queue: sessionQueue)
                    Task { @MainActor in self.schedulePrebuiltWriter() }
                }
                return
            }

            writerSetupQueue.async { [self] in
                Logger.camera.info("⏱ rec[5] writerSetupQueue start: \(String(format: "%.0f", (CFAbsoluteTimeGetCurrent()-t0)*1000))ms")
                let tBuild = CFAbsoluteTimeGetCurrent()
                guard let components = buildWriterComponents(
                    frameSize: frameSize, captureSettings: captureSnap, proResOK: proResOK,
                    location: snapshotLocation, styleName: snapshotStyleName, captureDate: captureDate
                ) else {
                    Logger.camera.error("⏱ rec[5] buildWriterComponents FAILED: \(String(format: "%.0f", (CFAbsoluteTimeGetCurrent()-t0)*1000))ms")
                    sessionQueue.async { [self] in isWaitingToRecord = false }
                    Task { @MainActor in
                        self.isRecording = false
                        self.stopRecordingTimer()
                        self.recordingError = NSError(
                            domain: "com.fexer", code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "Failed to initialize video writer"])
                    }
                    return
                }
                Logger.camera.info("⏱ rec[6] build done: total=\(String(format: "%.0f", (CFAbsoluteTimeGetCurrent()-t0)*1000))ms build=\(String(format: "%.0f", (CFAbsoluteTimeGetCurrent()-tBuild)*1000))ms")

                sessionQueue.async { [self] in
                    Logger.camera.info("⏱ rec[7] writer install: \(String(format: "%.0f", (CFAbsoluteTimeGetCurrent()-t0)*1000))ms")
                    guard isWaitingToRecord else {
                        components.writer.cancelWriting()
                        Logger.camera.info("⏱ rec[7] cancelled (stopRecording won the race)")
                        return
                    }
                    assetWriter = components.writer
                    videoWriterInput = components.videoInput
                    audioWriterInput = components.audioInput
                    pixelBufferAdaptor = components.adaptor

                    processor.onProcessedFrame = { [weak self] ciImage, time in
                        guard let self else { return }
                        if self.isWaitingToRecord {
                            Logger.camera.info("⏱ rec[8] first frame → startSession: \(String(format: "%.0f", (CFAbsoluteTimeGetCurrent()-t0)*1000))ms")
                            self.isWaitingToRecord = false
                            self.assetWriter?.startSession(atSourceTime: time)
                            Logger.camera.info("⏱ rec[9] recording live: \(String(format: "%.0f", (CFAbsoluteTimeGetCurrent()-t0)*1000))ms")
                        }
                        self.appendVideoFrame(ciImage, time: time)
                    }
                    let tAudio = CFAbsoluteTimeGetCurrent()
                    audioOutput.setSampleBufferDelegate(self, queue: sessionQueue)
                    Logger.camera.info("⏱ rec[7b] setSampleBufferDelegate: \(String(format: "%.1f", (CFAbsoluteTimeGetCurrent()-tAudio)*1000))ms, total: \(String(format: "%.0f", (CFAbsoluteTimeGetCurrent()-t0)*1000))ms")
                }
            }
        }
    }

    func stopRecording() {
        sessionQueue.async { [self] in
            let wasWaiting = isWaitingToRecord
            isWaitingToRecord = false
            processor.onProcessedFrame = nil
            audioOutput.setSampleBufferDelegate(nil, queue: nil)
            Task { @MainActor in
                self.isRecording = false
                self.recordingDuration = 0
                self.stopRecordingTimer()
                UIApplication.shared.isIdleTimerDisabled = false
            }
            guard let writer = assetWriter else {
                // assetWriter is nil when stopRecording races with writerSetupQueue building the
                // writer. isWaitingToRecord = false above signals the hop-back on sessionQueue
                // to call cancelWriting() instead of installing the writer.
                pendingRecordingLocation = nil
                pendingRecordingStyleName = nil
                return
            }

            if wasWaiting {
                // Writer was installed but startSession was never called (no video frame arrived).
                // cancelWriting is required here — finishWriting on a writer without an active
                // session throws NSInternalInconsistencyException.
                writer.cancelWriting()
                assetWriter = nil
                videoWriterInput = nil
                audioWriterInput = nil
                pixelBufferAdaptor = nil
                pendingRecordingLocation = nil
                pendingRecordingStyleName = nil
            } else {
                isFinishingRecording = true
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
                    defer { self.sessionQueue.async { self.isFinishingRecording = false } }
                    guard writer.status == .completed else {
                        let err = writer.error
                        Logger.camera.error("Video writing failed: \(err?.localizedDescription ?? "unknown")")
                        Task { @MainActor in self.recordingError = err }
                        return
                    }
                    performPhotoLibraryChange {
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
                    // Rebuild prebuilt writer while user reviews/edits the clip, ready for next tap.
                    Task { @MainActor in self.schedulePrebuiltWriter() }
                }
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

    struct WriterComponents {
        let writer: AVAssetWriter
        let videoInput: AVAssetWriterInput
        let audioInput: AVAssetWriterInput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
    }

    // sessionQueue-only; stored between video mode entry and first record tap.
    struct PrebuiltWriterEntry {
        let components: WriterComponents
        let fps: Int
        let resolution: VideoResolution
        let codec: VideoCodec
    }

    // MARK: - Prebuilt writer (zero startWriting latency for first record tap)

    /// Starts building a writer at current video settings on writerSetupQueue, stores it
    /// in prebuiltWriterEntry. When startRecording sees a settings match it installs the
    /// prebuilt directly — skipping startWriting() entirely on the hot path.
    /// If startRecording arrives while the prebuilt is still building, it registers a
    /// pendingRecordOnPrebuiltComplete closure instead of queuing a second build.
    func schedulePrebuiltWriter() {
        let snap = captureSettings
        let proResOK = isProResRecordingSupported
        let frameSize: CGSize = previewImageSize != .zero ? previewImageSize : {
            switch snap.videoSettings.resolution {
            case .uhd4K: return CGSize(width: 2160, height: 3840)
            default:     return CGSize(width: 1080, height: 1920)
            }
        }()
        let targetFPS = snap.videoSettings.frameRate
        let targetRes = snap.videoSettings.resolution
        let targetCodec = snap.videoSettings.codec
        Logger.camera.info("⏱ prebuilt[0]: scheduling \(targetFPS)fps \(targetRes.rawValue) \(targetCodec.rawValue)")

        sessionQueue.async { [self] in
            if let stale = prebuiltWriterEntry {
                stale.components.writer.cancelWriting()
                prebuiltWriterEntry = nil
                Logger.camera.info("⏱ prebuilt[1]: cancelled stale stored writer")
            }
            // If already building, let the in-flight build finish — its completion will
            // call pendingRecordOnPrebuiltComplete if a record tap is waiting.
            guard !isPrebuiltBuilding else {
                Logger.camera.info("⏱ prebuilt[1]: build already in progress, skipping duplicate")
                return
            }
            guard !isWaitingToRecord && !isFinishingRecording && assetWriter == nil else {
                Logger.camera.info("⏱ prebuilt[1]: skipped — recording in progress")
                return
            }
            isPrebuiltBuilding = true
            Task { @MainActor in self.isVideoWriterReady = false }
            let captureDate = iso8601Formatter.string(from: Date())

            writerSetupQueue.async { [self] in
                let t = CFAbsoluteTimeGetCurrent()
                Logger.camera.info("⏱ prebuilt[2]: building \(targetFPS)fps on writerSetupQueue…")
                guard let components = buildWriterComponents(
                    frameSize: frameSize, captureSettings: snap, proResOK: proResOK,
                    location: nil, styleName: nil, captureDate: captureDate
                ) else {
                    Logger.camera.error("⏱ prebuilt[2]: buildWriterComponents failed")
                    sessionQueue.async { [self] in
                        isPrebuiltBuilding = false
                        pendingRecordOnPrebuiltComplete = nil
                    }
                    return
                }
                Logger.camera.info("⏱ prebuilt[3]: startWriting done in \(String(format: "%.0f", (CFAbsoluteTimeGetCurrent()-t)*1000))ms")

                sessionQueue.async { [self] in
                    isPrebuiltBuilding = false
                    // If a record tap arrived while we were building, hand the writer to it directly.
                    if let pending = pendingRecordOnPrebuiltComplete {
                        pendingRecordOnPrebuiltComplete = nil
                        Logger.camera.info("⏱ prebuilt[4]: coalesced pending record tap — installing now")
                        pending(components)
                        return
                    }
                    guard !isWaitingToRecord && !isFinishingRecording && assetWriter == nil else {
                        components.writer.cancelWriting()
                        Logger.camera.info("⏱ prebuilt[4]: discarded — recording started during build")
                        return
                    }
                    if let stale = prebuiltWriterEntry { stale.components.writer.cancelWriting() }
                    prebuiltWriterEntry = PrebuiltWriterEntry(
                        components: components, fps: targetFPS,
                        resolution: targetRes, codec: targetCodec
                    )
                    Logger.camera.info("⏱ prebuilt[4]: ✅ stored — next record tap will be instant")
                    Task { @MainActor in self.isVideoWriterReady = true }
                }
            }
        }
    }

    /// Cancels the prebuilt writer and any pending coalesced record. Call when leaving video mode.
    func cancelPrebuiltWriter() {
        sessionQueue.async { [self] in
            pendingRecordOnPrebuiltComplete = nil
            if let stale = prebuiltWriterEntry {
                stale.components.writer.cancelWriting()
                prebuiltWriterEntry = nil
                Logger.camera.info("⏱ prebuilt: cancelled (left video mode)")
            }
            Task { @MainActor in self.isVideoWriterReady = false }
        }
    }

    // Runs on writerSetupQueue — must not access any nonisolated(unsafe) instance vars.
    // All inputs are value-type snapshots taken on sessionQueue before dispatch.
    private func buildWriterComponents(
        frameSize: CGSize, captureSettings: CaptureSettings, proResOK: Bool,
        location: CLLocation?, styleName: String?, captureDate: String
    ) -> WriterComponents? {
        let width = Int(frameSize.width)
        let height = Int(frameSize.height)
        let settings = captureSettings.videoSettings
        let fps = settings.frameRate
        let codec = settings.codec
        let useProRes = codec == .proRes && proResOK
        let fileType: AVFileType = useProRes ? .mov : .mp4

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(useProRes ? "mov" : "mp4")

        guard let writer = try? AVAssetWriter(url: url, fileType: fileType) else {
            Logger.camera.error("Failed to create AVAssetWriter")
            return nil
        }

        // Video codec — ProRes skips compression properties (uses its own quality tiers)
        let codecType: AVVideoCodecType = codec == .h264 ? .h264 : useProRes ? .proRes422HQ : .hevc
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
            return nil
        }
        writer.add(videoInput)
        writer.add(audioInput)
        writer.metadata = makeVideoMetadata(
            settings: captureSettings,
            location: location,
            styleName: styleName,
            captureDate: captureDate
        )

        // Warm up the CIContext→CVPixelBuffer render path so Metal shader compilation
        // doesn't happen on the first real appendVideoFrame call mid-recording.
        // This path (render to pixelBuffer) is separate from the preview path
        // (render to MTKView texture) so shaders may not be pre-compiled yet.
        var warmPB: CVPixelBuffer?
        if CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &warmPB) == kCVReturnSuccess,
           let warmPixelBuffer = warmPB {
            let warmImg = CIImage(color: CIColor(red: 0, green: 0, blue: 0))
                .cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))
            CIContext.shared.render(warmImg, to: warmPixelBuffer)
        }

        let tSW = CFAbsoluteTimeGetCurrent()
        writer.startWriting()
        Logger.camera.info("⏱ startWriting took: \(String(format: "%.0f", (CFAbsoluteTimeGetCurrent()-tSW)*1000))ms — \(width)×\(height) \(fps)fps \(codecType.rawValue)")
        return WriterComponents(writer: writer, videoInput: videoInput, audioInput: audioInput, adaptor: adaptor)
    }

    func makeVideoMetadata(
        settings: CaptureSettings,
        location: CLLocation?,
        styleName: String?,
        captureDate: String
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
                          value: captureDate as NSString))
        items.append(item(identifier: .quickTimeMetadataMake, value: "Apple" as NSString))
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
        guard let writer = assetWriter, writer.status == .writing,
              let input = videoWriterInput,
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
        // Write to asset when recording. !isWaitingToRecord guards against appending before
        // startSession is called — audio fires immediately after setSampleBufferDelegate but
        // the first video frame hasn't called startSession yet.
        if let input = audioWriterInput,
           input.isReadyForMoreMediaData,
           !isWaitingToRecord,
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
        audioSampleCount &+= 1
        if audioSampleCount % 5 == 0 {
            Task { @MainActor in self.audioLevel = self.audioLevel * 0.7 + rms * 0.3 }
        }
    }
}
