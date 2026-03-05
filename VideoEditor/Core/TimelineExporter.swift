import Foundation
import AVFoundation
import CoreMedia
import CoreImage

@MainActor
final class TimelineExporter {
    static let shared = TimelineExporter()
    
    private struct ClipSegment {
        let timeRange: CMTimeRange
        let adjustments: ColorAdjustments
    }
    
    private init() {}
    
    func export(
        videoTracks: [TimelineTrack],
        audioTracks: [TimelineTrack],
        config: ProjectConfig,
        format: ExportFormat,
        destinationURL: URL
    ) async throws {
        let build = try await buildComposition(
            videoTracks: videoTracks,
            audioTracks: audioTracks,
            config: config
        )
        
        let presetCandidates = [format.preferredPreset] + format.fallbackPresets
        guard let selectedPreset = await firstCompatiblePreset(
            from: presetCandidates,
            for: build.composition,
            fileType: format.preferredFileType
        ) else {
            throw TimelineExportError.unsupportedPreset
        }
        
        guard let exportSession = AVAssetExportSession(asset: build.composition, presetName: selectedPreset) else {
            throw TimelineExportError.unableToCreateExportSession
        }
        
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        
        let fileType = exportSession.supportedFileTypes.contains(format.preferredFileType)
            ? format.preferredFileType
            : (exportSession.supportedFileTypes.first ?? .mov)
        exportSession.videoComposition = build.videoComposition
        exportSession.shouldOptimizeForNetworkUse = (format == .mp4 || format == .hevc)
        
        do {
            try await exportSession.export(to: destinationURL, as: fileType)
        } catch is CancellationError {
            throw TimelineExportError.exportCancelled
        } catch {
            throw TimelineExportError.exportFailed(error.localizedDescription)
        }
    }
    
    private func firstCompatiblePreset(
        from candidates: [String],
        for asset: AVAsset,
        fileType: AVFileType
    ) async -> String? {
        for candidate in candidates {
            let isCompatible = await AVAssetExportSession.compatibility(
                ofExportPreset: candidate,
                with: asset,
                outputFileType: fileType
            )
            if isCompatible {
                return candidate
            }
        }
        return nil
    }
    
    private func buildComposition(
        videoTracks: [TimelineTrack],
        audioTracks: [TimelineTrack],
        config: ProjectConfig
    ) async throws -> (composition: AVMutableComposition, videoComposition: AVVideoComposition, totalDuration: CMTime) {
        guard let primaryVideoTrack = videoTracks.first(where: { !$0.isAudioOnly && !$0.clips.isEmpty }) else {
            throw TimelineExportError.noVideoClips
        }
        
        let composition = AVMutableComposition()
        composition.naturalSize = config.resolution
        
        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw TimelineExportError.unableToCreateCompositionTrack
        }
        
        let primaryAudioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )
        
        var clipSegments: [ClipSegment] = []
        var timelineCursor = CMTime.zero
        var preferredTransformSet = false
        
        for clip in primaryVideoTrack.clips {
            guard let sourceURL = clip.mediaItem.url else {
                throw TimelineExportError.clipMissingURL(clip.mediaItem.name)
            }
            
            let asset = AVURLAsset(url: sourceURL)
            guard let sourceVideoTrack = try await asset.loadTracks(withMediaType: .video).first else {
                continue
            }
            
            let sourceDuration = try await asset.load(.duration)
            guard sourceDuration.isNumeric else { continue }
            let sourceStart = clip.startTime.isNumeric ? clip.startTime : .zero
            let availableDurationRaw = CMTimeSubtract(sourceDuration, sourceStart)
            guard availableDurationRaw.isNumeric else { continue }
            let availableDuration = CMTimeMaximum(.zero, availableDurationRaw)
            guard availableDuration.isNumeric, availableDuration > .zero else { continue }
            
            let requestedDuration = (clip.duration.isNumeric && clip.duration > .zero) ? clip.duration : availableDuration
            let finalDuration = CMTimeMinimum(requestedDuration, availableDuration)
            guard finalDuration.isNumeric, finalDuration > .zero else { continue }
            let sourceRange = CMTimeRange(start: sourceStart, duration: finalDuration)
            
            try compositionVideoTrack.insertTimeRange(sourceRange, of: sourceVideoTrack, at: timelineCursor)
            
            if !preferredTransformSet {
                compositionVideoTrack.preferredTransform = try await sourceVideoTrack.load(.preferredTransform)
                preferredTransformSet = true
            }
            
            if !clip.isMuted,
               let sourceAudioTrack = try await asset.loadTracks(withMediaType: .audio).first,
               let primaryAudioTrack {
                try primaryAudioTrack.insertTimeRange(sourceRange, of: sourceAudioTrack, at: timelineCursor)
            }
            
            let segmentTimeRange = CMTimeRange(start: timelineCursor, duration: finalDuration)
            clipSegments.append(ClipSegment(timeRange: segmentTimeRange, adjustments: clip.adjustments))
            timelineCursor = CMTimeAdd(timelineCursor, finalDuration)
        }
        
        for lane in audioTracks where !lane.clips.isEmpty {
            guard let compositionAudioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                continue
            }
            
            var laneCursor = CMTime.zero
            for clip in lane.clips {
                guard let sourceURL = clip.mediaItem.url else { continue }
                let asset = AVURLAsset(url: sourceURL)
                guard let sourceAudioTrack = try await asset.loadTracks(withMediaType: .audio).first else { continue }
                
                let sourceDuration = try await asset.load(.duration)
                guard sourceDuration.isNumeric else { continue }
                let sourceStart = clip.startTime.isNumeric ? clip.startTime : .zero
                let availableDurationRaw = CMTimeSubtract(sourceDuration, sourceStart)
                guard availableDurationRaw.isNumeric else { continue }
                let availableDuration = CMTimeMaximum(.zero, availableDurationRaw)
                guard availableDuration.isNumeric, availableDuration > .zero else { continue }
                
                let requestedDuration = (clip.duration.isNumeric && clip.duration > .zero) ? clip.duration : availableDuration
                let finalDuration = CMTimeMinimum(requestedDuration, availableDuration)
                guard finalDuration.isNumeric, finalDuration > .zero else { continue }
                let sourceRange = CMTimeRange(start: sourceStart, duration: finalDuration)
                
                try compositionAudioTrack.insertTimeRange(sourceRange, of: sourceAudioTrack, at: laneCursor)
                laneCursor = CMTimeAdd(laneCursor, finalDuration)
            }
        }
        
        if !timelineCursor.isNumeric || timelineCursor <= .zero {
            throw TimelineExportError.noVideoClips
        }
        
        let exportProcessor = CoreImageProcessor.shared
        let clipMap = clipSegments
        let defaultAdjustments = ColorAdjustments()
        
        let videoComposition = try await AVVideoComposition(applyingFiltersTo: composition, applier: { params in
            let compositionTime = params.compositionTime
            let clipAdjustments = clipMap.first(where: { segment in
                guard segment.timeRange.start.isNumeric,
                      segment.timeRange.duration.isNumeric,
                      segment.timeRange.duration > .zero,
                      compositionTime.isNumeric
                else {
                    return false
                }
                let start = segment.timeRange.start
                let end = CMTimeAdd(start, segment.timeRange.duration)
                return CMTimeCompare(compositionTime, start) >= 0 && CMTimeCompare(compositionTime, end) < 0
            })?.adjustments ?? defaultAdjustments
            let filtered = exportProcessor.applyAdjustments(clipAdjustments, to: params.sourceImage)
            return AVCIImageFilteringResult(resultImage: filtered)
        })

        return (composition, videoComposition, timelineCursor)
    }
}
