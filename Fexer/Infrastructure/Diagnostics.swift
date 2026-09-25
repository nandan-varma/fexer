import Foundation
import OSLog

/// Operational messages contain no image bytes, coordinates, asset IDs, or user filenames.
enum Diagnostics {
    static let camera = Logger(subsystem: "com.nandanvarma.fexer", category: "camera")
    static let imaging = Logger(subsystem: "com.nandanvarma.fexer", category: "imaging")
    static let storage = Logger(subsystem: "com.nandanvarma.fexer", category: "storage")
    static let lifecycle = Logger(subsystem: "com.nandanvarma.fexer", category: "lifecycle")
    /// One category for every timing log so a device console/sysdiagnose can filter to just this
    /// and read the whole capture pipeline's timing breakdown as a flat list of "⏱ stage Nms" lines.
    static let perf = Logger(subsystem: "com.nandanvarma.fexer", category: "perf")

    static func report(_ error: any Error, operation: String) {
        storage.error("\(operation, privacy: .public) failed: \(String(describing: error), privacy: .private)")
    }

    static func ms(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) * 1000 + Double(attoseconds) / 1_000_000_000_000_000
    }

    /// Logs `label`'s wall-clock duration at `.notice` (visible in Console.app/sysdiagnose without
    /// special configuration). Wrap every stage of a pipeline you want visibility into with this.
    @discardableResult
    static func time<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
        let start = ContinuousClock.now
        defer { perf.notice("⏱ \(label, privacy: .public) \(ms(start.duration(to: .now)), format: .fixed(precision: 1), privacy: .public)ms") }
        return try body()
    }
    // `isolated: (any Actor)? = #isolation` keeps this generic wrapper running on the caller's
    // actor instead of treating `body` as crossing into a non-isolated context — without it, the
    // compiler flags every call site (MainActor view models, ImageRenderer/CaptureStore actors)
    // as an unsafe Sendable closure transfer, since `time` itself is isolation-agnostic.
    @discardableResult
    static func time<T>(_ label: String, isolation: isolated (any Actor)? = #isolation, _ body: () async throws -> T) async rethrows -> T {
        let start = ContinuousClock.now
        defer { perf.notice("⏱ \(label, privacy: .public) \(ms(start.duration(to: .now)), format: .fixed(precision: 1), privacy: .public)ms") }
        return try await body()
    }
    /// For marking a single instant (e.g. an AVCapturePhotoCaptureDelegate callback) relative to
    /// a stored start time, rather than a start/end span.
    static func mark(_ label: String, since start: ContinuousClock.Instant) {
        perf.notice("⏱ \(label, privacy: .public) +\(ms(start.duration(to: .now)), format: .fixed(precision: 1), privacy: .public)ms")
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
