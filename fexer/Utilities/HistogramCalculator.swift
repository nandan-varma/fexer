import CoreImage

struct HistogramCalculator {
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
            luma[i]  = 0.299 * r + 0.587 * g + 0.114 * b
        }

        var maxVal: Float = 0.001
        for arr in [red, green, blue, luma] {
            if let m = arr.max(), m > maxVal { maxVal = m }
        }

        return HistogramData(
            red:   red.map   { $0 / maxVal },
            green: green.map { $0 / maxVal },
            blue:  blue.map  { $0 / maxVal },
            luma:  luma.map  { $0 / maxVal }
        )
    }
}
