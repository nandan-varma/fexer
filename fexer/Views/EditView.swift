import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import Photos

struct EditView: View {
    let photo: CapturedPhoto
    var onCancel: (() -> Void)?
    var onSave: ((CapturedPhoto) -> Void)?

    @State private var state = EditState()
    @State private var previewImage: UIImage?
    @State private var originalImage: UIImage?
    @State private var isSaving = false
    @State private var mode: EditorMode = .adjust
    @State private var adjustment: Adjustment = .exposure
    @State private var cropParameter: CropParameter = .straighten
    @State private var renderID = UUID()
    @State private var renderTask: Task<Void, Never>?
    @State private var didHapticAtCenter = false
    @GestureState private var isPressingOriginal = false
    @GestureState private var liveCropDrag: CGSize = .zero
    @GestureState private var liveCropScale: CGFloat = 1

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                canvas
                contextualControls
                bottomRail
            }

            if isSaving {
                Color.black.opacity(0.32).ignoresSafeArea()
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            originalImage = photo.jpegData.flatMap(UIImage.init(data:))
            renderPreview()
            HapticManager.warmUp()
        }
    }

    private var topBar: some View {
        HStack {
            Button("Cancel") { onCancel?() }
                .fontWeight(.medium)

            Spacer()

            Button {
                state = EditState()
                renderPreview()
                HapticManager.light()
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .frame(width: 40, height: 40)
            }
            .disabled(!state.isModified || isSaving)
            .opacity(state.isModified ? 1 : 0.35)
            .accessibilityLabel("Reset edits")

            Button("Done") { saveEdits() }
                .fontWeight(.semibold)
                .disabled(isSaving)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .frame(height: 52)
    }

    private var canvas: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black

                if mode == .crop, let image = previewImage {
                    cropCanvas(image: image, in: geometry.size)
                } else if let image = previewImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: geometry.size.width, maxHeight: geometry.size.height)
                        .opacity(isPressingOriginal ? 0 : 1)
                }

                if let image = originalImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: geometry.size.width, maxHeight: geometry.size.height)
                        .opacity(isPressingOriginal ? 1 : 0)
                        .allowsHitTesting(false)
                } else {
                    ProgressView().tint(.white)
                }

                VStack {
                    Spacer()
                    Text(isPressingOriginal ? "ORIGINAL" : mode == .crop ? "Pinch and drag to reframe" : "Hold for original")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1.2)
                        .foregroundStyle(.white.opacity(isPressingOriginal ? 1 : 0.6))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 12)
                }
            }
            .contentShape(Rectangle())
            .gesture(mode == .adjust ? originalPressGesture : nil)
            .onChange(of: isPressingOriginal) { oldValue, newValue in
                if newValue && !oldValue { HapticManager.light() }
            }
        }
        .frame(maxHeight: .infinity)
        .clipped()
    }

    private func cropCanvas(image: UIImage, in canvasSize: CGSize) -> some View {
        let layout = cropLayout(for: image.size, in: canvasSize, zoom: state.cropZoom)
        let liveZoom = (state.cropZoom * liveCropScale).fxClamped(to: 1...6)
        let liveLayout = cropLayout(for: image.size, in: canvasSize, zoom: liveZoom)
        let committedOffset = cropOffset(in: liveLayout)
        let maxOffsetX = max((liveLayout.imageSize.width - layout.viewport.width) / 2, 0)
        let maxOffsetY = max((liveLayout.imageSize.height - layout.viewport.height) / 2, 0)
        let offset = CGSize(
            width: (committedOffset.width + liveCropDrag.width).fxClamped(to: -maxOffsetX...maxOffsetX),
            height: (committedOffset.height + liveCropDrag.height).fxClamped(to: -maxOffsetY...maxOffsetY)
        )

        return ZStack {
            Color.black

            Image(uiImage: image)
                .resizable()
                .frame(width: liveLayout.imageSize.width, height: liveLayout.imageSize.height)
                .offset(offset)
                .frame(width: layout.viewport.width, height: layout.viewport.height)
                .clipped()
                .position(x: layout.viewport.midX, y: layout.viewport.midY)

            RuleOfThirdsGrid()
                .stroke(.white.opacity(0.58), lineWidth: 0.6)
                .frame(width: layout.viewport.width, height: layout.viewport.height)
                .position(x: layout.viewport.midX, y: layout.viewport.midY)
                .allowsHitTesting(false)

            CropFrameOverlay()
                .stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .square))
                .frame(width: layout.viewport.width, height: layout.viewport.height)
                .position(x: layout.viewport.midX, y: layout.viewport.midY)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .gesture(cropGesture(layout: layout))
    }

    private func cropLayout(
        for imageSize: CGSize,
        in canvasSize: CGSize,
        zoom: CGFloat
    ) -> CropLayout {
        let available = CGSize(
            width: max(canvasSize.width - 36, 1),
            height: max(canvasSize.height - 36, 1)
        )
        let imageRatio = max(imageSize.width / max(imageSize.height, 1), 0.01)
        let requested = state.cropAspectRatio.map {
            imageSize.height > imageSize.width ? 1 / $0 : $0
        } ?? imageRatio
        let viewportSize: CGSize
        if available.width / available.height > requested {
            viewportSize = CGSize(width: available.height * requested, height: available.height)
        } else {
            viewportSize = CGSize(width: available.width, height: available.width / requested)
        }
        let viewport = CGRect(
            x: (canvasSize.width - viewportSize.width) / 2,
            y: (canvasSize.height - viewportSize.height) / 2,
            width: viewportSize.width,
            height: viewportSize.height
        )
        let baseScale = max(viewport.width / max(imageSize.width, 1),
                            viewport.height / max(imageSize.height, 1))
        return CropLayout(
            viewport: viewport,
            imageSize: CGSize(
                width: imageSize.width * baseScale * zoom,
                height: imageSize.height * baseScale * zoom
            )
        )
    }

    private func cropOffset(in layout: CropLayout) -> CGSize {
        let overflowX = max(layout.imageSize.width - layout.viewport.width, 0)
        let overflowY = max(layout.imageSize.height - layout.viewport.height, 0)
        return CGSize(
            width: (0.5 - state.cropCenterX) * overflowX,
            height: (0.5 - state.cropCenterY) * overflowY
        )
    }

    @ViewBuilder
    private var contextualControls: some View {
        if mode == .adjust {
            VStack(spacing: 6) {
                HStack {
                    Text(adjustment.title)
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(adjustment.displayValue(from: state))
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(adjustment.value(from: state) == 0 ? Color.secondary : Color.yellow)
                }

                ZStack {
                    Rectangle()
                        .fill(.white.opacity(0.18))
                        .frame(height: 2)
                    Rectangle()
                        .fill(.white.opacity(0.5))
                        .frame(width: 1, height: 12)
                    Slider(value: adjustmentBinding, in: adjustment.range)
                        .tint(.yellow)
                }
                .frame(height: 30)
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
        } else {
            cropControls
                .padding(.top, 10)
        }
    }

    private var bottomRail: some View {
        VStack(spacing: 8) {
            if mode == .adjust {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Adjustment.allCases) { item in
                            adjustmentButton(item)
                        }
                    }
                    .padding(.horizontal, 18)
                }
            } else {
                aspectRatioRail
            }

            HStack(spacing: 56) {
                modeButton(.adjust)
                modeButton(.crop)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
        }
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private func adjustmentButton(_ item: Adjustment) -> some View {
        let selected = adjustment == item
        let changed = item.value(from: state) != 0
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) { adjustment = item }
            HapticManager.selectionChanged()
        } label: {
            VStack(spacing: 5) {
                Image(systemName: item.symbol)
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 40, height: 34)
                    .background(selected ? Color.yellow : Color.white.opacity(changed ? 0.16 : 0.07), in: Capsule())
                    .foregroundStyle(selected ? .black : changed ? .yellow : .white)
                Text(item.shortTitle)
                    .font(.system(size: 10, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .white : .secondary)
            }
            .frame(width: 58)
        }
        .buttonStyle(.plain)
    }

    private var cropControls: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 32) {
                    cropAction("Rotate", symbol: "rotate.right") {
                        state.quarterTurns = (state.quarterTurns + 1) % 4
                    }
                    cropAction("Flip", symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right") {
                        state.isFlippedHorizontally.toggle()
                    }
                    ForEach(CropParameter.allCases) { item in
                        Button {
                            cropParameter = item
                            HapticManager.selectionChanged()
                        } label: {
                            VStack(spacing: 5) {
                                Image(systemName: item.symbol).font(.system(size: 18))
                                Text(item.shortTitle).font(.system(size: 10))
                            }
                            .foregroundStyle(cropParameter == item ? .yellow : .white)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 24)
            }

            HStack {
                Text(cropParameter.title)
                    .font(.system(size: 12, weight: .medium))
                Slider(value: cropParameterBinding, in: cropParameter.range)
                    .tint(.yellow)
                Text(cropParameter.displayValue(from: state))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .frame(width: 52, alignment: .trailing)
            }
            .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
    }

    private func cropAction(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            renderPreview()
            HapticManager.light()
        } label: {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 19))
                Text(title).font(.system(size: 10))
            }
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    private var aspectRatioRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                aspectButton("Original", ratio: nil)
                aspectButton("Square", ratio: 1)
                aspectButton("3:2", ratio: 3 / 2)
                aspectButton("4:3", ratio: 4 / 3)
                aspectButton("5:4", ratio: 5 / 4)
                aspectButton("16:9", ratio: 16 / 9)
            }
            .padding(.horizontal, 18)
        }
    }

    private func aspectButton(_ title: String, ratio: CGFloat?) -> some View {
        let selected = state.cropAspectRatio == ratio
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                state.cropAspectRatio = ratio
                state.cropRect = nil
                if ratio == nil {
                    state.cropZoom = 1
                    state.cropCenterX = 0.5
                    state.cropCenterY = 0.5
                }
            }
            HapticManager.selectionChanged()
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? .black : .white)
                .padding(.horizontal, 16)
                .frame(height: 34)
                .background(selected ? Color.yellow : Color.white.opacity(0.08), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func modeButton(_ item: EditorMode) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.22)) { mode = item }
            renderPreview(debounced: false)
            HapticManager.selectionChanged()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: item.symbol).font(.system(size: 19, weight: .medium))
                Text(item.title).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(mode == item ? .yellow : .white.opacity(0.65))
        }
        .buttonStyle(.plain)
    }

    private var adjustmentBinding: Binding<Float> {
        Binding(
            get: { adjustment.value(from: state) },
            set: { newValue in
                adjustment.set(newValue, on: &state)
                let nearCenter = abs(newValue) < adjustment.range.upperBound * 0.025
                if nearCenter && !didHapticAtCenter {
                    HapticManager.selectionChanged()
                    didHapticAtCenter = true
                } else if !nearCenter {
                    didHapticAtCenter = false
                }
                renderPreview()
            }
        )
    }

    private var cropParameterBinding: Binding<Double> {
        Binding(
            get: { cropParameter.value(from: state) },
            set: { value in
                cropParameter.set(value, on: &state)
                if cropParameter == .straighten {
                    renderPreview(debounced: true)
                }
            }
        )
    }

    private var originalPressGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .updating($isPressingOriginal) { _, pressing, _ in
                pressing = true
            }
    }

    private func cropGesture(layout: CropLayout) -> some Gesture {
        let drag = DragGesture(minimumDistance: 0)
            .updating($liveCropDrag) { value, offset, _ in
                offset = value.translation
            }
            .onEnded { value in
                let overflowX = layout.imageSize.width - layout.viewport.width
                let overflowY = layout.imageSize.height - layout.viewport.height
                if overflowX > 0 {
                    state.cropCenterX = (state.cropCenterX - value.translation.width / overflowX)
                        .fxClamped(to: 0...1)
                }
                if overflowY > 0 {
                    state.cropCenterY = (state.cropCenterY - value.translation.height / overflowY)
                        .fxClamped(to: 0...1)
                }
            }

        let pinch = MagnificationGesture()
            .updating($liveCropScale) { value, scale, _ in
                scale = value
            }
            .onEnded { value in
                state.cropZoom = (state.cropZoom * value).fxClamped(to: 1...6)
            }

        return drag.simultaneously(with: pinch)
    }

    private func renderPreview(debounced: Bool = false) {
        guard let data = photo.jpegData,
              let input = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return }
        let requestID = UUID()
        renderID = requestID
        var capturedState = state
        if mode == .crop {
            capturedState.cropRect = nil
            capturedState.cropAspectRatio = nil
            capturedState.cropZoom = 1
            capturedState.cropCenterX = 0.5
            capturedState.cropCenterY = 0.5
        }
        let context = ciContext
        renderTask?.cancel()
        renderTask = Task {
            if debounced {
                try? await Task.sleep(for: .milliseconds(90))
                guard !Task.isCancelled else { return }
            }
            let image = await Task.detached(priority: .userInitiated) {
                guard let result = Self.applyEdits(to: input, state: capturedState, maxDimension: 1200),
                      let cgImage = context.createCGImage(result, from: result.extent) else { return nil as UIImage? }
                return UIImage(cgImage: cgImage)
            }.value
            guard !Task.isCancelled, renderID == requestID else { return }
            if let image {
                previewImage = image
            }
        }
    }

    nonisolated static func applyEdits(
        to input: CIImage,
        state: EditState,
        maxDimension: CGFloat? = nil
    ) -> CIImage? {
        var image = input
        if let maxDimension {
            let scale = min(1, maxDimension / max(input.extent.width, input.extent.height))
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }

        if state.exposure != 0 {
            let filter = CIFilter.exposureAdjust()
            filter.inputImage = image
            filter.ev = state.exposure
            image = filter.outputImage ?? image
        }
        if state.shadows != 0 || state.highlights != 0 {
            let filter = CIFilter.highlightShadowAdjust()
            filter.inputImage = image
            filter.shadowAmount = 1 + state.shadows
            filter.highlightAmount = 1 - state.highlights * 0.5
            image = filter.outputImage ?? image
        }
        if state.contrast != 0 || state.saturation != 0 {
            let filter = CIFilter.colorControls()
            filter.inputImage = image
            filter.contrast = 1 + state.contrast
            filter.saturation = 1 + state.saturation
            image = filter.outputImage ?? image
        }
        if state.vibrance != 0 {
            let filter = CIFilter.vibrance()
            filter.inputImage = image
            filter.amount = state.vibrance
            image = filter.outputImage ?? image
        }
        if state.warmth != 0 {
            let filter = CIFilter.temperatureAndTint()
            filter.inputImage = image
            filter.neutral = CIVector(x: CGFloat(6500 + state.warmth * 2000), y: 0)
            filter.targetNeutral = CIVector(x: 6500, y: 0)
            image = filter.outputImage ?? image
        }
        if state.sharpness != 0 {
            let filter = CIFilter.sharpenLuminance()
            filter.inputImage = image
            filter.sharpness = state.sharpness
            image = filter.outputImage ?? image
        }
        if state.vignette != 0 {
            let filter = CIFilter.vignette()
            filter.inputImage = image
            filter.intensity = state.vignette
            filter.radius = 1.5
            image = filter.outputImage ?? image
        }

        let totalRotation = CGFloat(state.rotationDegrees * .pi / 180)
            + CGFloat(state.quarterTurns) * .pi / 2
        if totalRotation != 0 {
            image = image.transformed(by: CGAffineTransform(rotationAngle: totalRotation))
        }
        if state.isFlippedHorizontally {
            let extent = image.extent
            image = image.transformed(by: CGAffineTransform(translationX: extent.midX * 2, y: 0)
                .scaledBy(x: -1, y: 1))
        }
        if let crop = state.cropRect {
            let extent = image.extent
            let rect = CGRect(
                x: extent.minX + extent.width * crop.minX,
                y: extent.minY + extent.height * crop.minY,
                width: extent.width * crop.width,
                height: extent.height * crop.height
            )
            image = image.cropped(to: rect)
        } else if state.cropAspectRatio != nil || state.cropZoom != 1
                    || state.cropCenterX != 0.5 || state.cropCenterY != 0.5 {
            let extent = image.extent
            let requestedRatio = state.cropAspectRatio ?? (extent.width / extent.height)
            let ratio = extent.height > extent.width && state.cropAspectRatio != nil
                ? 1 / requestedRatio : requestedRatio
            let currentRatio = extent.width / extent.height
            let size: CGSize
            if currentRatio > ratio {
                size = CGSize(width: extent.height * ratio / state.cropZoom, height: extent.height / state.cropZoom)
            } else {
                size = CGSize(width: extent.width / state.cropZoom, height: extent.width / ratio / state.cropZoom)
            }
            let centerX = extent.minX + extent.width * state.cropCenterX
            // EditState stores crop position in screen coordinates (top to bottom),
            // while Core Image uses a bottom-left origin.
            let centerY = extent.maxY - extent.height * state.cropCenterY
            let originX = min(max(centerX - size.width / 2, extent.minX), extent.maxX - size.width)
            let originY = min(max(centerY - size.height / 2, extent.minY), extent.maxY - size.height)
            image = image.cropped(to: CGRect(
                x: originX,
                y: originY,
                width: size.width,
                height: size.height
            ))
        }

        return image.transformed(by: CGAffineTransform(
            translationX: -image.extent.minX,
            y: -image.extent.minY
        ))
    }

    private func saveEdits() {
        guard let data = photo.jpegData,
              let input = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return }
        isSaving = true
        let capturedState = state
        let capturedPhoto = photo
        let context = ciContext
        Task.detached(priority: .userInitiated) {
            guard let edited = Self.applyEdits(to: input, state: capturedState),
                  let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let cgImage = context.createCGImage(edited, from: edited.extent, format: .RGBA8, colorSpace: colorSpace),
                  let jpegData = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.95) else {
                await MainActor.run {
                    isSaving = false
                    HapticManager.error()
                }
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
                HapticManager.focusLocked()
                onSave?(savedPhoto)
            }
        }
    }
}

private enum EditorMode: String, CaseIterable {
    case adjust
    case crop

    var title: String { rawValue.capitalized }
    var symbol: String { self == .adjust ? "slider.horizontal.3" : "crop.rotate" }
}

private enum CropParameter: String, CaseIterable, Identifiable {
    case straighten, zoom, horizontal, vertical

    var id: Self { self }
    var title: String { rawValue.capitalized }
    var shortTitle: String {
        switch self {
        case .straighten: "Angle"
        case .horizontal: "Horizontal"
        case .vertical: "Vertical"
        case .zoom: "Zoom"
        }
    }
    var symbol: String {
        switch self {
        case .straighten: "dial.medium"
        case .zoom: "magnifyingglass"
        case .horizontal: "arrow.left.and.right"
        case .vertical: "arrow.up.and.down"
        }
    }
    var range: ClosedRange<Double> {
        switch self {
        case .straighten: -45...45
        case .zoom: 1...6
        case .horizontal, .vertical: 0...1
        }
    }
    func value(from state: EditState) -> Double {
        switch self {
        case .straighten: state.rotationDegrees
        case .zoom: Double(state.cropZoom)
        case .horizontal: Double(state.cropCenterX)
        case .vertical: Double(state.cropCenterY)
        }
    }
    func set(_ value: Double, on state: inout EditState) {
        switch self {
        case .straighten: state.rotationDegrees = value
        case .zoom: state.cropZoom = CGFloat(value)
        case .horizontal: state.cropCenterX = CGFloat(value)
        case .vertical: state.cropCenterY = CGFloat(value)
        }
    }
    func displayValue(from state: EditState) -> String {
        switch self {
        case .straighten: String(format: "%+.1f°", state.rotationDegrees)
        case .zoom: String(format: "%.2fx", state.cropZoom)
        case .horizontal: String(format: "%+.0f", (state.cropCenterX - 0.5) * 200)
        case .vertical: String(format: "%+.0f", (state.cropCenterY - 0.5) * 200)
        }
    }
}

private enum Adjustment: String, CaseIterable, Identifiable {
    case exposure, highlights, shadows, contrast, saturation, vibrance, warmth, sharpness, vignette

    var id: Self { self }
    var title: String { rawValue.capitalized }
    var shortTitle: String {
        switch self {
        case .saturation: "Saturate"
        case .highlights: "Highlight"
        case .sharpness: "Sharpen"
        default: title
        }
    }
    var symbol: String {
        switch self {
        case .exposure: "plusminus.circle"
        case .highlights: "sun.max"
        case .shadows: "circle.lefthalf.filled"
        case .contrast: "circle.righthalf.filled"
        case .saturation: "drop.fill"
        case .vibrance: "wand.and.stars"
        case .warmth: "thermometer.medium"
        case .sharpness: "triangle"
        case .vignette: "circle.dotted"
        }
    }
    var range: ClosedRange<Float> {
        switch self {
        case .exposure: -2...2
        case .contrast: -0.5...0.5
        case .sharpness, .vignette: 0...1
        default: -1...1
        }
    }
    func value(from state: EditState) -> Float {
        switch self {
        case .exposure: state.exposure
        case .highlights: state.highlights
        case .shadows: state.shadows
        case .contrast: state.contrast
        case .saturation: state.saturation
        case .vibrance: state.vibrance
        case .warmth: state.warmth
        case .sharpness: state.sharpness
        case .vignette: state.vignette
        }
    }
    func set(_ value: Float, on state: inout EditState) {
        switch self {
        case .exposure: state.exposure = value
        case .highlights: state.highlights = value
        case .shadows: state.shadows = value
        case .contrast: state.contrast = value
        case .saturation: state.saturation = value
        case .vibrance: state.vibrance = value
        case .warmth: state.warmth = value
        case .sharpness: state.sharpness = value
        case .vignette: state.vignette = value
        }
    }
    func displayValue(from state: EditState) -> String {
        let value = value(from: state)
        return self == .exposure ? String(format: "%+.1f EV", value) : String(format: "%+.2f", value)
    }
}

private struct CropLayout {
    let viewport: CGRect
    let imageSize: CGSize
}

private struct CropFrameOverlay: Shape {
    func path(in rect: CGRect) -> Path {
        let handle: CGFloat = 24
        var path = Path()
        path.addRect(rect)

        path.move(to: CGPoint(x: rect.minX, y: rect.minY + handle))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + handle, y: rect.minY))

        path.move(to: CGPoint(x: rect.maxX - handle, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + handle))

        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - handle))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - handle, y: rect.maxY))

        path.move(to: CGPoint(x: rect.minX + handle, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - handle))
        return path
    }
}

private struct RuleOfThirdsGrid: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for fraction in [CGFloat(1) / 3, CGFloat(2) / 3] {
            path.move(to: CGPoint(x: rect.minX + rect.width * fraction, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * fraction, y: rect.maxY))
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * fraction))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * fraction))
        }
        return path
    }
}
