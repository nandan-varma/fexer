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
    @State private var selectedHSLBand: Int = 0
    @State private var selectedCurveChannel: CurveChannel = .master
    @State private var showLUTImporter = false
    @State private var draggedCurveIndex: Int? = nil

    private let ciContext: CIContext = .shared

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
        .sheet(isPresented: $showLUTImporter) {
            LUTImporterView(bookmark: $state.importedLUTBookmark) {
                renderPreview()
            }
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
        switch mode {
        case .adjust:
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
        case .hsl:
            hslPanel.padding(.vertical, 8)
        case .curves:
            curvesPanel.padding(.vertical, 8)
        case .crop:
            cropControls.padding(.top, 10)
        }
    }

    private var bottomRail: some View {
        VStack(spacing: 8) {
            switch mode {
            case .adjust:
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Adjustment.allCases) { item in
                            adjustmentButton(item)
                        }
                    }
                    .padding(.horizontal, 18)
                }
            case .crop:
                aspectRatioRail
            case .hsl, .curves:
                EmptyView()
            }

            HStack {
                HStack(spacing: 26) {
                    modeButton(.adjust)
                    modeButton(.hsl)
                    modeButton(.curves)
                    modeButton(.crop)
                }
                .frame(maxWidth: .infinity)

                Button { showLUTImporter = true } label: {
                    VStack(spacing: 3) {
                        Image(systemName: state.importedLUTBookmark != nil ? "cube.fill" : "cube")
                            .font(.system(size: 17, weight: .medium))
                        Text("LUT")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(state.importedLUTBookmark != nil ? .yellow : .white.opacity(0.55))
                    .frame(width: 48)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
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
            filter.neutral = CIVector(x: CGFloat(6500 - state.warmth * 2000), y: 0)
            filter.targetNeutral = CIVector(x: 6500, y: 0)
            image = filter.outputImage ?? image
        }
        if state.sharpness != 0 {
            let filter = CIFilter.sharpenLuminance()
            filter.inputImage = image
            filter.sharpness = state.sharpness
            image = filter.outputImage ?? image
        }

        // Master tone curve (equal adjustment to all channels)
        if state.curveMaster != EditState.identityCurve {
            let pts = state.curveMaster
            let f = CIFilter.toneCurve()
            f.inputImage = image
            f.point0 = CGPoint(x: CGFloat(pts[0].x), y: CGFloat(pts[0].y))
            f.point1 = CGPoint(x: CGFloat(pts[1].x), y: CGFloat(pts[1].y))
            f.point2 = CGPoint(x: CGFloat(pts[2].x), y: CGFloat(pts[2].y))
            f.point3 = CGPoint(x: CGFloat(pts[3].x), y: CGFloat(pts[3].y))
            f.point4 = CGPoint(x: CGFloat(pts[4].x), y: CGFloat(pts[4].y))
            image = f.outputImage ?? image
        }

        // Per-channel R/G/B curves + HSL band mixer via baked 17³ LUT
        if state.hasHSLAdjustments || state.hasCurveAdjustments {
            let dim = 17
            var cube = [Float](repeating: 0, count: dim * dim * dim * 4)
            let bandCenters: [Float]    = [0.0, 0.083, 0.167, 0.333, 0.5, 0.611, 0.778, 0.917]
            let bandHalfWidths: [Float] = [0.083, 0.056, 0.056, 0.111, 0.056, 0.111, 0.083, 0.056]
            let bandValues = state.allHSLBands.map { state[keyPath: $0.1] }
            // Sort once outside the loop; evalCurve sorts per call which is 3×4913 = 14K sorts.
            let sortedCurveR = state.curveR.sorted { $0.x < $1.x }
            let sortedCurveG = state.curveG.sorted { $0.x < $1.x }
            let sortedCurveB = state.curveB.sorted { $0.x < $1.x }

            for bi in 0..<dim {
                for gi in 0..<dim {
                    for ri in 0..<dim {
                        var rv = Float(ri) / Float(dim - 1)
                        var gv = Float(gi) / Float(dim - 1)
                        var bv = Float(bi) / Float(dim - 1)

                        if state.hasCurveAdjustments {
                            rv = evalSortedCurve(sortedCurveR, at: rv)
                            gv = evalSortedCurve(sortedCurveG, at: gv)
                            bv = evalSortedCurve(sortedCurveB, at: bv)
                        }

                        if state.hasHSLAdjustments {
                            var (h, s, l) = rgb2hsl(r: rv, g: gv, b: bv)
                            var hShift: Float = 0, sDelta: Float = 0, lDelta: Float = 0
                            for i in 0..<8 {
                                let band = bandValues[i]
                                guard band.isNonZero else { continue }
                                let dist = hueDistance(h, bandCenters[i])
                                let hw = bandHalfWidths[i]
                                let inf = max(0, 1 - (dist / hw) * (dist / hw))
                                hShift += band.hue / 360.0 * inf
                                sDelta += band.saturation * inf
                                lDelta += band.luminance * inf
                            }
                            h = (h + hShift).truncatingRemainder(dividingBy: 1)
                            if h < 0 { h += 1 }
                            s = max(0, min(1, s + sDelta))
                            l = max(0, min(1, l + lDelta))
                            (rv, gv, bv) = hsl2rgb(h: h, s: s, l: l)
                        }

                        let idx = (bi * dim * dim + gi * dim + ri) * 4
                        cube[idx]     = max(0, min(1, rv))
                        cube[idx + 1] = max(0, min(1, gv))
                        cube[idx + 2] = max(0, min(1, bv))
                        cube[idx + 3] = 1.0
                    }
                }
            }
            let cubeData = Data(bytes: cube, count: cube.count * MemoryLayout<Float>.size)
            if let flt = CIFilter(name: "CIColorCubeWithColorSpace"),
               let sRGB = CGColorSpace(name: CGColorSpace.sRGB) {
                flt.setValue(Float(dim), forKey: "inputCubeDimension")
                flt.setValue(cubeData, forKey: "inputCubeData")
                flt.setValue(sRGB, forKey: "inputColorSpace")
                flt.setValue(image, forKey: kCIInputImageKey)
                image = flt.outputImage ?? image
            }
        }

        // Custom imported LUT (.cube file via security-scoped bookmark)
        if let bookmark = state.importedLUTBookmark {
            image = applyImportedLUT(to: image, bookmark: bookmark) ?? image
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

    // MARK: - HSL Panel

    @ViewBuilder private var hslPanel: some View {
        VStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(0..<8, id: \.self) { index in
                        let bandInfo = state.allHSLBands[index]
                        let band = state[keyPath: bandInfo.1]
                        let isSelected = selectedHSLBand == index
                        let isChanged = band != HSLBand()
                        Button {
                            selectedHSLBand = index
                            HapticManager.selectionChanged()
                        } label: {
                            Text(bandInfo.0)
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 12)
                                .frame(height: 28)
                                .background(isSelected ? hslBandColor(index) : Color.white.opacity(isChanged ? 0.15 : 0.07))
                                .foregroundStyle(isSelected ? .black : (isChanged ? .yellow : .white))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 18)
            }

            let kp = state.allHSLBands[selectedHSLBand].1
            VStack(spacing: 8) {
                hslSliderRow("Hue", range: -180...180, format: "%+.0f°",
                    get: { Double(state[keyPath: kp].hue) },
                    set: { v in var b = state[keyPath: kp]; b.hue = Float(v); state[keyPath: kp] = b; renderPreview() })
                hslSliderRow("Saturation", range: -1...1, format: "%+.2f",
                    get: { Double(state[keyPath: kp].saturation) },
                    set: { v in var b = state[keyPath: kp]; b.saturation = Float(v); state[keyPath: kp] = b; renderPreview() })
                hslSliderRow("Luminance", range: -1...1, format: "%+.2f",
                    get: { Double(state[keyPath: kp].luminance) },
                    set: { v in var b = state[keyPath: kp]; b.luminance = Float(v); state[keyPath: kp] = b; renderPreview() })
            }
            .padding(.horizontal, 18)
        }
    }

    private func hslBandColor(_ index: Int) -> Color {
        [Color.red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink][index]
    }

    private func hslSliderRow(
        _ label: String, range: ClosedRange<Double>, format: String,
        get: @escaping () -> Double, set: @escaping (Double) -> Void
    ) -> some View {
        let val = get()
        return HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .leading)
            Slider(value: Binding(get: get, set: set), in: range)
                .tint(.yellow)
            Text(String(format: format, val))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(val == 0 ? Color.white.opacity(0.4) : Color.yellow)
                .frame(width: 44, alignment: .trailing)
        }
    }

    // MARK: - Curves Panel

    @ViewBuilder private var curvesPanel: some View {
        VStack(spacing: 8) {
            HStack(spacing: 0) {
                ForEach(CurveChannel.allCases) { channel in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { selectedCurveChannel = channel }
                    } label: {
                        Text(channel.rawValue)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(selectedCurveChannel == channel ? .black : channel.color.opacity(0.85))
                            .frame(maxWidth: .infinity)
                            .frame(height: 30)
                            .background(selectedCurveChannel == channel ? channel.color : .clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 18)

            let pts = state[keyPath: selectedCurveChannel.keyPath]
            let channelColor = selectedCurveChannel.color
            GeometryReader { geo in
                ZStack {
                    Canvas { ctx, size in
                        let sorted = pts.sorted { $0.x < $1.x }

                        ctx.stroke(Path { p in
                            for t: CGFloat in [0.25, 0.5, 0.75] {
                                p.move(to: CGPoint(x: size.width * t, y: 0))
                                p.addLine(to: CGPoint(x: size.width * t, y: size.height))
                                p.move(to: CGPoint(x: 0, y: size.height * (1 - t)))
                                p.addLine(to: CGPoint(x: size.width, y: size.height * (1 - t)))
                            }
                        }, with: .color(.white.opacity(0.1)), lineWidth: 0.5)

                        ctx.stroke(Path { p in
                            p.move(to: CGPoint(x: 0, y: size.height))
                            p.addLine(to: CGPoint(x: size.width, y: 0))
                        }, with: .color(.white.opacity(0.2)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                        var curvePath = Path()
                        for i in 0...48 {
                            let x = Float(i) / 48.0
                            var y = x
                            for j in 1..<sorted.count {
                                let p0 = sorted[j-1], p1 = sorted[j]
                                if x <= p1.x {
                                    let t = (x - p0.x) / max(p1.x - p0.x, 0.001)
                                    y = p0.y + t * (p1.y - p0.y)
                                    break
                                }
                                if j == sorted.count - 1 { y = p1.y }
                            }
                            let cp = CGPoint(x: CGFloat(x) * size.width, y: (1 - CGFloat(y)) * size.height)
                            if i == 0 { curvePath.move(to: cp) } else { curvePath.addLine(to: cp) }
                        }
                        ctx.stroke(curvePath, with: .color(channelColor), lineWidth: 2)

                        for (i, pt) in sorted.enumerated() {
                            let cx = CGFloat(pt.x) * size.width
                            let cy = (1 - CGFloat(pt.y)) * size.height
                            let r: CGFloat = draggedCurveIndex == i ? 8 : 5
                            ctx.fill(Path(ellipseIn: CGRect(x: cx-r-2, y: cy-r-2, width: (r+2)*2, height: (r+2)*2)), with: .color(.white))
                            ctx.fill(Path(ellipseIn: CGRect(x: cx-r, y: cy-r, width: r*2, height: r*2)), with: .color(channelColor))
                        }
                    }

                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(curveDragGesture(in: geo.size))
                }
            }
            .frame(height: 90)
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 18)

            let kp = selectedCurveChannel.keyPath
            let ptLabels = ["Blacks", "Shadows", "Mids", "Lights", "Whites"]
            VStack(spacing: 5) {
                ForEach(0..<5, id: \.self) { i in
                    HStack {
                        Text(ptLabels[i])
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .leading)
                        Slider(value: Binding(
                            get: { Double(state[keyPath: kp][i].y) },
                            set: { v in var arr = state[keyPath: kp]; arr[i].y = Float(v); state[keyPath: kp] = arr; renderPreview() }
                        ), in: 0...1)
                        .tint(selectedCurveChannel.color)
                        Text(String(format: "%.2f", state[keyPath: kp][i].y))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 32, alignment: .trailing)
                    }
                }
            }
            .padding(.horizontal, 18)
        }
    }

    private func curveDragGesture(in size: CGSize) -> some Gesture {
        let kp = selectedCurveChannel.keyPath
        return DragGesture(minimumDistance: 0)
            .onChanged { value in
                if draggedCurveIndex == nil {
                    let pts = state[keyPath: kp]
                    var nearest = 0
                    var minDist = CGFloat.infinity
                    for (i, pt) in pts.enumerated() {
                        let px = CGFloat(pt.x) * size.width
                        let py = (1 - CGFloat(pt.y)) * size.height
                        let dist = hypot(value.startLocation.x - px, value.startLocation.y - py)
                        if dist < minDist { minDist = dist; nearest = i }
                    }
                    if minDist < 36 { draggedCurveIndex = nearest }
                }
                if let idx = draggedCurveIndex {
                    let newY = Float(max(0, min(1, 1 - value.location.y / size.height)))
                    var arr = state[keyPath: kp]
                    arr[idx].y = newY
                    state[keyPath: kp] = arr
                    renderPreview(debounced: false)
                }
            }
            .onEnded { _ in draggedCurveIndex = nil }
    }

    // MARK: - Static helpers for applyEdits

    nonisolated private static func evalSortedCurve(_ s: [SIMD2<Float>], at x: Float) -> Float {
        guard s.count >= 2 else { return x }
        if x <= s[0].x { return s[0].y }
        if x >= s[s.count - 1].x { return s[s.count - 1].y }
        for i in 1..<s.count {
            if x <= s[i].x {
                let t = (x - s[i-1].x) / max(s[i].x - s[i-1].x, 0.001)
                return s[i-1].y + t * (s[i].y - s[i-1].y)
            }
        }
        return x
    }

    nonisolated private static func rgb2hsl(r: Float, g: Float, b: Float) -> (Float, Float, Float) {
        let mx = max(r, g, b), mn = min(r, g, b)
        let l = (mx + mn) * 0.5
        let d = mx - mn
        guard d > 0.001 else { return (0, 0, l) }
        let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        var h: Float
        if mx == r       { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) / 6 }
        else if mx == g  { h = ((b - r) / d + 2) / 6 }
        else             { h = ((r - g) / d + 4) / 6 }
        if h < 0 { h += 1 }
        return (h, s, l)
    }

    nonisolated private static func hsl2rgb(h: Float, s: Float, l: Float) -> (Float, Float, Float) {
        guard s > 0.001 else { return (l, l, l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        return (hue2rgb(p: p, q: q, t: h + 1.0/3),
                hue2rgb(p: p, q: q, t: h),
                hue2rgb(p: p, q: q, t: h - 1.0/3))
    }

    nonisolated private static func hue2rgb(p: Float, q: Float, t: Float) -> Float {
        var t = t
        if t < 0 { t += 1 }; if t > 1 { t -= 1 }
        if t < 1.0/6 { return p + (q - p) * 6 * t }
        if t < 0.5   { return q }
        if t < 2.0/3 { return p + (q - p) * (2.0/3 - t) * 6 }
        return p
    }

    nonisolated private static func hueDistance(_ a: Float, _ b: Float) -> Float {
        let d = abs(a - b); return min(d, 1 - d)
    }

    nonisolated private final class ParsedLUTEntry: NSObject {
        let cubeData: Data; let dimension: Int
        init(_ d: Data, _ dim: Int) { cubeData = d; dimension = dim }
    }
    nonisolated(unsafe) private static let importedLUTCache: NSCache<NSData, ParsedLUTEntry> = {
        let c = NSCache<NSData, ParsedLUTEntry>(); c.countLimit = 4; return c
    }()

    nonisolated private static func applyImportedLUT(to image: CIImage, bookmark: Data) -> CIImage? {
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: .withoutUI,
                                 relativeTo: nil, bookmarkDataIsStale: &isStale),
              !isStale else { return nil }

        let cacheKey = bookmark as NSData
        let entry: ParsedLUTEntry
        if let cached = importedLUTCache.object(forKey: cacheKey) {
            entry = cached
        } else {
            guard url.startAccessingSecurityScopedResource() else { return nil }
            defer { url.stopAccessingSecurityScopedResource() }
            guard let content = try? String(contentsOf: url, encoding: .utf8),
                  let (cubeData, dim) = LUTLoader.parseCube(content: content) else { return nil }
            let newEntry = ParsedLUTEntry(cubeData, dim)
            importedLUTCache.setObject(newEntry, forKey: cacheKey)
            entry = newEntry
        }

        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
              let flt = CIFilter(name: "CIColorCubeWithColorSpace") else { return nil }
        flt.setValue(Float(entry.dimension), forKey: "inputCubeDimension")
        flt.setValue(entry.cubeData, forKey: "inputCubeData")
        flt.setValue(sRGB, forKey: "inputColorSpace")
        flt.setValue(image, forKey: kCIInputImageKey)
        return flt.outputImage
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
    case hsl
    case curves
    case crop

    var title: String {
        switch self {
        case .adjust: "Adjust"
        case .hsl:    "Color"
        case .curves: "Curves"
        case .crop:   "Crop"
        }
    }
    var symbol: String {
        switch self {
        case .adjust: "slider.horizontal.3"
        case .hsl:    "paintpalette"
        case .curves: "chart.line.uptrend.xyaxis"
        case .crop:   "crop.rotate"
        }
    }
}

private enum CurveChannel: String, CaseIterable, Identifiable {
    case master = "Master"
    case red    = "Red"
    case green  = "Green"
    case blue   = "Blue"

    var id: String { rawValue }

    var keyPath: WritableKeyPath<EditState, [SIMD2<Float>]> {
        switch self {
        case .master: \.curveMaster
        case .red:    \.curveR
        case .green:  \.curveG
        case .blue:   \.curveB
        }
    }

    var color: Color {
        switch self {
        case .master: .white
        case .red:    .red
        case .green:  .green
        case .blue:   .blue
        }
    }
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
