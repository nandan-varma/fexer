import AVFoundation
import CoreImage
import Metal
import MetalKit

/// Processes every video frame from AVCaptureVideoDataOutput.
/// Runs entirely on sessionQueue (background). Never touches MainActor.
final class CaptureProcessor: NSObject {
    // Latest rendered CIImage for MTKView (swapped atomically)
    private(set) var latestImage: CIImage?
    private let imageLock = NSLock()

    // Histogram data published to UI (swapped atomically)
    var onHistogramUpdate: (([Float], [Float], [Float], [Float]) -> Void)?
    var onFrameAvailable: (() -> Void)?

    // Filter pipeline state (set from CameraViewModel on main thread, read here)
    var lutFilter: LUTFilter? {
        get { _lutFilter }
        set { lutFilterLock.lock(); _lutFilter = newValue; lutFilterLock.unlock() }
    }
    private var _lutFilter: LUTFilter?
    private let lutFilterLock = NSLock()

    private let flagsLock = NSLock()
    private var _isFocusPeakingEnabled = false
    private var _isZebraEnabled = false
    private var _isFalseColorEnabled = false
    var isFocusPeakingEnabled: Bool {
        get { flagsLock.withLock { _isFocusPeakingEnabled } }
        set { flagsLock.withLock { _isFocusPeakingEnabled = newValue } }
    }
    var isZebraEnabled: Bool {
        get { flagsLock.withLock { _isZebraEnabled } }
        set { flagsLock.withLock { _isZebraEnabled = newValue } }
    }
    var isFalseColorEnabled: Bool {
        get { flagsLock.withLock { _isFalseColorEnabled } }
        set { flagsLock.withLock { _isFalseColorEnabled = newValue } }
    }
    // zebraTime is only ever read and written on sessionQueue — no lock needed
    var zebraTime: Float = 0

    private let focusPeakingFilter = FocusPeakingFilter()
    private let zebraFilter = ZebraFilter()
    private let falseColorFilter = FalseColorFilter()
    private lazy var histogramFilter: CIFilter = CIFilter(name: "CIAreaHistogram")!

    private var frameCount = 0
    private lazy var ciContext: CIContext = {
        let device = MTLCreateSystemDefaultDevice()!
        return CIContext(mtlDevice: device, options: [
            .useSoftwareRenderer: false,
            .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
        ])
    }()

    func setLatestImage(_ image: CIImage) {
        imageLock.lock()
        latestImage = image
        imageLock.unlock()
        onFrameAvailable?()
    }

    func getLatestImage() -> CIImage? {
        imageLock.lock()
        defer { imageLock.unlock() }
        return latestImage
    }
}

extension CaptureProcessor: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        frameCount += 1
        zebraTime = (zebraTime + 1.0 / 60.0).truncatingRemainder(dividingBy: 100.0)

        var image = CIImage(cvPixelBuffer: pixelBuffer)
        let rawImage = image  // snapshot before filter chain for histogram

        // LUT
        lutFilterLock.lock()
        if let lut = _lutFilter {
            lut.inputImage = image
            if let output = lut.outputImage {
                image = output
            }
        }
        lutFilterLock.unlock()

        // False color (replaces zebra when active)
        if isFalseColorEnabled {
            falseColorFilter.inputImage = image
            if let output = falseColorFilter.outputImage {
                image = output
            }
        }

        // Focus peaking (composited on top of false color if both active)
        if isFocusPeakingEnabled {
            focusPeakingFilter.inputImage = image
            if let output = focusPeakingFilter.outputImage {
                image = output
            }
        }

        // Zebra stripes (skipped when false color is on — redundant)
        if isZebraEnabled && !isFalseColorEnabled {
            zebraFilter.inputImage = image
            zebraFilter.inputTime = zebraTime
            if let output = zebraFilter.outputImage {
                image = output
            }
        }

        setLatestImage(image)

        // Histogram every 3rd frame (~20fps at 60fps session)
        if frameCount % 3 == 0 {
            computeHistogram(from: rawImage)
        }
    }

    private func computeHistogram(from image: CIImage) {
        let extent = image.extent
        let count = 256

        histogramFilter.setValue(image, forKey: "inputImage")
        histogramFilter.setValue(CIVector(cgRect: extent), forKey: "inputExtent")
        histogramFilter.setValue(count, forKey: "inputCount")
        histogramFilter.setValue(1.0, forKey: "inputScale")

        guard let histogramImage = histogramFilter.outputImage else { return }

        let bitmapSize = count * 4 * MemoryLayout<Float>.size
        var bitmap = [Float](repeating: 0, count: count * 4)
        ciContext.render(histogramImage,
                         toBitmap: &bitmap,
                         rowBytes: bitmapSize,
                         bounds: CGRect(x: 0, y: 0, width: count, height: 1),
                         format: .RGBAf,
                         colorSpace: nil)

        var red   = [Float](repeating: 0, count: count)
        var green = [Float](repeating: 0, count: count)
        var blue  = [Float](repeating: 0, count: count)
        var luma  = [Float](repeating: 0, count: count)

        for i in 0..<count {
            let r = bitmap[i * 4 + 0]
            let g = bitmap[i * 4 + 1]
            let b = bitmap[i * 4 + 2]
            red[i]   = r
            green[i] = g
            blue[i]  = b
            luma[i]  = 0.299 * r + 0.587 * g + 0.114 * b
        }

        // Normalize to 0–1 without allocating a concatenated array
        var maxVal: Float = 0.001
        for arr in [red, green, blue, luma] {
            if let m = arr.max(), m > maxVal { maxVal = m }
        }
        red   = red.map   { $0 / maxVal }
        green = green.map { $0 / maxVal }
        blue  = blue.map  { $0 / maxVal }
        luma  = luma.map  { $0 / maxVal }

        onHistogramUpdate?(red, green, blue, luma)
    }
}
