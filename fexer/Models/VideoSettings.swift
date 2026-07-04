import AVFoundation

enum VideoResolution: String, CaseIterable, Identifiable {
    case hd1080p   = "1080p"
    case uhd4K     = "4K"
    case slowMo    = "Slo-Mo"

    var id: String { rawValue }

    var sessionPreset: AVCaptureSession.Preset {
        switch self {
        case .uhd4K:   return .hd4K3840x2160
        case .slowMo:  return .hd1920x1080   // high-fps at 1080p
        case .hd1080p: return .hd1920x1080
        }
    }

    /// When true, the session is configured for high-FPS capture and output
    /// is played back at a lower rate to produce slow motion.
    var isSlowMotion: Bool { self == .slowMo }
}

enum VideoCodec: String, CaseIterable, Identifiable {
    case hevc   = "HEVC"
    case h264   = "H.264"
    case proRes = "ProRes"

    var id: String { rawValue }
}

struct VideoSettings {
    var resolution: VideoResolution = .hd1080p
    var frameRate: Int = 30
    var codec: VideoCodec = .hevc

    var audioSampleRate: Double { 48_000 }
    var audioBitRate: Int { 256_000 }  // 256 kbps stereo AAC — broadcast standard at 48 kHz

    var videoBitRate: Int {
        switch (resolution, frameRate) {
        case (.uhd4K, let fps) where fps > 30: return 100_000_000  // 4K 60fps HEVC
        case (.uhd4K, _):                      return  60_000_000  // 4K 30fps HEVC
        case (.slowMo, _):                     return  40_000_000  // 1080p high-fps
        case (.hd1080p, let fps) where fps > 30: return 30_000_000 // 1080p 60fps
        default:                               return  25_000_000  // 1080p 30fps HEVC
        }
    }
}
