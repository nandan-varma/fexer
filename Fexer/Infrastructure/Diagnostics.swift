import Foundation
import OSLog

/// Operational messages contain no image bytes, coordinates, asset IDs, or user filenames.
enum Diagnostics {
    static let camera = Logger(subsystem: "com.nandanvarma.fexer", category: "camera")
    static let imaging = Logger(subsystem: "com.nandanvarma.fexer", category: "imaging")
    static let storage = Logger(subsystem: "com.nandanvarma.fexer", category: "storage")
    static let lifecycle = Logger(subsystem: "com.nandanvarma.fexer", category: "lifecycle")

    static func report(_ error: any Error, operation: String) {
        storage.error("\(operation, privacy: .public) failed: \(String(describing: error), privacy: .private)")
    }

    static var buildDescription: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–"
        #if DEBUG
        return "\(version) (\(build)) · Debug"
        #else
        return "\(version) (\(build)) · Release"
        #endif
    }
}

struct AppIssue: Error, LocalizedError, Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let message: String

    init(_ title: String, _ message: String) {
        id = UUID()
        self.title = title
        self.message = message
    }

    var errorDescription: String? { message }

    static let cameraUnavailable = AppIssue("Camera unavailable", "The camera couldn’t start. Close other camera apps and try again.")
    static let cameraDenied = AppIssue("Allow camera access", "Open Settings and allow Camera to take photos with Fexer.")
    static let captureFailed = AppIssue("Photo not captured", "The camera couldn’t finish this photo. Please try again.")
    static let decodingFailed = AppIssue("Can’t open this image", "The image is damaged or uses an unsupported format.")
    static let exportFailed = AppIssue("Couldn’t render the photo", "Your original is safe. Try exporting again.")
    static let photosDenied = AppIssue("Photo saved in Fexer", "Allow Photos access in Settings, then save again from your library.")
    static let busy = AppIssue("Camera is busy", "Wait for the current capture to finish.")
}

extension Double {
    func bounded(_ range: ClosedRange<Double>, fallback: Double = 0) -> Double {
        min(max(isFinite ? self : fallback, range.lowerBound), range.upperBound)
    }
}
