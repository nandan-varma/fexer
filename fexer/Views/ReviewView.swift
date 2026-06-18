import SwiftUI

struct ReviewView: View {
    let photo: CapturedPhoto
    var onDismiss: (() -> Void)?

    @State private var magnification: CGFloat = 1.0
    @State private var lastMagnification: CGFloat = 1.0
    @State private var showExif = false
    @State private var showShareSheet = false
    @State private var reviewHistogram: HistogramData?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Photo display
            Group {
                if let data = photo.jpegData, let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .scaleEffect(magnification)
                        .gesture(magnificationGesture)
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 60))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }

            // EXIF overlay
            if showExif {
                exifOverlay
                    .transition(.opacity)
            }

            // Controls
            VStack {
                HStack {
                    Button(action: { onDismiss?() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(.black.opacity(0.5), in: Circle())
                    }

                    Spacer()

                    Button {
                        withAnimation { showExif.toggle() }
                    } label: {
                        Image(systemName: showExif ? "info.circle.fill" : "info.circle")
                            .font(.system(size: 20))
                            .foregroundStyle(.white)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 50)

                Spacer()

                HStack(spacing: 24) {
                    // Style tag
                    if let style = photo.appliedStyle {
                        Label(style.name, systemImage: "camera.filters")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.8))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.white.opacity(0.15), in: Capsule())
                    }

                    Spacer()

                    // Share
                    if let data = photo.jpegData {
                        ShareLink(item: Image(uiImage: UIImage(data: data) ?? UIImage()),
                                  preview: SharePreview("Photo", image: Image(uiImage: UIImage(data: data) ?? UIImage()))) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 20))
                                .foregroundStyle(.white)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
        }
        .gesture(
            DragGesture()
                .onEnded { g in
                    if g.translation.height > 80 { onDismiss?() }
                }
        )
        .onAppear { computeReviewHistogram() }
        .onTapGesture(count: 2) {
            let target: CGFloat = magnification > 1.5 ? 1.0 : 2.0
            withAnimation(.spring()) { magnification = target }
            lastMagnification = target
        }
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                magnification = (lastMagnification * value).fxClamped(to: 1.0...10.0)
            }
            .onEnded { _ in
                lastMagnification = magnification
            }
    }

    private var exifOverlay: some View {
        let exif = ExifReader.read(from: photo.jpegData ?? Data())
        let settings = photo.captureSettings

        return VStack(alignment: .leading, spacing: 6) {
            Text("CAPTURE INFO")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.yellow)
                .tracking(2)

            if let hist = reviewHistogram {
                HistogramView(data: hist)
                    .padding(.bottom, 4)
            }

            Group {
                exifRow("ISO", value: "ISO \(Int(settings.isoValue))")
                exifRow("Shutter", value: settings.shutterSpeedDisplayString)
                exifRow("WB", value: "\(Int(settings.whiteBalance))K \(settings.whiteBalanceTint >= 0 ? "+\(Int(settings.whiteBalanceTint))" : "\(Int(settings.whiteBalanceTint))")")
                exifRow("Metering", value: settings.meteringMode.rawValue)
                if let make = exif[.make] { exifRow("Camera", value: make) }
                if let fl = exif[.focalLength] { exifRow("Focal Length", value: fl) }
                if let lat = exif[.gpsLatitude] { exifRow("GPS", value: lat) }
            }

            if let style = photo.appliedStyle {
                exifRow("Style", value: style.name)
            }
        }
        .padding(16)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }

    private func computeReviewHistogram() {
        guard let data = photo.jpegData, let uiImage = UIImage(data: data),
              let cgImage = uiImage.cgImage else { return }

        Task.detached(priority: .utility) {
            let ciImage = CIImage(cgImage: cgImage)
            let context = CIContext()
            let count = 256

            guard let filter = CIFilter(name: "CIAreaHistogram") else { return }
            filter.setValue(ciImage, forKey: "inputImage")
            filter.setValue(CIVector(cgRect: ciImage.extent), forKey: "inputExtent")
            filter.setValue(count, forKey: "inputCount")
            filter.setValue(1.0, forKey: "inputScale")
            guard let output = filter.outputImage else { return }

            let bitmapSize = count * 4 * MemoryLayout<Float>.size
            var bitmap = [Float](repeating: 0, count: count * 4)
            context.render(output, toBitmap: &bitmap, rowBytes: bitmapSize,
                           bounds: CGRect(x: 0, y: 0, width: count, height: 1),
                           format: .RGBAf, colorSpace: nil)

            var r = [Float](repeating: 0, count: count)
            var g = [Float](repeating: 0, count: count)
            var b = [Float](repeating: 0, count: count)
            var l = [Float](repeating: 0, count: count)
            for i in 0..<count {
                r[i] = bitmap[i*4]; g[i] = bitmap[i*4+1]; b[i] = bitmap[i*4+2]
                l[i] = 0.299*r[i] + 0.587*g[i] + 0.114*b[i]
            }
            var maxV: Float = 0.001
            for arr in [r, g, b, l] { if let m = arr.max(), m > maxV { maxV = m } }
            let hist = HistogramData(
                red: r.map { $0/maxV }, green: g.map { $0/maxV },
                blue: b.map { $0/maxV }, luma: l.map { $0/maxV }
            )
            await MainActor.run { self.reviewHistogram = hist }
        }
    }

    private func exifRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
        }
    }
}
