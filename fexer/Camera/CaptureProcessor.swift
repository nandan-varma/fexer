import AVFoundation
import CoreImage
import Metal
import MetalKit
import os
import QuartzCore

// CVPixelBuffer is a CF reference type with atomic retain/release on its backing store.
// Swift 6 Sendable checking can't verify CF types automatically, so we assert it manually.
extension CVBuffer: @retroactive @unchecked Sendable {}

/// Processes every video frame from AVCaptureVideoDataOutput.
/// Runs entirely on sessionQueue (background). Never touches MainActor.
///
/// The frame pipeline is: false color → LUT → focus peaking → zebra.
/// Histogram is computed from the pre-filter image every 3rd frame.
final class CaptureProcessor: NSObject {
    /// Latest rendered CIImage for MTKView (thread-safe via OSAllocatedUnfairLock)
    private let imageLock = OSAllocatedUnfairLock(initialState: Optional<CIImage>.none)

    // Histogram / monitoring data published to UI
    var onHistogramUpdate: (([Float], [Float], [Float], [Float]) -> Void)?
    var onWaveformUpdate: ((WaveformData) -> Void)?
    var onVectorscopeUpdate: ((VectorscopeData) -> Void)?
    var onPreviewSizeKnown: ((CGSize) -> Void)?
    /// Called with the raw pixel buffer ~once per second (for thumbnail generation).
    var onPixelBuffer: ((CVPixelBuffer) -> Void)?
    /// Called with the final filtered CIImage and its presentation time.
    /// Used by AVAssetWriter to record video with filters baked in.
    var onProcessedFrame: ((CIImage, CMTime) -> Void)?

    // Filter pipeline state (set from CameraViewModel on main thread, read here)
    private let lutFilterLock = OSAllocatedUnfairLock(initialState: nil as LUTFilter?)

    var lutFilter: LUTFilter? {
        get { lutFilterLock.withLock { $0 } }
        set { lutFilterLock.withLock { $0 = newValue } }
    }

    // Thread-safe zebra time access
    private let zebraTimeLock = OSAllocatedUnfairLock(initialState: Float(0))

    func getZebraTime() -> Float {
        zebraTimeLock.withLock { $0 }
    }

    func setZebraTime(_ time: Float) {
        zebraTimeLock.withLock { $0 = time }
    }

    private let peakingColorLock = OSAllocatedUnfairLock(
        initialState: CIColor(red: 1, green: 0.2, blue: 0.2, alpha: 0.9)
    )

    var peakingColor: CIColor {
        get { peakingColorLock.withLock { $0 } }
        set { peakingColorLock.withLock { $0 = newValue } }
    }

    private let flagsLock = OSAllocatedUnfairLock(
        initialState: (peaking: false, zebra: false, falseColor: false, waveform: false, vectorscope: false)
    )

    var isFocusPeakingEnabled: Bool {
        get { flagsLock.withLock { $0.peaking } }
        set { flagsLock.withLock { $0.peaking = newValue } }
    }
    var isZebraEnabled: Bool {
        get { flagsLock.withLock { $0.zebra } }
        set { flagsLock.withLock { $0.zebra = newValue } }
    }
    var isFalseColorEnabled: Bool {
        get { flagsLock.withLock { $0.falseColor } }
        set { flagsLock.withLock { $0.falseColor = newValue } }
    }
    var isWaveformEnabled: Bool {
        get { flagsLock.withLock { $0.waveform } }
        set { flagsLock.withLock { $0.waveform = newValue } }
    }
    var isVectorscopeEnabled: Bool {
        get { flagsLock.withLock { $0.vectorscope } }
        set { flagsLock.withLock { $0.vectorscope = newValue } }
    }

    // Zebra threshold storage (sessionQueue-safe via lock)
    private let zebraThresholdLock = OSAllocatedUnfairLock(initialState: (high: Float(0.95), low: Float(0.02)))
    var zebraHighThreshold: Float {
        get { zebraThresholdLock.withLock { $0.high } }
        set { zebraThresholdLock.withLock { $0.high = newValue } }
    }
    var zebraLowThreshold: Float {
        get { zebraThresholdLock.withLock { $0.low } }
        set { zebraThresholdLock.withLock { $0.low = newValue } }
    }

    // Anamorphic 2× desqueeze (thread-safe: set from MainActor, read from sessionQueue)
    private let anamorphicLock = OSAllocatedUnfairLock(initialState: false)
    var isAnamorphicDesqueezeEnabled: Bool {
        get { anamorphicLock.withLock { $0 } }
        set { anamorphicLock.withLock { $0 = newValue } }
    }

    // Gates frame delivery until AVFoundation rotation is configured.
    // Frames arriving before rotation is set are landscape — drop them to avoid the boot flash.
    private let rotationReadyLock = OSAllocatedUnfairLock(initialState: false)
    var isRotationReady: Bool {
        get { rotationReadyLock.withLock { $0 } }
        set { rotationReadyLock.withLock { $0 = newValue } }
    }

    // Long exposure frame accumulation — all mutable state below is sessionQueue-only
    // except longExpActiveLock (read/written from caller + sessionQueue)
    private let longExpActiveLock = OSAllocatedUnfairLock(initialState: false)
    // Capped at 60 frames (sampled every 4th at 60fps ≈ 15fps), so peak memory stays ~480 MB
    // instead of the ~1.9 GB that 240 raw frames at 8 MB each would require.
    private var longExpFrames: [CIImage] = []
    private var longExpStart: CMTime = .invalid
    var longExpDuration: Double = 4.0
    var onLongExposureComplete: ((CIImage) -> Void)?

    private let kLongExpMaxFrames = 60
    private let kLongExpFrameSkip = 4  // sample every 4th frame → ~15 fps from 60 fps input

    var isLongExposureCapturing: Bool { longExpActiveLock.withLock { $0 } }

    func beginLongExposureCapture(duration: Double = 4.0, completion: @escaping (CIImage) -> Void) {
        onLongExposureComplete = completion
        longExpDuration = duration
        longExpActiveLock.withLock { $0 = true }
    }

    /// Cancels an in-progress long exposure. Must be called from sessionQueue.
    func cancelLongExposureCapture() {
        longExpActiveLock.withLock { $0 = false }
        longExpFrames = []
        longExpStart = .invalid
        onLongExposureComplete = nil
    }

    private let focusPeakingFilter = FocusPeakingFilter()
    private let zebraFilter = ZebraFilter()
    private let falseColorFilter = FalseColorFilter()
    private var frameCount = 0
    private var reportedSize: CGSize = .zero
    private let histogramQueue = DispatchQueue(label: "com.fexer.histogram", qos: .utility)
    private lazy var ciContext: CIContext = CIContext.shared

    func setLatestImage(_ image: CIImage) {
        imageLock.withLock { $0 = image }
    }

    func getLatestImage() -> CIImage? {
        imageLock.withLock { $0 }
    }
}

extension CaptureProcessor: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard isRotationReady else { return }

        frameCount += 1
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let currentTime = Float(CACurrentMediaTime().truncatingRemainder(dividingBy: 100.0))
        setZebraTime(currentTime)

        var image = CIImage(cvPixelBuffer: pixelBuffer)

        // Anamorphic 2× horizontal desqueeze (applied before all other processing)
        if anamorphicLock.withLock({ $0 }) {
            image = image.transformed(by: CGAffineTransform(scaleX: 2.0, y: 1.0))
        }

        // Report image dimensions once (and again if camera is flipped)
        let size = image.extent.size
        if size != reportedSize {
            reportedSize = size
            onPreviewSizeKnown?(size)
        }

        // Feed raw buffer for thumbnail generation: on first frame and every ~1 s (60 fps ÷ 60)
        if frameCount == 1 || frameCount % 60 == 0 {
            onPixelBuffer?(pixelBuffer)
        }
        let rawImage = image  // snapshot before filter chain for histogram

        // Long exposure: subsample frames to cap memory (kLongExpMaxFrames × ~8 MB ≈ 480 MB).
        // Taking every kLongExpFrameSkip-th frame gives ~15 fps sampling from 60 fps input.
        if longExpActiveLock.withLock({ $0 }) {
            if longExpFrames.isEmpty { longExpStart = presentationTime }
            if frameCount % kLongExpFrameSkip == 0 && longExpFrames.count < kLongExpMaxFrames {
                longExpFrames.append(rawImage)
            }
            if longExpStart.isValid && CMTimeGetSeconds(CMTimeSubtract(presentationTime, longExpStart)) >= longExpDuration {
                longExpActiveLock.withLock { $0 = false }
                let frames = longExpFrames
                longExpFrames = []
                let callback = onLongExposureComplete
                onLongExposureComplete = nil
                histogramQueue.async {
                    if let blended = Self.blendFrames(frames) { callback?(blended) }
                }
            }
        }

        // False color must see the ungraded signal — apply before LUT
        if isFalseColorEnabled {
            falseColorFilter.inputImage = image
            if let output = falseColorFilter.outputImage {
                image = output
            }
        }

        // LUT (skip when false color is active — monitoring tool shows ungraded image)
        if !isFalseColorEnabled {
            let lut = lutFilterLock.withLock { $0 }
            if let lut {
                lut.inputImage = image
                if let output = lut.outputImage {
                    image = output
                }
            }
        }

        // Focus peaking (composited on top of false color if both active)
        if isFocusPeakingEnabled {
            focusPeakingFilter.inputHighlightColor = peakingColor
            focusPeakingFilter.inputImage = image
            if let output = focusPeakingFilter.outputImage {
                image = output
            }
        }

        // Zebra stripes (skipped when false color is on — redundant)
        if isZebraEnabled && !isFalseColorEnabled {
            let thresholds = zebraThresholdLock.withLock { $0 }
            zebraFilter.inputImage = image
            zebraFilter.inputTime = getZebraTime()
            zebraFilter.inputOverThreshold = thresholds.high
            zebraFilter.inputUnderThreshold = thresholds.low
            if let output = zebraFilter.outputImage {
                image = output
            }
        }

        onProcessedFrame?(image, presentationTime)
        setLatestImage(image)

        // Histogram + waveform + vectorscope every 2nd frame (~30 fps) — off sessionQueue
        if frameCount % 2 == 0 {
            let capturedImage = rawImage
            let context = ciContext
            let needsWaveform = isWaveformEnabled
            let needsVectorscope = isVectorscopeEnabled
            histogramQueue.async { [self] in
                computeHistogram(from: capturedImage, context: context)
                if needsWaveform {
                    let data = HistogramCalculator.computeWaveform(from: capturedImage, context: context)
                    Task { @MainActor in onWaveformUpdate?(data) }
                }
                if needsVectorscope {
                    let data = HistogramCalculator.computeVectorscope(from: capturedImage, context: context)
                    Task { @MainActor in onVectorscopeUpdate?(data) }
                }
            }
        }
    }

    /// Maximum-composites N frames: each pixel keeps the brightest value seen across all frames.
    /// Produces light trails and star trails; correct for long-exposure light accumulation.
    /// (Add÷N averaging was previously used but produced ghosting without trails.)
    private static func blendFrames(_ frames: [CIImage]) -> CIImage? {
        guard !frames.isEmpty else { return nil }
        guard frames.count > 1 else { return frames[0] }
        // Create once per blend pass — not per iteration — to avoid repeated filter allocation.
        guard let maxFilter = CIFilter(name: "CIMaximumCompositing") else { return frames[0] }

        var result = frames[0]
        for frame in frames.dropFirst() {
            maxFilter.setValue(result, forKey: kCIInputBackgroundImageKey)
            maxFilter.setValue(frame,  forKey: kCIInputImageKey)
            if let out = maxFilter.outputImage { result = out }
        }
        return result
    }

    private func computeHistogram(from image: CIImage, context: CIContext) {
        let data = HistogramCalculator.compute(from: image, context: context)
        Task { @MainActor in
            onHistogramUpdate?(data.red, data.green, data.blue, data.luma)
        }
    }
}
