import AVFoundation
import Foundation
import Observation
import UIKit

@MainActor @Observable
final class LibraryModel {
    private(set) var items: [LibraryItem] = []
    private(set) var loading = false
    private(set) var exporting: Set<UUID> = []
    var issue: AppIssue?
    let store: CaptureStore
    let renderer: ImageRenderer
    private let exporter: any PhotoExporting
    private let thumbnails = NSCache<NSString, UIImage>()

    init(store: CaptureStore, renderer: ImageRenderer, exporter: any PhotoExporting = PhotosExporter()) {
        self.store = store
        self.renderer = renderer
        self.exporter = exporter
        thumbnails.totalCostLimit = 32 * 1024 * 1024
    }

    func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do { items = try await store.list() }
        catch { present(error, operation: "Load library") }
    }

    /// The Photos-library round trip (`export`) can take hundreds of ms to over a second — far
    /// longer than the local save. Firing it in the background lets the shutter (gated on
    /// `pendingCapture`/this call returning) re-enable as soon as the original is safely on disk,
    /// instead of blocking every capture on a full PHPhotoLibrary import. The existing
    /// `needsPhotosSave` badge and Settings bulk-export action already cover the "still pending"
    /// state this creates.
    func accept(_ payload: PhotoPayload, recipe: EditRecipe, location: GeoTag?, autoExport: Bool) async throws -> LibraryItem {
        // needsPhotosSave is baked into the one record.json write inside store.save — writing it
        // there and then rewriting it here was a second full disk write on every capture (~40ms).
        let item = try await store.save(payload, recipe: recipe, location: location, needsPhotosSave: autoExport)
        items.insert(item, at: 0)
        if autoExport { Task { await Diagnostics.time("library.photosExport (background)") { await self.export(item) } } }
        return items.first { $0.id == item.id } ?? item
    }

    func acceptVideo(url: URL, location: GeoTag?, autoExport: Bool) async throws -> LibraryItem {
        let item = try await store.saveVideo(from: url, location: location, needsPhotosSave: autoExport)
        items.insert(item, at: 0)
        if autoExport { Task { await Diagnostics.time("library.photosExport (background)") { await self.export(item) } } }
        return item
    }

    func export(_ original: LibraryItem) async {
        guard !exporting.contains(original.id), var item = items.first(where: { $0.id == original.id }) else { return }
        if item.photosIdentifier != nil, item.exportedRecipe == item.recipe { return }
        exporting.insert(item.id)
        defer { exporting.remove(item.id) }
        do {
            let id: String
            if item.kind == .video {
                id = try await Diagnostics.time("export.photosSaveVideo") { try await PhotosExporter().saveVideo(url: store.sourceURL(item), date: item.createdAt, location: item.location) }
            } else {
                let source = try await store.source(for: item)
                // A Live Photo must retain the original still/movie pairing. Edited exports are stills.
                let unchanged = !item.recipe.isModified
                let data = unchanged ? source : try await Diagnostics.time("export.render") { try await renderer.export(data: source, edit: item.recipe, format: .jpeg) }
                let live = unchanged ? await store.liveURL(item) : nil
                id = try await Diagnostics.time("export.photosSavePhoto (\(data.count / 1024)KB)") { try await exporter.savePhoto(data: data, rawURL: store.rawURL(item), liveURL: live, date: item.createdAt, location: item.location) }
            }
            item.photosIdentifier = id
            item.exportedRecipe = item.recipe
            item.needsPhotosSave = false
            try await store.update(item)
            replace(item)
        } catch {
            item.needsPhotosSave = true
            do { try await store.update(item); replace(item) }
            catch { Diagnostics.report(error, operation: "Persist pending export") }
            present(error, operation: "Save to Photos")
        }
    }

    func saveEdits(_ recipe: EditRecipe, for original: LibraryItem) async throws -> LibraryItem {
        guard var item = items.first(where: { $0.id == original.id }) else { throw AppIssue.decodingFailed }
        item.recipe = recipe.validated
        item.revision += 1
        item.needsPhotosSave = item.photosIdentifier != nil && item.exportedRecipe != item.recipe
        try await store.update(item)
        replace(item)
        return item
    }

    func toggleFavorite(_ original: LibraryItem) async {
        guard var item = items.first(where: { $0.id == original.id }) else { return }
        item.favorite.toggle()
        do { try await store.update(item); replace(item) }
        catch { present(error, operation: "Save favorite") }
    }

    func delete(_ item: LibraryItem) async -> Bool {
        guard !exporting.contains(item.id) else { return false }
        do {
            try await store.delete(item)
            items.removeAll { $0.id == item.id }
            return true
        } catch { present(error, operation: "Delete capture"); return false }
    }

    func thumbnail(_ item: LibraryItem) async -> UIImage? {
        let key = "\(item.id)-\(item.revision)" as NSString
        if let cached = thumbnails.object(forKey: key) { return cached }
        return await Diagnostics.time("library.thumbnailGenerate") { await thumbnailUncached(item, key: key) }
    }
    private func thumbnailUncached(_ item: LibraryItem, key: NSString) async -> UIImage? {
        do {
            let data: Data
            if let cached = try await Diagnostics.time("thumbnail.diskCacheCheck", { try await store.thumbnail(item) }) {
                data = cached
            }
            else if item.kind == .photo {
                data = try await Diagnostics.time("thumbnail.render") { try await renderer.thumbnailJPEG(data: store.source(for: item), edit: item.recipe) }
                try await Diagnostics.time("thumbnail.writeCache") { try await store.saveThumbnail(data, for: item) }
            } else {
                let asset = AVURLAsset(url: await store.sourceURL(item))
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 480, height: 480)
                let result = try await generator.image(at: .zero)
                guard let encoded = UIImage(cgImage: result.image).jpegData(compressionQuality: 0.8) else { return nil }
                data = encoded
                try await store.saveThumbnail(data, for: item)
            }
            guard !Task.isCancelled, let image = UIImage(data: data) else { return nil }
            thumbnails.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * 4))
            return image
        } catch {
            Diagnostics.report(error, operation: "Load thumbnail")
            return nil
        }
    }

    private func replace(_ item: LibraryItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = item }
    }
    private func present(_ error: any Error, operation: String) {
        Diagnostics.report(error, operation: operation)
        issue = error as? AppIssue ?? AppIssue(operation + " failed", "Your originals remain in Fexer. Please try again.")
    }
}
