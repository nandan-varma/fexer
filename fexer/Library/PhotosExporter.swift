import CoreLocation
import Foundation
import Photos
import Synchronization
import UniformTypeIdentifiers

protocol PhotoExporting: Sendable {
    func savePhoto(data: Data, rawURL: URL?, liveURL: URL?, date: Date, location: GeoTag?) async throws -> String
}

struct PhotosExporter: PhotoExporting {
    func savePhoto(data: Data, rawURL: URL?, liveURL: URL?, date: Date, location: GeoTag?) async throws -> String {
        try await authorize()
        let identifier = Mutex<String?>(nil)
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.creationDate = date
            if let location { request.location = Self.location(location) }
            let options = PHAssetResourceCreationOptions()
            options.uniformTypeIdentifier = CaptureStore.imageExtension(data) == "heic" ? UTType.heic.identifier : UTType.jpeg.identifier
            request.addResource(with: .photo, data: data, options: options)
            if let rawURL { request.addResource(with: .alternatePhoto, fileURL: rawURL, options: nil) }
            if let liveURL { request.addResource(with: .pairedVideo, fileURL: liveURL, options: nil) }
            identifier.withLock { $0 = request.placeholderForCreatedAsset?.localIdentifier }
        }
        guard let id = identifier.withLock({ $0 }) else { throw AppIssue.exportFailed }
        return id
    }

    func saveVideo(url: URL, date: Date, location: GeoTag?) async throws -> String {
        try await authorize()
        let identifier = Mutex<String?>(nil)
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.creationDate = date
            if let location { request.location = Self.location(location) }
            request.addResource(with: .video, fileURL: url, options: nil)
            identifier.withLock { $0 = request.placeholderForCreatedAsset?.localIdentifier }
        }
        guard let id = identifier.withLock({ $0 }) else { throw AppIssue.exportFailed }
        return id
    }

    private func authorize() async throws {
        var status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .addOnly) }
        guard status == .authorized || status == .limited else { throw AppIssue.photosDenied }
    }

    private static func location(_ tag: GeoTag) -> CLLocation {
        CLLocation(coordinate: .init(latitude: tag.latitude, longitude: tag.longitude), altitude: tag.altitude ?? 0,
                   horizontalAccuracy: 10, verticalAccuracy: tag.altitude == nil ? -1 : 10, timestamp: Date())
    }
}
