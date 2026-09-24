import SwiftUI

struct LibraryView: View {
    @Bindable var library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected: LibraryItem?
    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 2)]

    var body: some View {
        NavigationStack {
            Group {
                if library.items.isEmpty && !library.loading {
                    ContentUnavailableView("No captures yet", systemImage: "photo.on.rectangle",
                                          description: Text("Photos and videos you capture in Fexer appear here."))
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(library.items) { item in
                                Button { selected = item } label: { LibraryCell(item: item, library: library) }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(item.kind == .video ? "Video, \(item.createdAt.formatted(date: .abbreviated, time: .shortened))" : "Photo, \(item.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            }
                        }
                    }
                }
            }
            .background(Theme.background)
            .navigationTitle("Library").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task { await library.load() }
            .navigationDestination(item: $selected) { item in CaptureDetail(item: item, library: library) }
            .issueAlert($library.issue)
        }
        .preferredColorScheme(.dark).tint(Theme.accent)
    }
}

private struct LibraryCell: View {
    let item: LibraryItem
    let library: LibraryModel
    var body: some View {
        CaptureThumbnail(item: item, library: library)
            .aspectRatio(1, contentMode: .fill)
            .clipped()
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: 3) {
                    if item.favorite { Image(systemName: "heart.fill") }
                    if item.kind == .video { Image(systemName: "video.fill") }
                    if item.needsPhotosSave { Image(systemName: "icloud.and.arrow.up") }
                }.font(.caption2).foregroundStyle(.white).shadow(radius: 1).padding(5)
            }
    }
}

struct CaptureThumbnail: View {
    let item: LibraryItem
    let library: LibraryModel
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            Theme.surface
            if let image { Image(uiImage: image).resizable().scaledToFill() }
        }
        .task(id: "\(item.id)-\(item.revision)") { image = await library.thumbnail(item) }
    }
}
