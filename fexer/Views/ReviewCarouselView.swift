import Photos
import SwiftUI

struct ReviewCarouselView: View {
    let initialPhoto: CapturedPhoto?
    let galleryViewModel: GalleryViewModel
    var onDismiss: (() -> Void)?
    var onOpenFullGallery: (() -> Void)?

    private var libraryAssets: [PHAsset] {
        let excluded = initialPhoto?.assetLocalIdentifier
        return galleryViewModel.photos
            .filter { $0.mediaType == .image }
            .filter { excluded == nil || $0.localIdentifier != excluded }
            .prefix(50)
            .map { $0 }
    }

    private var hasContent: Bool { initialPhoto != nil || !libraryAssets.isEmpty }

    var body: some View {
        if hasContent {
            TabView {
                if let photo = initialPhoto {
                    ReviewView(photo: photo, onDismiss: onDismiss)
                }
                ForEach(libraryAssets, id: \.localIdentifier) { asset in
                    LibraryPhotoPageView(
                        asset: asset,
                        galleryViewModel: galleryViewModel,
                        onDismiss: onDismiss,
                        onOpenFullGallery: onOpenFullGallery
                    )
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .background(Color.black)
            .ignoresSafeArea()
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "photo.stack")
                    .font(.system(size: 48))
                    .foregroundStyle(.white.opacity(0.3))
                Text("No Photos Yet")
                    .font(.system(size: 17))
                    .foregroundStyle(.white.opacity(0.5))
            }
            VStack {
                HStack {
                    CircleIconButton(systemName: "xmark", weight: .semibold) { onDismiss?() }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                Spacer()
            }
        }
    }
}

// MARK: - Library photo page

struct LibraryPhotoPageView: View {
    let asset: PHAsset
    let galleryViewModel: GalleryViewModel
    var onDismiss: (() -> Void)?
    var onOpenFullGallery: (() -> Void)?

    @State private var loadedImage: UIImage?
    @State private var shareData: Data?
    @State private var magnification: CGFloat = 1.0
    @State private var lastMagnification: CGFloat = 1.0
    @State private var showDeleteConfirmation = false
    @State private var requestID: PHImageRequestID?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image = loadedImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(magnification)
                    .gesture(magnificationGesture)
            } else {
                ProgressView().tint(.white)
            }

            VStack {
                // Top bar
                HStack {
                    CircleIconButton(systemName: "xmark", weight: .semibold) { onDismiss?() }

                    Spacer()

                    ReviewDeleteButton(showConfirmation: $showDeleteConfirmation, onDelete: deletePhoto)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)

                Spacer()

                // Bottom bar
                HStack(spacing: 28) {
                    Spacer()

                    SharePhotoLink(data: shareData)

                    if let openGallery = onOpenFullGallery {
                        Button(action: openGallery) {
                            Image(systemName: "square.grid.2x2")
                                .font(.system(size: 20))
                                .foregroundStyle(.white)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
        }
        .reviewGestures(magnification: $magnification, lastMagnification: $lastMagnification, onDismiss: onDismiss)
        .onAppear { loadImage() }
        .onDisappear { requestID.map { galleryViewModel.cancelRequest($0) } }
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                magnification = (lastMagnification * value).fxClamped(to: 1.0...10.0)
            }
            .onEnded { _ in lastMagnification = magnification }
    }

    private func loadImage() {
        requestID = galleryViewModel.fullImage(for: asset) { image in
            loadedImage = image
            shareData = image?.jpegData(compressionQuality: 0.95)
        }
    }

    private func deletePhoto() {
        galleryViewModel.delete(asset: asset) { success in
            if success { onDismiss?() }
        }
    }
}
