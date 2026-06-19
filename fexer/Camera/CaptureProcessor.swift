import AVFoundation
import CoreImage
import Metal
import MetalKit
import os
import QuartzCore

/// Processes every video frame from AVCaptureVideoDataOutput.
/// Runs entirely on sessionQueue (background). Never touches MainActor.
///
/// The frame pipeline is: false color → LUT → focus peaking → zebra.
/// Histogram is computed from the pre-filter image every 3rd frame.
final class CaptureProcessor: NSObject {
    /// Latest rendered CIImage for MTKView (thread-safe via OSAllocatedUnfairLock)
    private let imageLock = OSAllocatedUnfairLock(initialState: Optional<CIImage>.none)

    // Histogram data published to UI (swapped atomically)
    var onHistogramUpdate: (([Float], [Float], [Float], [Float]) -> Void)?
    var onFrameAvailable: (() -> Void)?
    var onPreviewSizeKnown: ((CGSize) -> Void)?
    /// Called with the raw pixel buffer ~once per second (for thumbnail generation).
    var onPixelBuffer: ((CVPixelBuffer) -> Void)?

    // Filter pipeline state (set from CameraViewModel on main thread, read here)
    private let lutFilterLock = OSAllocatedUnfairLock(initialState: nil as LUTFilter?)

    var lutFilter: LUTFilter? {
        get { lutFilterLock.withLock { $0 } }
        set { lutFilterLock.withLock { $0 = newValue } }
    }

    // Thread-safe method to get current LUT filter with validation
    func getCurrentLUTFilter() -> LUTFilter? {
        lutFilterLock.withLock { $0 }
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

    private let flagsLock = OSAllocatedUnfairLock(initialState: (false, false, false))

    var isFocusPeakingEnabled: Bool {
        get { flagsLock.withLock { $0.0 } }
        set { flagsLock.withLock { $0.0 = newValue } }
    }
    var isZebraEnabled: Bool {
        get { flagsLock.withLock { $0.1 } }
        set { flagsLock.withLock { $0.1 = newValue } }
    }
    var isFalseColorEnabled: Bool {
        get { flagsLock.withLock { $0.2 } }
        set { flagsLock.withLock { $0.2 = newValue } }
    }

    // zebraTime is only ever read and written on sessionQueue — no lock needed
    var zebraTime: Float = 0

    // Anamorphic 2× desqueeze (thread-safe: set from MainActor, read from sessionQueue)
    private let anamorphicLock = OSAllocatedUnfairLock(initialState: false)
    var isAnamorphicDesqueezeEnabled: Bool {
        get { anamorphicLock.withLock { $0 } }
        set { anamorphicLock.withLock { $0 = newValue } }
    }

    // Long exposure frame accumulation — all mutable state below is sessionQueue-only
    // except longExpActiveLock (read/written from caller + sessionQueue)
    private let longExpActiveLock = OSAllocatedUnfairLock(initialState: false)
    private var longExpFrames: [CIImage] = []
    private var longExpStart: CFTimeInterval = 0
    var longExpDuration: Double = 4.0
    var onLongExposureComplete: ((CIImage) -> Void)?

    var isLongExposureCapturing: Bool { longExpActiveLock.withLock { $0 } }

    func beginLongExposureCapture(duration: Double = 4.0, completion: @escaping (CIImage) -> Void) {
        onLongExposureComplete = completion
        longExpDuration = duration
        longExpActiveLock.withLock { $0 = true }
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
        onFrameAvailable?()
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

        frameCount += 1
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

        // Long exposure: accumulate frames for frame-averaged blend
        if longExpActiveLock.withLock({ $0 }) {
            if longExpFrames.isEmpty { longExpStart = CACurrentMediaTime() }
            longExpFrames.append(rawImage)
            if CACurrentMediaTime() - longExpStart >= longExpDuration {
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
            zebraFilter.inputImage = image
            zebraFilter.inputTime = getZebraTime()
            if let output = zebraFilter.outputImage {
                image = output
            }
        }

        setLatestImage(image)

        // Histogram every 3rd frame (~20fps at 60fps session) — computed off sessionQueue
        if frameCount % 3 == 0 {
            let image = rawImage
            let context = ciContext
            histogramQueue.async { [self] in
                computeHistogram(from: image, context: context)
            }
        }
    }

    /// Maximum-composites N frames: each pixel keeps the brightest value seen across all frames.
    /// Produces light trails and star trails; correct for long-exposure light accumulation.
    /// (Add÷N averaging was previously used but produced ghosting without trails.)
    private static func blendFrames(_ frames: [CIImage]) -> CIImage? {
        guard !frames.isEmpty else { return nil }
        guard frames.count > 1 else { return frames[0] }

        var result = frames[0]
        for frame in frames.dropFirst() {
            guard let maxFilter = CIFilter(name: "CIMaximumCompositing") else { continue }
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
