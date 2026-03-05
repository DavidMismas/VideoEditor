import Foundation
import AVFoundation
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable, Identifiable {
    case mp4
    case hevc
    case mov
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .mp4: return "MP4 (H.264)"
        case .hevc: return "HEVC (H.265)"
        case .mov: return "MOV (ProRes)"
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
    
    var preferredPreset: String {
        switch self {
        case .mp4:
            return AVAssetExportPresetHighestQuality
        case .hevc:
            return AVAssetExportPresetHEVCHighestQuality
        case .mov:
            return AVAssetExportPresetAppleProRes422LPCM
        }
    }
    
    var fallbackPresets: [String] {
        switch self {
        case .mp4:
            return [AVAssetExportPreset1920x1080, AVAssetExportPresetHighestQuality]
        case .hevc:
            return [AVAssetExportPresetHighestQuality]
        case .mov:
            return [AVAssetExportPresetHighestQuality]
        }
    }
    
    // Preconfigured target used by format selection (for future AVAssetWriter tuning).
    var targetBitrate: Int {
        switch self {
        case .mp4: return 12_000_000
        case .hevc: return 8_000_000
        case .mov: return 40_000_000
        }
    }
}

enum TimelineExportError: LocalizedError {
    case noVideoClips
    case clipMissingURL(String)
    case unableToCreateCompositionTrack
    case unsupportedPreset
    case unableToCreateExportSession
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
        case .unsupportedPreset:
            return "Selected export format is not supported for this timeline."
        case .unableToCreateExportSession:
            return "Unable to initialize export session."
        case .exportCancelled:
            return "Export was cancelled."
        case .exportFailed(let reason):
            return "Export failed: \(reason)"
        }
    }
}
