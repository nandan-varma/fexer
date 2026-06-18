import Photos
import SwiftUI
import Observation

@Observable
final class GalleryViewModel: NSObject {
    var photos: [PHAsset] = []
    var isLoading = false

    private var fetchResult: PHFetchResult<PHAsset>?
    private let imageManager = PHCachingImageManager()

    override init() {
        super.init()
        PHPhotoLibrary.shared().register(self)
        fetchPhotos()
    }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    func fetchPhotos() {
        isLoading = true
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 300

        let result = PHAsset.fetchAssets(with: .image, options: options)
        fetchResult = result

        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in assets.append(asset) }

        photos = assets
        isLoading = false
    }

    func thumbnail(for asset: PHAsset, size: CGSize, completion: @escaping (UIImage?) -> Void) -> PHImageRequestID {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .opportunistic

        return imageManager.requestImage(
            for: asset,
            targetSize: size,
            contentMode: .aspectFill,
            options: options
        ) { image, _ in
            DispatchQueue.main.async { completion(image) }
        }
    }

    func cancelRequest(_ id: PHImageRequestID) {
        imageManager.cancelImageRequest(id)
    }
}

extension GalleryViewModel: PHPhotoLibraryChangeObserver {
    func photoLibraryDidChange(_ changeInstance: PHChange) {
        guard let result = fetchResult,
              let changes = changeInstance.changeDetails(for: result)
        else { return }

        Task { @MainActor in
            self.fetchResult = changes.fetchResultAfterChanges
            var updated: [PHAsset] = []
            changes.fetchResultAfterChanges.enumerateObjects { asset, _, _ in updated.append(asset) }
            self.photos = updated
        }
    }
}
