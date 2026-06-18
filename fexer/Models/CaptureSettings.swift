import AVFoundation
import CoreMedia

enum CaptureFormat: String, CaseIterable {
    case jpeg = "JPEG"
    case raw = "RAW"
    case rawPlusJpeg = "RAW+JPEG"
}

struct CaptureSettings {
    var isoValue: Float = 200
    var shutterSpeed: CMTime = CMTimeMake(value: 1, timescale: 250)
    var whiteBalance: Float = 5500
    var focusDistance: Float = 0.5
    var exposureCompensation: Float = 0

    var isAutoISO: Bool = true
    var isAutoShutter: Bool = true
    var isAutoWhiteBalance: Bool = true
    var isAutoFocus: Bool = true

    var captureFormat: CaptureFormat = .jpeg
    var isProRAW: Bool = false

    var shutterSpeedDisplayString: String {
        let seconds = CMTimeGetSeconds(shutterSpeed)
        if seconds >= 1 {
            return seconds.truncatingRemainder(dividingBy: 1) == 0
                ? "\(Int(seconds))\""
                : String(format: "%.1f\"", seconds)
        } else {
            let denom = Int(round(1.0 / seconds))
            return "1/\(denom)"
        }
    }

    static let isoStops: [Float] = [25, 50, 100, 200, 400, 800, 1600, 3200, 6400]
    static let shutterStops: [CMTime] = [
        CMTimeMake(value: 1, timescale: 8000),
        CMTimeMake(value: 1, timescale: 4000),
        CMTimeMake(value: 1, timescale: 2000),
        CMTimeMake(value: 1, timescale: 1000),
        CMTimeMake(value: 1, timescale: 500),
        CMTimeMake(value: 1, timescale: 250),
        CMTimeMake(value: 1, timescale: 125),
        CMTimeMake(value: 1, timescale: 60),
        CMTimeMake(value: 1, timescale: 30),
        CMTimeMake(value: 1, timescale: 15),
        CMTimeMake(value: 1, timescale: 8),
        CMTimeMake(value: 1, timescale: 4),
        CMTimeMake(value: 1, timescale: 2),
        CMTimeMake(value: 1, timescale: 1),
        CMTimeMake(value: 2, timescale: 1),
        CMTimeMake(value: 4, timescale: 1),
        CMTimeMake(value: 8, timescale: 1),
        CMTimeMake(value: 15, timescale: 1),
        CMTimeMake(value: 30, timescale: 1)
    ]
}
