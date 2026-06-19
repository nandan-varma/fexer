import AVFoundation

enum VideoResolution: String, CaseIterable, Identifiable {
    case hd1080p = "1080p"
    case uhd4K   = "4K"

    var id: String { rawValue }

    var sessionPreset: AVCaptureSession.Preset {
        self == .uhd4K ? .hd4K3840x2160 : .hd1920x1080
    }
}

enum VideoCodec: String, CaseIterable, Identifiable {
    case hevc   = "HEVC"
    case h264   = "H.264"
    case proRes = "ProRes"

    var id: String { rawValue }

    var avCodecType: AVVideoCodecType {
        switch self {
        case .h264:   return .h264
        case .hevc:   return .hevc
        case .proRes: return .proRes4444
        }
    }
}

struct VideoSettings {
    var resolution: VideoResolution = .hd1080p
    var frameRate: Int = 30
    var codec: VideoCodec = .hevc
}
