import SwiftUI
import Photos

struct GalleryView: View {
    @Environment(AppState.self) var appState
    @State private var galleryViewModel = GalleryViewModel()
    @State private var selectedPhoto: UIImage?
    @State private var showDetail = false

    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(galleryViewModel.photos, id: \.localIdentifier) { asset in
                        AssetThumbnailView(asset: asset, viewModel: galleryViewModel)
                            .aspectRatio(1, contentMode: .fill)
                            .clipped()
                    }
                }
            }
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        appState.currentScreen = .camera
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Text("\(galleryViewModel.photos.count)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .background(Color.black)
            .preferredColorScheme(.dark)
        }
    }
}

private struct AssetThumbnailView: View {
    let asset: PHAsset
    let viewModel: GalleryViewModel

    @State private var thumbnail: UIImage?
    @State private var requestID: PHImageRequestID?

    var body: some View {
        GeometryReader { geo in
            Group {
                if let img = thumbnail {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Color(white: 0.1)
                        .overlay(
                            Image(systemName: "photo")
                                .foregroundStyle(.white.opacity(0.2))
                        )
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .onAppear {
            let size = CGSize(width: 200, height: 200)
            requestID = viewModel.thumbnail(for: asset, size: size) { img in
                thumbnail = img
            }
        }
        .onDisappear {
            if let id = requestID { viewModel.cancelRequest(id) }
        }
    }
}
