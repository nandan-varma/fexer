import CoreImage

// Waveform: 64 display columns × 128 luma bins
// density[col * rows + bin] — bin 0 = 0% IRE (bottom of display), rows-1 = 100% IRE (top)
nonisolated struct WaveformData {
    static let cols = 64
    static let rows = 128
    var density: [Float]

    init() { density = [Float](repeating: 0, count: WaveformData.cols * WaveformData.rows) }
    init(density: [Float]) { self.density = density }

    var isEmpty: Bool { density.isEmpty }

    subscript(col: Int, bin: Int) -> Float { density[col * WaveformData.rows + bin] }
}

// Vectorscope: 64×64 Cb-Cr density map (log-normalized).
// Cb (B-Y) = horizontal axis — col 0 = left (Cb = -0.5), col gridSize-1 = right (Cb = +0.5)
// Cr (R-Y) = vertical axis  — row 0 = top  (Cr = +0.5), row gridSize-1 = bottom (Cr = -0.5)
// density[row * size + col]
nonisolated struct VectorscopeData {
    static let size = 64
    var density: [Float]

    init() { density = [Float](repeating: 0, count: VectorscopeData.size * VectorscopeData.size) }
    init(density: [Float]) { self.density = density }

    var isEmpty: Bool { density.isEmpty }

    subscript(row: Int, col: Int) -> Float { density[row * VectorscopeData.size + col] }
}

enum HistogramCalculator {
    nonisolated static func compute(from image: CIImage, context: CIContext) -> HistogramData {
        let count = 256
        guard let filter = CIFilter(name: "CIAreaHistogram") else {
            return HistogramData()
        }

        filter.setValue(image, forKey: "inputImage")
        filter.setValue(CIVector(cgRect: image.extent), forKey: "inputExtent")
        filter.setValue(count, forKey: "inputCount")
        filter.setValue(1.0, forKey: "inputScale")

        guard let histogramImage = filter.outputImage else { return HistogramData() }

        let bitmapSize = count * 4 * MemoryLayout<Float>.size
        var bitmap = [Float](repeating: 0, count: count * 4)
        context.render(histogramImage,
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
            luma[i]  = 0.2126 * r + 0.7152 * g + 0.0722 * b
        }

        var maxVal: Float = 0.001
        for arr in [red, green, blue, luma] {
            if let m = arr.max(), m > maxVal { maxVal = m }
        }

        return HistogramData(
            red: red.map { $0 / maxVal },
            green: green.map { $0 / maxVal },
            blue: blue.map { $0 / maxVal },
            luma: luma.map { $0 / maxVal }
        )
    }

    // Renders the image to a 64×128 sample, then builds a per-column luma density map.
    // Each column of the display corresponds to the same horizontal slice of the camera frame.
    nonisolated static func computeWaveform(from image: CIImage, context: CIContext) -> WaveformData {
        let cols = WaveformData.cols
        let rows = WaveformData.rows

        let scale = CGAffineTransform(
            scaleX: CGFloat(cols) / image.extent.width,
            y: CGFloat(rows) / image.extent.height
        )
        let scaled = image.transformed(by: scale)

        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
              let cgImage = context.createCGImage(scaled, from: scaled.extent,
                                                  format: .RGBA8, colorSpace: sRGB),
              let cfData = cgImage.dataProvider?.data
        else { return WaveformData() }

        let bytes = CFDataGetBytePtr(cfData)!
        let bytesPerRow = cgImage.bytesPerRow

        var density = [Float](repeating: 0, count: cols * rows)

        for y in 0..<rows {
            for x in 0..<cols {
                let off = y * bytesPerRow + x * 4
                let r = Float(bytes[off    ]) / 255.0
                let g = Float(bytes[off + 1]) / 255.0
                let b = Float(bytes[off + 2]) / 255.0
                // Rec. 709 luma
                let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                // bin 0 = 0% IRE (bottom), rows-1 = 100% IRE (top)
                let bin = max(0, min(rows - 1, Int(luma * Float(rows - 1))))
                density[x * rows + bin] += 1
            }
        }

        // Normalize each column independently so thin bright lines read as full intensity
        for x in 0..<cols {
            let base = x * rows
            var maxVal: Float = 0
            for r in 0..<rows where density[base + r] > maxVal { maxVal = density[base + r] }
            if maxVal > 0 {
                for r in 0..<rows { density[base + r] /= maxVal }
            }
        }

        return WaveformData(density: density)
    }

    // Renders the image to a 64×64 sample, computes Rec.709 Cb/Cr per pixel,
    // and accumulates a 2D density map. Log-normalized to reveal faint chroma detail.
    nonisolated static func computeVectorscope(from image: CIImage, context: CIContext) -> VectorscopeData {
        let gridSize = VectorscopeData.size

        let scale = CGAffineTransform(
            scaleX: CGFloat(gridSize) / image.extent.width,
            y: CGFloat(gridSize) / image.extent.height
        )
        let scaled = image.transformed(by: scale)

        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
              let cgImage = context.createCGImage(scaled, from: scaled.extent,
                                                  format: .RGBA8, colorSpace: sRGB),
              let cfData = cgImage.dataProvider?.data
        else { return VectorscopeData() }

        let bytes = CFDataGetBytePtr(cfData)!
        let bytesPerRow = cgImage.bytesPerRow

        var counts = [Float](repeating: 0, count: gridSize * gridSize)

        for y in 0..<gridSize {
            for x in 0..<gridSize {
                let off = y * bytesPerRow + x * 4
                let r = Float(bytes[off    ]) / 255.0
                let g = Float(bytes[off + 1]) / 255.0
                let b = Float(bytes[off + 2]) / 255.0

                // Rec. 709 Cb/Cr: range -0.5 … +0.5
                let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                let cb = (b - luma) / 1.8556
                let cr = (r - luma) / 1.5748

                // Map to grid: col 0 = Cb -0.5 (left), row 0 = Cr +0.5 (top)
                let col = max(0, min(gridSize - 1, Int((cb + 0.5) * Float(gridSize - 1))))
                let row = max(0, min(gridSize - 1, Int((0.5 - cr) * Float(gridSize - 1))))
                counts[row * gridSize + col] += 1
            }
        }

        // Log-normalize: boosts faint chroma without clipping bright neutrals
        var maxVal: Float = 0
        for v in counts where v > maxVal { maxVal = v }
        if maxVal > 0 {
            let logMax = log(1 + maxVal)
            for i in 0..<counts.count {
                counts[i] = log(1 + counts[i]) / logMax
            }
        }

        return VectorscopeData(density: counts)
    }
}
