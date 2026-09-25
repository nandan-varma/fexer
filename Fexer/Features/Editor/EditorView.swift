import SwiftUI
import UniformTypeIdentifiers

struct EditorView: View {
    @State var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var tool: Tool = .adjust
    @State private var adjustment: Adjustment = .exposure
    @State private var color = 0
    @State private var channel = 0
    @State private var comparing = false
    @State private var styles = false
    @State private var importing = false
    @State private var discard = false
    @State private var beforeStyles = EditRecipe()
    enum Tool: String, CaseIterable, Identifiable {
        case adjust = "Adjust", crop = "Crop", color = "Color", curves = "Curves"
        var id: Self { self }
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                GeometryReader { geometry in
                    ZStack {
                        Theme.background
                        if let image = comparing ? model.originalImage : model.image {
                            Image(uiImage: image).resizable().scaledToFit().frame(width: geometry.size.width, height: geometry.size.height)
                        } else { ProgressView("Loading photo") }
                        if comparing { Text("ORIGINAL").font(.caption.weight(.semibold)).padding(8).background(.black.opacity(0.7), in: Capsule()).frame(maxHeight: .infinity, alignment: .top).padding() }
                    }
                }.frame(minHeight: 160)
                HStack {
                    Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward").frame(width: 44, height: 44) }.disabled(model.history.past.isEmpty).accessibilityLabel("Undo")
                    Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward").frame(width: 44, height: 44) }.disabled(model.history.future.isEmpty).accessibilityLabel("Redo")
                    Spacer()
                    Button { comparing.toggle() } label: { Label(comparing ? "Edited" : "Original", systemImage: "square.on.square") }.font(.caption).frame(minHeight: 44)
                    Spacer()
                    Button { beforeStyles = model.recipe; styles = true } label: { Image(systemName: "camera.filters").frame(width: 44, height: 44) }.accessibilityLabel("Photo styles")
                }.padding(.horizontal, 12)
                Picker("Editing tool", selection: $tool) { ForEach(Tool.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).padding(.horizontal, 18)
                ScrollView {
                    VStack(spacing: 16) {
                        switch tool {
                        case .adjust: adjustmentTools
                        case .crop: cropTools
                        case .color: colorTools
                        case .curves: curveTools
                        }
                    }.padding(20)
                }.frame(height: 245).background(Theme.surface.opacity(0.55))
            }
            .background(Theme.background)
            .navigationTitle("Edit photo").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { if model.recipe != model.item.recipe { discard = true } else { dismiss() } } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { if await model.save() { dismiss() } } }.disabled(model.saving || model.source == nil).accessibilityIdentifier("saveEdits")
                }
                ToolbarItem(placement: .secondaryAction) { Button("Reset all edits", role: .destructive) { model.change { $0 = EditRecipe() } } }
            }
        }
        .preferredColorScheme(.dark).tint(Theme.accent)
        .task { await model.load() }
        .onChange(of: model.recipe) { model.render() }
        .interactiveDismissDisabled(model.recipe != model.item.recipe)
        .sheet(isPresented: $styles, onDismiss: { model.history.record(beforeStyles, replacing: model.recipe) }) { StylePicker(recipe: $model.recipe, renderer: model.library.renderer, source: model.source) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { Task { await model.importCube(url) } }
            case .failure(let error): model.issue = AppIssue("Import failed", error.localizedDescription)
            }
        }
        .confirmationDialog("Discard your changes?", isPresented: $discard, titleVisibility: .visible) { Button("Discard changes", role: .destructive) { dismiss() } }
        .issueAlert($model.issue)
    }
    private var adjustmentTools: some View {
        VStack(spacing: 16) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Adjustment.allCases) { value in
                        Button { adjustment = value } label: {
                            VStack(spacing: 6) { Image(systemName: value.symbol).font(.title3); Text(value.rawValue).font(.caption2) }.frame(minWidth: 62, minHeight: 58)
                        }.tint(adjustment == value ? Theme.accent : Theme.muted)
                    }
                }
            }
            HapticScrubber(title: adjustment.rawValue, value: Binding(get: { model.recipe[keyPath: adjustment.keyPath] }, set: { model.recipe[keyPath: adjustment.keyPath] = $0 }), range: adjustment.range, onEditingChanged: model.gesture)
            Button("Reset \(adjustment.rawValue.lowercased())") { model.change { $0[keyPath: adjustment.keyPath] = 0 } }.font(.caption)
        }
    }
    private var cropTools: some View {
        VStack(spacing: 16) {
            HStack {
                Picker("Aspect ratio", selection: Binding(get: { model.recipe.ratio }, set: { ratio in model.change { $0.ratio = ratio } })) { ForEach(FrameRatio.allCases) { Text($0 == .original ? "Original" : $0.rawValue).tag($0) } }
                Spacer()
                Button { model.change { $0.quarterTurns += 1 } } label: { Label("Rotate", systemImage: "rotate.left") }.labelStyle(.iconOnly).frame(width: 44, height: 44)
                Button { model.change { $0.flipped.toggle() } } label: { Label("Flip", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") }.labelStyle(.iconOnly).frame(width: 44, height: 44)
            }
            HapticScrubber(title: "Straighten", value: $model.recipe.straighten, range: -45...45, display: String(format: "%.1f°", model.recipe.straighten), onEditingChanged: model.gesture)
            HapticScrubber(title: "Crop zoom", value: $model.recipe.cropZoom, range: 1...6, display: String(format: "%.1f×", model.recipe.cropZoom), onEditingChanged: model.gesture)
            HapticScrubber(title: "Horizontal position", value: $model.recipe.cropX, range: 0...1, display: model.recipe.cropX.formatted(.percent.precision(.fractionLength(0))), onEditingChanged: model.gesture)
            HapticScrubber(title: "Vertical position", value: $model.recipe.cropY, range: 0...1, display: model.recipe.cropY.formatted(.percent.precision(.fractionLength(0))), onEditingChanged: model.gesture)
        }
    }
    private var colorTools: some View {
        VStack(spacing: 16) {
            Picker("Color range", selection: $color) { ForEach(Array(["Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta"].enumerated()), id: \.offset) { index, name in Text(name).tag(index) } }
            HapticScrubber(title: "Hue", value: $model.recipe.colors[color].hue, range: -60...60, onEditingChanged: model.gesture)
            HapticScrubber(title: "Saturation", value: $model.recipe.colors[color].saturation, range: -1...1, onEditingChanged: model.gesture)
            HapticScrubber(title: "Luminance", value: $model.recipe.colors[color].luminance, range: -1...1, onEditingChanged: model.gesture)
            if model.recipe.importedCube != nil {
                Button("Remove imported LUT") { model.change { $0.importedCube = nil } }
            } else { Button("Import .cube LUT") { importing = true } }
        }
    }
    private var curveTools: some View {
        VStack(spacing: 12) {
            Picker("Curve channel", selection: $channel) { Text("RGB").tag(0); Text("Red").tag(1); Text("Green").tag(2); Text("Blue").tag(3) }.pickerStyle(.segmented)
            Canvas { context, size in
                var path = Path()
                for index in 0..<5 {
                    let point = CGPoint(x: Double(index) / 4 * size.width, y: (1 - model.recipe.curves[channel][index]) * size.height)
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                context.stroke(path, with: .color(Theme.accent), lineWidth: 2)
            }.frame(height: 75).background(.white.opacity(0.04))
            ForEach(0..<5) { index in
                HapticScrubber(title: ["Blacks", "Shadows", "Midtones", "Highlights", "Whites"][index], value: $model.recipe.curves[channel][index], range: 0...1,
                                display: model.recipe.curves[channel][index].formatted(.percent.precision(.fractionLength(0))), onEditingChanged: model.gesture)
            }
            Button("Reset channel") { model.change { $0.curves[channel] = [0, 0.25, 0.5, 0.75, 1] } }
        }
    }
}
