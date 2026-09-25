import AVKit
import SwiftUI

struct CaptureDetail: View {
    let item: LibraryItem
    @Bindable var library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var confirmDelete = false
    @State private var shareFile: ShareableFile?
    @State private var image: UIImage?
    @State private var videoURL: URL?

    private var current: LibraryItem { library.items.first { $0.id == item.id } ?? item }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if current.kind == .video {
                if let videoURL { VideoPlayer(player: AVPlayer(url: videoURL)) } else { ProgressView() }
            } else if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                ProgressView()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(current.createdAt, format: .dateTime.day().month().year().hour().minute())
                    .font(.caption).foregroundStyle(Theme.muted)
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { Task { await library.toggleFavorite(current) } } label: {
                    Image(systemName: current.favorite ? "heart.fill" : "heart")
                }.tint(current.favorite ? Theme.accent : .white)
                    .accessibilityLabel(current.favorite ? "Remove favorite" : "Add favorite")
                Menu {
                    if current.kind == .photo {
                        Button { editing = true } label: { Label("Edit", systemImage: "slider.horizontal.3") }
                    }
                    Button { share() } label: { Label("Share", systemImage: "square.and.arrow.up") }
                    if current.needsPhotosSave {
                        Button { Task { await library.export(current) } } label: { Label("Save to Photos", systemImage: "arrow.down.circle") }
                    }
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("More options")
            }
        }
        .task(id: current.revision) { await load() }
        .sheet(isPresented: $editing) { EditorView(model: EditorModel(item: current, library: library)) }
        .sheet(item: $shareFile) { file in ActivityView(url: file.url) }
        .confirmationDialog("Delete this capture?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { if await library.delete(current) { dismiss() } } }
        }
        .issueAlert($library.issue)
    }

    private func load() async {
        if current.kind == .video { videoURL = await library.store.sourceURL(current); return }
        do {
            try await Diagnostics.time("captureDetail.load") {
                let data = try await library.store.source(for: current)
                let pixels = try await library.renderer.preview(data: data, edit: current.recipe)
                image = UIImage(cgImage: pixels)
            }
        } catch { Diagnostics.report(error, operation: "Load photo") }
    }

    private func share() {
        Task {
            let captured = current
            do {
                try await Diagnostics.time("captureDetail.share") {
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString + "." + (captured.kind == .video ? "mov" : captured.sourceExtension))
                    if captured.kind == .video {
                        try FileManager.default.copyItem(at: await library.store.sourceURL(captured), to: url)
                    } else {
                        let data = try await library.store.source(for: captured)
                        let export = captured.recipe.isModified ? try await library.renderer.export(data: data, edit: captured.recipe, format: .jpeg) : data
                        try export.write(to: url)
                    }
                    shareFile = ShareableFile(url: url)
                }
            } catch { Diagnostics.report(error, operation: "Share capture") }
        }
    }
}

struct ShareableFile: Identifiable { let id = UUID(); let url: URL }

struct ActivityView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
