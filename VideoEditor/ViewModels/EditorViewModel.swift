import Foundation
import SwiftUI
import CoreMedia
import AVFoundation
import Observation

@Observable
class EditorViewModel {
    // Project Settings
    var config = ProjectConfig()
    
    // Playback Engine
    var engine = VideoPlaybackEngine()
    
    // Library
    var mediaLibrary: [MediaItem] = []
    var importedLUTs: [LUTItem] = []
    
    // Timeline
    var videoTracks: [TimelineTrack] = [TimelineTrack(name: "V1", clips: [])]
    var audioTracks: [TimelineTrack] = [TimelineTrack(name: "A1", clips: [], isAudioOnly: true)]
    
    // Selection state
    var selectedClipId: UUID?
    var selectedMediaLibraryItemId: UUID?
    
    // Middle clip-editor segments (trim/split source for drag into bottom timeline)
    var clipEditorSegments: [TimelineClip] = []
    var clipEditorReferenceDurationSeconds: Double = 0
    var clipEditorSplitModeEnabled: Bool = false
    
    var isolatedClip: TimelineClip? {
        didSet {
            guard let isolated = isolatedClip else {
                if oldValue != nil {
                    engine.currentAdjustments = ColorAdjustments()
                    engine.currentLUTURL = nil
                    clipEditorSegments = []
                    clipEditorReferenceDurationSeconds = 0
                    clipEditorSplitModeEnabled = false
                }
                return
            }
            
            // Only reload media when the isolated clip itself changes.
            // Slider-driven adjustment changes mutate the same clip instance and should not reset playback.
            let clipChanged = oldValue?.id != isolated.id || oldValue?.mediaItem.url != isolated.mediaItem.url
            if clipChanged, let url = isolated.mediaItem.url {
                engine.loadMedia(from: url)
                clipEditorSegments = [isolated]
                clipEditorReferenceDurationSeconds = max(
                    sourceDurationSeconds(for: isolated),
                    max(isolated.duration.seconds, minimumEditorSegmentDurationSeconds)
                )
            } else if clipEditorSegments.isEmpty {
                clipEditorSegments = [isolated]
                clipEditorReferenceDurationSeconds = max(
                    sourceDurationSeconds(for: isolated),
                    max(isolated.duration.seconds, minimumEditorSegmentDurationSeconds)
                )
            } else if oldValue?.appliedLUTID != isolated.appliedLUTID {
                for index in clipEditorSegments.indices {
                    clipEditorSegments[index].appliedLUTID = isolated.appliedLUTID
                }
            }
            
            engine.currentAdjustments = isolated.adjustments
            engine.currentLUTURL = lutURL(for: isolated.appliedLUTID)
        }
    }
    
    // Active adjustments view
    var activeAdjustments: ColorAdjustments {
        get {
            guard let id = selectedClipId,
                  let clip = findClip(id: id) else {
                if let isolated = isolatedClip {
                    return isolated.adjustments
                }
                return ColorAdjustments()
            }
            return clip.adjustments
        }
        set {
            if let selectedId = selectedClipId {
                updateAdjustments(for: selectedId, newValue)
                if isolatedClip?.id == selectedId {
                    isolatedClip?.adjustments = newValue
                }
            } else if let isolatedId = isolatedClip?.id {
                isolatedClip?.adjustments = newValue
                // Keep export state aligned when the isolated clip has already been dropped to timeline.
                updateAdjustments(for: isolatedId, newValue)
                for index in clipEditorSegments.indices {
                    clipEditorSegments[index].adjustments = newValue
                }
            } else {
                updateAdjustments(for: selectedClipId, newValue)
            }
            engine.currentAdjustments = newValue
        }
    }
    
    // Current Playhead Position
    var currentTime: CMTime = .zero
    var isPlaying: Bool = false
    
    // Export
    var exportFormat: ExportFormat = .mp4
    var exportQuality: ExportQuality = .medium
    var exportFrameRate: ExportFrameRate = .fps30
    var exportResolution: ExportResolution = .fullHD
    
    private let fallbackClipDurationSeconds: Double = 5.0
    private let minimumEditorSegmentDurationSeconds: Double = 0.10
    
    // MARK: - Intents
    
    func importMedia(url: URL, type: MediaItem.MediaType) {
        let name = url.lastPathComponent
        let item = MediaItem(name: name, url: url, type: type)
        mediaLibrary.append(item)
        
        let itemID = item.id
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            guard let seconds = await Self.loadMediaDurationSeconds(for: url, type: type) else { return }
            
            await MainActor.run {
                guard let idx = self.mediaLibrary.firstIndex(where: { $0.id == itemID }) else { return }
                self.mediaLibrary[idx].durationSeconds = seconds
                self.refreshClipDurations(for: itemID, loadedDurationSeconds: seconds)
            }
        }
    }
    
    @discardableResult
    func importLUT(url: URL) -> Bool {
        let normalizedURL = url.standardizedFileURL
        
        if importedLUTs.contains(where: { $0.url.standardizedFileURL == normalizedURL }) {
            return true
        }
        
        guard ImportedLUTManager.shared.hasValidCube(at: normalizedURL) else {
            return false
        }
        
        let item = LUTItem(
            name: normalizedURL.deletingPathExtension().lastPathComponent,
            url: normalizedURL
        )
        importedLUTs.append(item)
        return true
    }
    
    func addExistingClip(clip: TimelineClip, toTrack trackId: UUID) {
        // Clone clip so repeated drags create independent timeline entries.
        let duplicatedClip = TimelineClip(
            mediaItem: clip.mediaItem,
            startTime: clip.startTime,
            duration: clip.duration,
            appliedLUTID: clip.appliedLUTID,
            adjustments: clip.adjustments,
            transforms: clip.transforms,
            volume: clip.volume,
            isMuted: clip.isMuted
        )
        // Search in video tracks
        if let idx = videoTracks.firstIndex(where: { $0.id == trackId }) {
            videoTracks[idx].clips.append(duplicatedClip)
            return
        }
        // Search in audio tracks
        if let idx = audioTracks.firstIndex(where: { $0.id == trackId }) {
            audioTracks[idx].clips.append(duplicatedClip)
            return
        }
    }
    
    func addClip(item: MediaItem, toTrack trackId: UUID) async {
        var newClip = makeTimelineClip(from: item)
        
        if shouldReplaceClipDuration(newClip.duration),
           let url = item.url,
           let loadedSeconds = await Self.loadMediaDurationSeconds(for: url, type: item.type) {
            newClip.duration = CMTime(seconds: loadedSeconds, preferredTimescale: 600)
            if let idx = mediaLibrary.firstIndex(where: { $0.id == item.id }) {
                mediaLibrary[idx].durationSeconds = loadedSeconds
            }
        }
        
        // Search in video tracks
        if let idx = videoTracks.firstIndex(where: { $0.id == trackId }) {
            videoTracks[idx].clips.append(newClip)
            return
        }
        // Search in audio tracks
        if let idx = audioTracks.firstIndex(where: { $0.id == trackId }) {
            audioTracks[idx].clips.append(newClip)
            return
        }
    }
    
    func makeTimelineClip(from item: MediaItem) -> TimelineClip {
        TimelineClip(
            mediaItem: item,
            startTime: .zero,
            duration: resolvedClipDuration(for: item)
        )
    }
    
    func selectClip(id: UUID?) {
        selectedClipId = id
        guard let id = id, let clip = findClip(id: id), let url = clip.mediaItem.url else {
            if id == nil {
                engine.currentAdjustments = ColorAdjustments()
                engine.currentLUTURL = nil
            }
            return
        }
        
        engine.loadMedia(from: url)
        engine.currentAdjustments = clip.adjustments
        engine.currentLUTURL = lutURL(for: clip.appliedLUTID)
    }
    
    func updateAdjustments(for id: UUID?, _ newAdjustments: ColorAdjustments) {
        guard let id = id else { return }
        
        // Search in video tracks
        for (trackIndex, track) in videoTracks.enumerated() {
            if let clipIndex = track.clips.firstIndex(where: { $0.id == id }) {
                videoTracks[trackIndex].clips[clipIndex].adjustments = newAdjustments
                return
            }
        }
    }
    
    // Helper
    private func findClip(id: UUID) -> TimelineClip? {
        for track in videoTracks {
            if let clip = track.clips.first(where: { $0.id == id }) {
                return clip
            }
        }
        return nil
    }
    
    @discardableResult
    func applyLUT(_ lutID: UUID, toClip clipID: UUID) -> Bool {
        guard let lut = importedLUTs.first(where: { $0.id == lutID }) else {
            return false
        }
        
        for trackIndex in videoTracks.indices {
            if let clipIndex = videoTracks[trackIndex].clips.firstIndex(where: { $0.id == clipID }) {
                videoTracks[trackIndex].clips[clipIndex].appliedLUTID = lutID
                
                if selectedClipId == clipID {
                    engine.currentLUTURL = lut.url
                }
                if isolatedClip?.id == clipID {
                    isolatedClip?.appliedLUTID = lutID
                    for index in clipEditorSegments.indices {
                        clipEditorSegments[index].appliedLUTID = lutID
                    }
                    engine.currentLUTURL = lut.url
                }
                return true
            }
        }
        
        if isolatedClip?.id == clipID {
            isolatedClip?.appliedLUTID = lutID
            for index in clipEditorSegments.indices {
                clipEditorSegments[index].appliedLUTID = lutID
            }
            engine.currentLUTURL = lut.url
            return true
        }
        
        return false
    }
    
    func lutName(for id: UUID?) -> String? {
        guard let id else { return nil }
        return importedLUTs.first(where: { $0.id == id })?.name
    }
    
    func lutURL(for id: UUID?) -> URL? {
        guard let id else { return nil }
        return importedLUTs.first(where: { $0.id == id })?.url
    }
    
    func draggableClip(for id: UUID) -> TimelineClip? {
        if let editorSegment = clipEditorSegments.first(where: { $0.id == id }) {
            return editorSegment
        }
        if let isolated = isolatedClip, isolated.id == id {
            return isolated
        }
        return findClip(id: id)
    }
    
    func clipEditorTotalDurationSeconds() -> Double {
        if clipEditorReferenceDurationSeconds.isFinite, clipEditorReferenceDurationSeconds > 0 {
            return clipEditorReferenceDurationSeconds
        }
        let fallback = clipEditorSegments
            .map { max(0.0, $0.startTime.seconds) + clipEditorSegmentDurationSeconds($0) }
            .max() ?? 0
        return max(fallback, minimumEditorSegmentDurationSeconds)
    }
    
    func clipEditorSegmentDurationSeconds(_ segment: TimelineClip) -> Double {
        let duration = segment.duration.seconds
        if duration.isFinite, duration > 0 {
            return duration
        }
        return minimumEditorSegmentDurationSeconds
    }
    
    func trimEditorSegmentLeading(
        id: UUID,
        anchorStartSeconds: Double,
        anchorDurationSeconds: Double,
        translationSeconds: Double
    ) {
        guard let index = clipEditorSegments.firstIndex(where: { $0.id == id }) else { return }
        guard index < clipEditorSegments.count else { return }
        let sourceDuration = max(
            clipEditorReferenceDurationSeconds,
            sourceDurationSeconds(for: clipEditorSegments[index])
        )
        let minDuration = minimumEditorSegmentDurationSeconds
        let previousEnd: Double = {
            guard index > 0 else { return 0.0 }
            let previous = clipEditorSegments[index - 1]
            return max(0.0, previous.startTime.seconds) + clipEditorSegmentDurationSeconds(previous)
        }()
        let requestedStart = anchorStartSeconds + translationSeconds
        let maxStart = min(
            sourceDuration - minDuration,
            anchorStartSeconds + max(anchorDurationSeconds - minDuration, 0)
        )
        let lowerBound = max(0.0, previousEnd)
        let upperBound = max(lowerBound, max(0.0, maxStart))
        let clampedStart = clamp(requestedStart, min: lowerBound, max: upperBound)
        let newDuration = max(minDuration, anchorDurationSeconds - (clampedStart - anchorStartSeconds))
        clipEditorSegments[index].startTime = CMTime(seconds: clampedStart, preferredTimescale: 600)
        clipEditorSegments[index].duration = CMTime(seconds: newDuration, preferredTimescale: 600)
    }
    
    func trimEditorSegmentTrailing(
        id: UUID,
        anchorStartSeconds: Double,
        anchorDurationSeconds: Double,
        translationSeconds: Double
    ) {
        guard let index = clipEditorSegments.firstIndex(where: { $0.id == id }) else { return }
        guard index < clipEditorSegments.count else { return }
        let sourceDuration = max(
            clipEditorReferenceDurationSeconds,
            sourceDurationSeconds(for: clipEditorSegments[index])
        )
        let minDuration = minimumEditorSegmentDurationSeconds
        let nextStart: Double = {
            guard index + 1 < clipEditorSegments.count else { return sourceDuration }
            let next = clipEditorSegments[index + 1]
            return max(0.0, next.startTime.seconds)
        }()
        let anchorEnd = anchorStartSeconds + anchorDurationSeconds
        let requestedEnd = anchorEnd + translationSeconds
        let minEnd = anchorStartSeconds + minDuration
        let maxEnd = max(minEnd, min(sourceDuration, nextStart))
        let clampedEnd = clamp(requestedEnd, min: minEnd, max: maxEnd)
        let newDuration = max(minDuration, clampedEnd - anchorStartSeconds)
        clipEditorSegments[index].duration = CMTime(seconds: newDuration, preferredTimescale: 600)
    }
    
    @discardableResult
    func splitEditorSegment(atTimelineSeconds timelineSeconds: Double) -> Bool {
        guard !clipEditorSegments.isEmpty else { return false }
        let safeTimeline = clamp(
            timelineSeconds,
            min: 0.0,
            max: max(clipEditorTotalDurationSeconds(), minimumEditorSegmentDurationSeconds)
        )
        
        for index in clipEditorSegments.indices {
            let segment = clipEditorSegments[index]
            let segmentStart = max(segment.startTime.seconds, 0.0)
            let duration = clipEditorSegmentDurationSeconds(segment)
            let end = segmentStart + duration
            if safeTimeline <= segmentStart || safeTimeline >= end {
                continue
            }
            
            let localSplit = safeTimeline - segmentStart
            let minDuration = minimumEditorSegmentDurationSeconds
            guard localSplit > minDuration, (duration - localSplit) > minDuration else {
                return false
            }
            
            let first = makeSegment(
                from: segment,
                startSeconds: segmentStart,
                durationSeconds: localSplit
            )
            let second = makeSegment(
                from: segment,
                startSeconds: safeTimeline,
                durationSeconds: duration - localSplit
            )
            clipEditorSegments.replaceSubrange(index...index, with: [first, second])
            return true
        }
        
        return false
    }
    
    func exportBottomTimeline(
        to outputURL: URL,
        format: ExportFormat,
        quality: ExportQuality,
        frameRate: ExportFrameRate,
        resolution: ExportResolution,
        onProgress: (@MainActor @Sendable (Double) -> Void)? = nil
    ) async throws {
        var exportConfig = config
        exportConfig.frameRate = frameRate.rawValue
        exportConfig.resolution = resolution.size
        
        try await TimelineExporter.shared.export(
            videoTracks: videoTracks,
            audioTracks: audioTracks,
            config: exportConfig,
            format: format,
            quality: quality,
            destinationURL: outputURL,
            lutLibrary: importedLUTs,
            onProgress: onProgress
        )
    }
    
    private func sourceDurationSeconds(for segment: TimelineClip) -> Double {
        if let mediaDuration = segment.mediaItem.durationSeconds, mediaDuration.isFinite, mediaDuration > 0 {
            return mediaDuration
        }
        let fallback = resolvedClipDuration(for: segment.mediaItem).seconds
        let occupied = max(segment.startTime.seconds, 0.0) + clipEditorSegmentDurationSeconds(segment)
        return max(fallback, occupied)
    }
    
    private func makeSegment(
        from source: TimelineClip,
        startSeconds: Double,
        durationSeconds: Double
    ) -> TimelineClip {
        TimelineClip(
            mediaItem: source.mediaItem,
            startTime: CMTime(seconds: max(0.0, startSeconds), preferredTimescale: 600),
            duration: CMTime(seconds: max(minimumEditorSegmentDurationSeconds, durationSeconds), preferredTimescale: 600),
            appliedLUTID: source.appliedLUTID,
            adjustments: source.adjustments,
            transforms: source.transforms,
            volume: source.volume,
            isMuted: source.isMuted
        )
    }
    
    private func clamp(_ value: Double, min lower: Double, max upper: Double) -> Double {
        Swift.max(lower, Swift.min(upper, value))
    }
    
    private func resolvedClipDuration(for item: MediaItem) -> CMTime {
        if let seconds = item.durationSeconds, seconds.isFinite, seconds > 0 {
            return CMTime(seconds: seconds, preferredTimescale: 600)
        }
        
        return CMTime(seconds: fallbackClipDurationSeconds, preferredTimescale: 600)
    }
    
    private func refreshClipDurations(for mediaItemID: UUID, loadedDurationSeconds: Double) {
        guard loadedDurationSeconds.isFinite, loadedDurationSeconds > 0 else { return }
        let loadedDuration = CMTime(seconds: loadedDurationSeconds, preferredTimescale: 600)
        
        for trackIndex in videoTracks.indices {
            for clipIndex in videoTracks[trackIndex].clips.indices where videoTracks[trackIndex].clips[clipIndex].mediaItem.id == mediaItemID {
                let current = videoTracks[trackIndex].clips[clipIndex].duration
                if shouldReplaceClipDuration(current) {
                    videoTracks[trackIndex].clips[clipIndex].duration = loadedDuration
                }
            }
        }
        
        for trackIndex in audioTracks.indices {
            for clipIndex in audioTracks[trackIndex].clips.indices where audioTracks[trackIndex].clips[clipIndex].mediaItem.id == mediaItemID {
                let current = audioTracks[trackIndex].clips[clipIndex].duration
                if shouldReplaceClipDuration(current) {
                    audioTracks[trackIndex].clips[clipIndex].duration = loadedDuration
                }
            }
        }
        
        if var isolated = isolatedClip, isolated.mediaItem.id == mediaItemID, shouldReplaceClipDuration(isolated.duration) {
            isolated.duration = loadedDuration
            isolatedClip = isolated
        }
    }
    
    private func shouldReplaceClipDuration(_ duration: CMTime) -> Bool {
        guard duration.isNumeric else { return true }
        let seconds = duration.seconds
        guard seconds.isFinite, seconds > 0 else { return true }
        return abs(seconds - fallbackClipDurationSeconds) < 0.001
    }
    
    private nonisolated static func loadMediaDurationSeconds(for url: URL, type: MediaItem.MediaType) async -> Double? {
        guard type != .image else { return nil }
        
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            guard duration.isNumeric else { return nil }
            let seconds = duration.seconds
            guard seconds.isFinite, seconds > 0 else { return nil }
            return seconds
        } catch {
            return nil
        }
    }
}
