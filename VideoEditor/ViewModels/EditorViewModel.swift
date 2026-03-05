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
    
    var isolatedClip: TimelineClip? {
        didSet {
            guard let isolated = isolatedClip else {
                if oldValue != nil {
                    engine.currentAdjustments = ColorAdjustments()
                    engine.currentLUTURL = nil
                }
                return
            }
            
            // Only reload media when the isolated clip itself changes.
            // Slider-driven adjustment changes mutate the same clip instance and should not reset playback.
            let clipChanged = oldValue?.id != isolated.id || oldValue?.mediaItem.url != isolated.mediaItem.url
            if clipChanged, let url = isolated.mediaItem.url {
                engine.loadMedia(from: url)
            }
            
            engine.currentAdjustments = isolated.adjustments
            engine.currentLUTURL = lutURL(for: isolated.appliedLUTID)
        }
    }
    
    // Active adjustments view
    var activeAdjustments: ColorAdjustments {
        get {
            if let isolated = isolatedClip {
                return isolated.adjustments
            }
            guard let id = selectedClipId,
                  let clip = findClip(id: id) else { return ColorAdjustments() }
            return clip.adjustments
        }
        set {
            if isolatedClip != nil {
                isolatedClip?.adjustments = newValue
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
    
    private let fallbackClipDurationSeconds: Double = 5.0
    
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
        // Search in video tracks
        if let idx = videoTracks.firstIndex(where: { $0.id == trackId }) {
            videoTracks[idx].clips.append(clip)
            return
        }
        // Search in audio tracks
        if let idx = audioTracks.firstIndex(where: { $0.id == trackId }) {
            audioTracks[idx].clips.append(clip)
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
                    engine.currentLUTURL = lut.url
                }
                return true
            }
        }
        
        if isolatedClip?.id == clipID {
            isolatedClip?.appliedLUTID = lutID
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
    
    func exportBottomTimeline(
        to outputURL: URL,
        format: ExportFormat,
        onProgress: (@MainActor @Sendable (Double) -> Void)? = nil
    ) async throws {
        try await TimelineExporter.shared.export(
            videoTracks: videoTracks,
            audioTracks: audioTracks,
            config: config,
            format: format,
            destinationURL: outputURL,
            lutLibrary: importedLUTs,
            onProgress: onProgress
        )
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
