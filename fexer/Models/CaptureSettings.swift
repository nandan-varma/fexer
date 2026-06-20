import AVFoundation
import CoreMedia

enum CaptureFormat: String, CaseIterable {
    case heif = "HEIF"
    case jpeg = "JPEG"
    case raw = "RAW"
    case rawPlusJpeg = "RAW+JPEG"
}

enum StabilizationMode: String, CaseIterable, Identifiable {
    case off         = "Off"
    case standard    = "Standard"
    case cinematic   = "Cinematic"
    case auto        = "Auto"

    var id: String { rawValue }

    var avMode: AVCaptureVideoStabilizationMode {
        switch self {
        case .off:        return .off
        case .standard:   return .standard
        case .cinematic:  return .cinematic
        case .auto:       return .auto
        }
    }
}

enum VideoColorSpace: String, CaseIterable, Identifiable {
    case sRGB      = "sRGB"
    case p3        = "P3"
    case hlg       = "HLG"
    case appleLog  = "Log"

    var id: String { rawValue }
}

struct CaptureSettings {
    var isoValue: Float = 200
    var shutterSpeed: CMTime = CMTime(value: 1, timescale: 250)
    var whiteBalance: Float = 5500
    var whiteBalanceTint: Float = 0        // -150 (green) … +150 (magenta)
    var focusDistance: Float = 0.5
    var exposureCompensation: Float = 0
    var exposureTargetOffset: Float = 0    // live EV offset from meter neutral (KVO)
    var meteringMode: MeteringMode = .matrix
    var isAELocked: Bool = false
    var lensAperture: Float = 1.8          // read-only: updated from device.lensAperture
    var isTrapFocusEnabled: Bool = false

    var isAutoISO: Bool = true
    var isAutoShutter: Bool = true
    var isAutoWhiteBalance: Bool = true
    var isAutoFocus: Bool = true

    var captureFormat: CaptureFormat = .heif
    var isProRAW: Bool = false
    var videoSettings = VideoSettings()

    // Torch
    var isTorchOn: Bool = false
    var torchLevel: Float = 1.0            // 0.01 … 1.0

    // Video-only
    var stabilizationMode: StabilizationMode = .auto
    var videoColorSpace: VideoColorSpace = .sRGB
    var isHDREnabled: Bool = false
    var isOpticalZoomLocked: Bool = false  // clamp zoom to nearest optical factor

    /// AF-C (.continuousAutoFocus) tracks continuously; AF-S (.autoFocus) focuses once then locks.
    var focusMode: AVCaptureDevice.FocusMode = .continuousAutoFocus

    var shutterSpeedDisplayString: String {
        CaptureSettings.formatShutterSpeed(CMTimeGetSeconds(shutterSpeed))
    }

    static func formatShutterSpeed(_ seconds: Double) -> String {
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
        CMTime(value: 1, timescale: 8000),
        CMTime(value: 1, timescale: 4000),
        CMTime(value: 1, timescale: 2000),
        CMTime(value: 1, timescale: 1000),
        CMTime(value: 1, timescale: 500),
        CMTime(value: 1, timescale: 250),
        CMTime(value: 1, timescale: 125),
        CMTime(value: 1, timescale: 60),
        CMTime(value: 1, timescale: 30),
        CMTime(value: 1, timescale: 15),
        CMTime(value: 1, timescale: 8),
        CMTime(value: 1, timescale: 4),
        CMTime(value: 1, timescale: 2),
        CMTime(value: 1, timescale: 1),
        CMTime(value: 2, timescale: 1),
        CMTime(value: 4, timescale: 1),
        CMTime(value: 8, timescale: 1),
        CMTime(value: 15, timescale: 1),
        CMTime(value: 30, timescale: 1)
    ]
}
