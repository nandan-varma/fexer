import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import Photos

struct EditView: View {
    let photo: CapturedPhoto
    var onSave: ((CapturedPhoto) -> Void)?

    @State private var state = EditState()
    @State private var previewImage: UIImage?
    @State private var isSaving = false

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Preview
                    Group {
                        if let img = previewImage {
                            Image(uiImage: img)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .cornerRadius(8)
                        } else {
                            Color.black
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 260)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                    // Adjustment sliders
                    ScrollView {
                        VStack(spacing: 0) {
                            adjustmentRow("Exposure",   value: $state.exposure,   range: -2...2,      format: "%.1f EV")
                            adjustmentRow("Contrast",   value: $state.contrast,   range: -0.5...0.5,  format: "%.2f")
                            adjustmentRow("Shadows",    value: $state.shadows,    range: -1...1,       format: "%.2f")
                            adjustmentRow("Highlights", value: $state.highlights, range: -1...1,       format: "%.2f")
                            adjustmentRow("Saturation", value: $state.saturation, range: -1...1,       format: "%.2f")
                            adjustmentRow("Warmth",     value: $state.warmth,     range: -1...1,       format: "%.2f")

                            Divider().padding(.vertical, 8)

                            // Rotation
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("ROTATE")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.5))
                                        .tracking(1.2)
                                    Spacer()
                                    Text(String(format: "%.1f°", state.rotationDegrees))
                                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                                        .foregroundStyle(.white)
                                }
                                Slider(value: $state.rotationDegrees, in: -45...45)
                                    .tint(.yellow)
                                    .onChange(of: state.rotationDegrees) { _, _ in renderPreview() }
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                        }
                    }
                }
            }
            .navigationTitle("Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Reset") {
                        state = EditState()
                        renderPreview()
                    }
                    .foregroundStyle(state.isModified ? .yellow : .white.opacity(0.4))
                    .disabled(!state.isModified)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isSaving {
                        ProgressView()
                            .tint(.yellow)
                    } else {
                        Button("Save") { saveEdits() }
                            .foregroundStyle(.yellow)
                            .fontWeight(.semibold)
                    }
                }
            }
        }
        .presentationDetents([.large])
        .onAppear { renderPreview() }
    }

    private func adjustmentRow(_ label: String, value: Binding<Float>,
                                range: ClosedRange<Float>, format: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .tracking(1.2)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(value.wrappedValue == 0 ? .white.opacity(0.4) : .white)
                    .animation(.none, value: value.wrappedValue)
            }
            Slider(value: value, in: range)
                .tint(.yellow)
                .onChange(of: value.wrappedValue) { _, _ in renderPreview() }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private func renderPreview() {
        guard let data = photo.jpegData,
              let ciImage = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return }
        let capturedState = state
        Task.detached(priority: .userInitiated) {
            let result = Self.applyEdits(to: ciImage, state: capturedState, at: 0.3)
            let ui = result.flatMap { UIImage(ciImage: $0) }
            await MainActor.run { previewImage = ui }
        }
    }

    /// Apply EditState filters to a CIImage. scale < 1.0 for preview (faster), 1.0 for final save.
    private nonisolated static func applyEdits(to input: CIImage, state: EditState, at scale: CGFloat = 1.0) -> CIImage? {
        var img = scale < 1.0
            ? input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : input

        // Exposure
        if state.exposure != 0 {
            let f = CIFilter.exposureAdjust()
            f.inputImage = img
            f.ev = state.exposure
            img = f.outputImage ?? img
        }

        // Shadows / highlights
        if state.shadows != 0 || state.highlights != 0 {
            let f = CIFilter.highlightShadowAdjust()
            f.inputImage = img
            f.shadowAmount = 1.0 + state.shadows
            f.highlightAmount = 1.0 - state.highlights * 0.5
            img = f.outputImage ?? img
        }

        // Contrast + saturation
        if state.contrast != 0 || state.saturation != 0 {
            let f = CIFilter.colorControls()
            f.inputImage = img
            f.contrast = 1.0 + state.contrast
            f.saturation = 1.0 + state.saturation
            f.brightness = 0
            img = f.outputImage ?? img
        }

        // Warmth (temperature shift)
        if state.warmth != 0 {
            let f = CIFilter.temperatureAndTint()
            f.inputImage = img
            let shift = Float(state.warmth * 2000)
            f.neutral = CIVector(x: CGFloat(6500 + shift), y: 0)
            f.targetNeutral = CIVector(x: 6500, y: 0)
            img = f.outputImage ?? img
        }

        // Rotation
        if state.rotationDegrees != 0 {
            let rad = CGFloat(state.rotationDegrees * .pi / 180)
            let t = CGAffineTransform(rotationAngle: rad)
            img = img.transformed(by: t)
        }

        return img
    }

    private func saveEdits() {
        guard let data = photo.jpegData,
              let ciImage = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return }
        isSaving = true
        let capturedState = state
        let capturedPhoto = photo
        let ctx = ciContext
        Task.detached(priority: .userInitiated) {
            guard let edited = Self.applyEdits(to: ciImage, state: capturedState, at: 1.0),
                  let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
                  let cgImage = ctx.createCGImage(edited, from: edited.extent,
                                                  format: .RGBA8, colorSpace: sRGB),
                  let jpegData = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.95)
            else {
                await MainActor.run { isSaving = false }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: jpegData, options: nil)
            }, completionHandler: nil)
            await MainActor.run {
                let savedPhoto = CapturedPhoto(
                    jpegData: jpegData,
                    rawFileURL: capturedPhoto.rawFileURL,
                    captureSettings: capturedPhoto.captureSettings,
                    appliedStyle: capturedPhoto.appliedStyle,
                    styleIntensity: capturedPhoto.styleIntensity,
                    captureDate: capturedPhoto.captureDate,
                    location: capturedPhoto.location,
                    exifMetadata: capturedPhoto.exifMetadata,
                    editState: capturedState
                )
                isSaving = false
                onSave?(savedPhoto)
            }
        }
    }
}
