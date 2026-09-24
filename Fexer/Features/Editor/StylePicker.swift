import SwiftUI

struct StylePicker: View {
    @Binding var recipe: EditRecipe
    let renderer: ImageRenderer
    let source: Data?
    @Environment(\.dismiss) private var dismiss
    @State private var category: PhotoStyle.Category = .film
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Find your feeling.").font(.system(size: 30, weight: .medium, design: .serif))
                        Text("A starting point, never a commitment. Change your look later without losing the original.").font(.subheadline).foregroundStyle(Theme.muted)
                    }
                    Picker("Style collection", selection: $category) { ForEach(PhotoStyle.Category.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 14)], spacing: 20) {
                        ForEach([PhotoStyle.original] + PhotoStyle.all.filter { $0.category == category && $0.id != "original" }) { style in
                            Button { recipe.styleID = style.id } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    StyleThumbnail(style: style, source: source, renderer: renderer)
                                        .frame(height: 148).clipped().clipShape(RoundedRectangle(cornerRadius: 12))
                                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(recipe.styleID == style.id ? Theme.accent : .clear, lineWidth: 2))
                                    HStack { Text(style.name).font(.subheadline.weight(.medium)); Spacer(); if recipe.styleID == style.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent) } }
                                    Text(style.detail).font(.caption).foregroundStyle(Theme.muted).multilineTextAlignment(.leading).frame(minHeight: 32, alignment: .top)
                                }
                            }.buttonStyle(.plain).accessibilityLabel(style.name).accessibilityAddTraits(recipe.styleID == style.id ? .isSelected : [])
                        }
                    }
                    if recipe.styleID != "original" { HapticScrubber(title: "Strength", value: $recipe.intensity, range: 0...1, display: recipe.intensity.formatted(.percent.precision(.fractionLength(0)))) }
                }.padding(20)
            }.background(Theme.background).navigationTitle("Photo styles").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.preferredColorScheme(.dark).tint(Theme.accent)
    }
}

private struct StyleThumbnail: View {
    let style: PhotoStyle
    let source: Data?
    let renderer: ImageRenderer
    @State private var image: UIImage?
    var body: some View {
        GeometryReader { geometry in
            Group {
                if let image { Image(uiImage: image).resizable().scaledToFill() }
                else { Rectangle().fill(Theme.surface).overlay { ProgressView() } }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }.task(id: style.id) {
            guard let data = source ?? UIImage(named: "SamplePreview")?.jpegData(compressionQuality: 0.85) else { return }
            do {
                var edit = EditRecipe(); edit.styleID = style.id
                let pixels = try await renderer.preview(data: data, edit: edit, dimension: 360)
                if !Task.isCancelled { image = UIImage(cgImage: pixels) }
            } catch { Diagnostics.report(error, operation: "Render style thumbnail") }
        }.accessibilityHidden(true)
    }
}
