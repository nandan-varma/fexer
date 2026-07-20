import AVKit
import Photos
import SwiftUI

struct GalleryView: View {
    @Environment(AppState.self) var appState
    @State private var galleryViewModel = GalleryViewModel()
    @State private var selectedAsset: PHAsset?

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
                            .onTapGesture { selectedAsset = asset }
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
        .sheet(item: $selectedAsset) { asset in
            GalleryDetailView(asset: asset, viewModel: galleryViewModel)
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
            ZStack(alignment: .bottomLeading) {
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

                if asset.mediaType == .video {
                    HStack(spacing: 3) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 9, weight: .semibold))
                        Text(asset.duration.videoDurationString)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.55))
                }
            }
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

private struct GalleryDetailView: View {
    let asset: PHAsset
    let viewModel: GalleryViewModel
    @Environment(\.dismiss) var dismiss

    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var requestID: PHImageRequestID?
    @State private var showDeleteConfirm = false
    @State private var shareData: Data?
    @State private var magnification: CGFloat = 1
    @State private var lastMagnification: CGFloat = 1

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if asset.mediaType == .video {
                if let player {
                    VideoPlayer(player: player)
                        .ignoresSafeArea()
                } else {
                    ProgressView().tint(.white)
                }
            } else {
                if let img = image {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .scaleEffect(magnification)
                        .gesture(magnificationGesture)
                        .onTapGesture(count: 2) {
                            let target: CGFloat = magnification > 1.5 ? 1 : 2.5
                            withAnimation(.spring()) { magnification = target }
                            lastMagnification = target
                        }
                } else {
                    ProgressView().tint(.white)
                }
            }

            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(.black.opacity(0.5), in: Circle())
                    }
                    Spacer()
                    Button {
                        showDeleteConfirm = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(.black.opacity(0.5), in: Circle())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                Spacer()

                if asset.mediaType == .image, let data = shareData {
                    HStack {
                        Spacer()
                        ShareLink(item: data, preview: SharePreview("Photo")) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 20))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .background(.black.opacity(0.5), in: Circle())
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 40)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear(perform: loadAsset)
        .onDisappear {
            if let id = requestID { viewModel.cancelRequest(id) }
            player?.pause()
        }
        .confirmationDialog("Delete this item?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                viewModel.delete(asset: asset) { _ in dismiss() }
            }
        }
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { v in magnification = (lastMagnification * v).fxClamped(to: 1...10) }
            .onEnded { _ in lastMagnification = magnification }
    }

    private func loadAsset() {
        if asset.mediaType == .video {
            viewModel.playerItem(for: asset) { item in
                guard let item else { return }
                player = AVPlayer(playerItem: item)
                player?.play()
            }
        } else {
            requestID = viewModel.fullImage(for: asset) { img in
                image = img
                guard let img else { return }
                Task.detached(priority: .utility) {
                    let data = img.jpegData(compressionQuality: 0.95)
                    await MainActor.run { self.shareData = data }
                }
            }
        }
    }
}

extension PHAsset: @retroactive Identifiable {
    public var id: String { localIdentifier }
}

private extension TimeInterval {
    var videoDurationString: String {
        let m = Int(self) / 60
        let s = Int(self) % 60
        return m > 0 ? String(format: "%d:%02d", m, s) : String(format: "0:%02d", s)
    }
}
