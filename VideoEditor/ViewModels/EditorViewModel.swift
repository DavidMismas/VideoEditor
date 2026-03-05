import Foundation
import SwiftUI
import CoreMedia
import Observation

@Observable
class EditorViewModel {
    // Project Settings
    var config = ProjectConfig()
    
    // Playback Engine
    var engine = VideoPlaybackEngine()
    
    // Library
    var mediaLibrary: [MediaItem] = []
    
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
    
    // MARK: - Intents
    
    func importMedia(url: URL, type: MediaItem.MediaType) {
        let name = url.lastPathComponent
        let item = MediaItem(name: name, url: url, type: type)
        mediaLibrary.append(item)
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
    
    func addClip(item: MediaItem, toTrack trackId: UUID) {
        let newClip = TimelineClip(mediaItem: item, startTime: .zero, duration: CMTime(seconds: 5, preferredTimescale: 600))
        
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
    
    func selectClip(id: UUID?) {
        selectedClipId = id
        if let id = id, let clip = findClip(id: id), let url = clip.mediaItem.url {
            engine.loadMedia(from: url)
            engine.currentAdjustments = clip.adjustments
        }
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
}
