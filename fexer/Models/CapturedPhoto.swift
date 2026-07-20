import CoreLocation
import Foundation

struct CapturedPhoto: Identifiable {
    let id: UUID
    let jpegData: Data?
    let rawFileURL: URL?
    let captureSettings: CaptureSettings
    let appliedStyle: PhotoStyle?
    let styleIntensity: Float
    let captureDate: Date
    let location: CLLocation?
    let exifMetadata: [String: Any]
    var editState: EditState?
    var assetLocalIdentifier: String?

    init(
        jpegData: Data? = nil,
        rawFileURL: URL? = nil,
        captureSettings: CaptureSettings = CaptureSettings(),
        appliedStyle: PhotoStyle? = nil,
        styleIntensity: Float = 1.0,
        captureDate: Date = Date(),
        location: CLLocation? = nil,
        exifMetadata: [String: Any] = [:],
        editState: EditState? = nil,
        assetLocalIdentifier: String? = nil
    ) {
        self.id = UUID()
        self.jpegData = jpegData
        self.rawFileURL = rawFileURL
        self.captureSettings = captureSettings
        self.appliedStyle = appliedStyle
        self.styleIntensity = styleIntensity
        self.captureDate = captureDate
        self.location = location
        self.exifMetadata = exifMetadata
        self.editState = editState
        self.assetLocalIdentifier = assetLocalIdentifier
    }
}

extension CapturedPhoto: Hashable {
    static func == (lhs: CapturedPhoto, rhs: CapturedPhoto) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
