import SwiftUI
import Photos

struct ReviewView: View {
    let photo: CapturedPhoto
    var onDismiss: (() -> Void)?
    var onDelete: (() -> Void)?

    @State private var magnification: CGFloat = 1.0
    @State private var lastMagnification: CGFloat = 1.0
    @State private var showExif = false
    @State private var showShareSheet = false
    @State private var reviewHistogram: HistogramData?
    @State private var cachedExif: [ExifField: String] = [:]
    @State private var showEdit = false
    @State private var editedPhoto: CapturedPhoto?
    @State private var showDeleteConfirmation = false

    var body: some View {
        ZStack {
            if showEdit {
                EditView(
                    photo: editedPhoto ?? photo,
                    onCancel: {
                        withAnimation(.easeInOut(duration: 0.22)) { showEdit = false }
                    },
                    onSave: { updatedPhoto in
                        editedPhoto = updatedPhoto
                        withAnimation(.easeInOut(duration: 0.22)) { showEdit = false }
                    }
                )
                .transition(.opacity)
                .zIndex(1)
            } else {
                reviewContent
                    .transition(.opacity)
            }
        }
        .onAppear {
            computeReviewHistogram()
            Task.detached(priority: .utility) { [jpegData = photo.jpegData] in
                let exif = ExifReader.read(from: jpegData ?? Data())
                await MainActor.run { self.cachedExif = exif }
            }
        }
    }

    private var reviewContent: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Photo display
            Group {
                if let data = (editedPhoto ?? photo).jpegData, let uiImage = UIImage(data: data) {
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
                        withAnimation(.easeInOut(duration: 0.22)) { showEdit = true }
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 20))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(.black.opacity(0.5), in: Circle())
                    }

                    if photo.assetLocalIdentifier != nil {
                        Button {
                            showDeleteConfirmation = true
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 18))
                                .foregroundStyle(.white)
                                .frame(width: 36, height: 36)
                                .background(.black.opacity(0.5), in: Circle())
                        }
                        .confirmationDialog("Delete this photo?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
                            Button("Delete Photo", role: .destructive) { deletePhoto() }
                        }
                    }

                    Button {
                        withAnimation { showExif.toggle() }
                    } label: {
                        Image(systemName: showExif ? "info.circle.fill" : "info.circle")
                            .font(.system(size: 20))
                            .foregroundStyle(.white)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)

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
                    if let data = editedPhoto?.jpegData ?? photo.jpegData {
                        ShareLink(item: data, preview: SharePreview("Photo")) {
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
            DragGesture(minimumDistance: 20)
                .onEnded { g in
                    let isVertical = abs(g.translation.height) > abs(g.translation.width)
                    if isVertical && g.translation.height > 80 { onDismiss?() }
                }
        )
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
        let exif = cachedExif
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

    private func deletePhoto() {
        guard let id = photo.assetLocalIdentifier else { return }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
        guard assets.count > 0 else { return }
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.deleteAssets(assets)
        }) { success, _ in
            if success {
                Task { @MainActor in
                    onDelete?()
                    onDismiss?()
                }
            }
        }
    }

    private func computeReviewHistogram() {
        guard let data = photo.jpegData, let uiImage = UIImage(data: data),
              let cgImage = uiImage.cgImage else { return }

        Task.detached(priority: .utility) {
            let ciImage = CIImage(cgImage: cgImage)
            let hist = HistogramCalculator.compute(from: ciImage, context: CIContext.shared)
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
