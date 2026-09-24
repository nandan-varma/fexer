import Observation
import Photos
import SwiftUI

@Observable
final class GalleryViewModel: NSObject, PHPhotoLibraryChangeObserver {
    var photos: [PHAsset] = []
    var isLoading = false
    var authorizationStatus: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)

    private var fetchResult: PHFetchResult<PHAsset>?
    /// Bumped on every fetch and every change notification; lets an in-flight fetch
    /// detect that its snapshot went stale (see fetchPhotos) instead of overwriting
    /// newer photos with an old result.
    private var fetchGeneration = 0
    private let imageManager = PHCachingImageManager()

    override init() {
        super.init()
        if authorizationStatus == .authorized || authorizationStatus == .limited {
            PHPhotoLibrary.shared().register(self)
            fetchPhotos()
        }
    }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    func fetchPhotos() {
        isLoading = true
        fetchGeneration += 1
        let generation = fetchGeneration
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(
            format: "mediaType == %d || mediaType == %d",
            PHAssetMediaType.image.rawValue,
            PHAssetMediaType.video.rawValue
        )

        guard let library = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum, subtype: .smartAlbumUserLibrary, options: nil
        ).firstObject else {
            isLoading = false
            return
        }

        let result = PHAsset.fetchAssets(in: library, options: options)
        fetchResult = result

        Task { [weak self] in
            let assets: [PHAsset] = await Task.detached(priority: .utility) {
                var a: [PHAsset] = []
                a.reserveCapacity(result.count)
                for i in 0..<result.count { a.append(result.object(at: i)) }
                return a
            }.value
            guard let self else { return }
            guard self.fetchGeneration == generation else {
                // Stale snapshot — a change notification landed while the copy was in
                // flight and already published newer photos.
                self.isLoading = false
                return
            }
            self.photos = assets
            self.isLoading = false
        }
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
            Task { @MainActor in completion(image) }
        }
    }

    func fullImage(for asset: PHAsset, completion: @escaping (UIImage?) -> Void) -> PHImageRequestID {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat

        return imageManager.requestImage(
            for: asset,
            targetSize: PHImageManagerMaximumSize,
            contentMode: .aspectFit,
            options: options
        ) { image, _ in
            Task { @MainActor in completion(image) }
        }
    }

    func playerItem(for asset: PHAsset, completion: @escaping (AVPlayerItem?) -> Void) {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .automatic
        imageManager.requestPlayerItem(forVideo: asset, options: options) { item, _ in
            Task { @MainActor in completion(item) }
        }
    }

    func authorizeIfNeeded() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        authorizationStatus = status
        if status == .notDetermined {
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] newStatus in
                guard let self else { return }
                // Hoisted out of the Task: referencing the weak-optional captured `self`
                // inside the concurrently-executing closure is a Swift 6 error.
                Task { @MainActor in
                    self.authorizationStatus = newStatus
                    if newStatus == .authorized || newStatus == .limited {
                        PHPhotoLibrary.shared().register(self)
                        self.fetchPhotos()
                    }
                }
            }
        } else if status == .authorized || status == .limited {
            PHPhotoLibrary.shared().register(self)
            fetchPhotos()
        }
    }

    func delete(asset: PHAsset, completion: @escaping (Bool) -> Void) {
        performPhotoLibraryChange {
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.deleteAssets([asset] as NSArray)
            }) { success, _ in
                Task { @MainActor in completion(success) }
            }
        }
    }

    func cancelRequest(_ id: PHImageRequestID) {
        imageManager.cancelImageRequest(id)
    }
}

extension GalleryViewModel {
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in
            guard let result = fetchResult,
                  let changes = changeInstance.changeDetails(for: result)
            else { return }
            fetchGeneration += 1
            self.fetchResult = changes.fetchResultAfterChanges
            var updated: [PHAsset] = []
            changes.fetchResultAfterChanges.enumerateObjects { asset, _, _ in updated.append(asset) }
            self.photos = updated
        }
    }
}
