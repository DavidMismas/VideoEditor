import Foundation
import AVFoundation
import UniformTypeIdentifiers
import CoreGraphics

enum ExportFormat: String, CaseIterable, Identifiable {
    case mp4
    case hevc
    case mov
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .mp4: return "MP4 (H.264)"
        case .hevc: return "HEVC (H.265)"
        case .mov: return "MOV (H.264)"
        }
    }
    
    var preferredExtension: String {
        switch self {
        case .mp4: return "mp4"
        case .hevc: return "mov"
        case .mov: return "mov"
        }
    }
    
    var contentType: UTType {
        switch self {
        case .mp4: return .mpeg4Movie
        case .hevc, .mov: return .quickTimeMovie
        }
    }
    
    var preferredFileType: AVFileType {
        switch self {
        case .mp4: return .mp4
        case .hevc, .mov: return .mov
        }
    }

    var videoCodec: AVVideoCodecType {
        switch self {
        case .mp4, .mov:
            return .h264
        case .hevc:
            return .hevc
        }
    }
}

enum ExportQuality: String, CaseIterable, Identifiable {
    case low
    case medium
    case high

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    func targetBitrate(for format: ExportFormat) -> Int {
        switch self {
        case .low:
            switch format {
            case .hevc: return 60_000_000
            case .mp4, .mov: return 80_000_000
            }
        case .medium:
            switch format {
            case .hevc: return 100_000_000
            case .mp4, .mov: return 120_000_000
            }
        case .high:
            switch format {
            case .hevc: return 140_000_000
            case .mp4, .mov: return 180_000_000
            }
        }
    }
}

enum ExportFrameRate: Int, CaseIterable, Identifiable {
    case fps30 = 30
    case fps60 = 60

    var id: Int { rawValue }

    var displayName: String {
        "\(rawValue) fps"
    }
}

enum ExportResolution: String, CaseIterable, Identifiable {
    case fullHD
    case uhd4k

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fullHD: return "1080p (1920x1080)"
        case .uhd4k: return "4K UHD (3840x2160)"
        }
    }

    var size: CGSize {
        switch self {
        case .fullHD:
            return CGSize(width: 1920, height: 1080)
        case .uhd4k:
            return CGSize(width: 3840, height: 2160)
        }
    }
}

enum TimelineExportError: LocalizedError {
    case noVideoClips
    case clipMissingURL(String)
    case unableToCreateCompositionTrack
    case unableToCreateReader
    case unableToCreateWriter
    case exportCancelled
    case exportFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .noVideoClips:
            return "Bottom timeline has no video clips to export."
        case .clipMissingURL(let clipName):
            return "Clip '\(clipName)' has no valid source URL."
        case .unableToCreateCompositionTrack:
            return "Unable to create composition tracks for export."
        case .unableToCreateReader:
            return "Unable to initialize asset reader for export."
        case .unableToCreateWriter:
            return "Unable to initialize asset writer for export."
        case .exportCancelled:
            return "Export was cancelled."
        case .exportFailed(let reason):
            return "Export failed: \(reason)"
        }
    }
}
