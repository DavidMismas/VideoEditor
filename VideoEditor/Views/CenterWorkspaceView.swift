import SwiftUI
import CoreMedia

struct CenterWorkspaceView: View {
    @Bindable var viewModel: EditorViewModel
    
    var body: some View {
        VSplitView {
            // Top: Live Preview
            LivePreviewView(viewModel: viewModel)
                .frame(minHeight: 200)
            
            // Middle: Active Clip Timeline
            ActiveClipEditorView(viewModel: viewModel)
                .frame(minHeight: 150)
            
            // Bottom: Master Timeline
            MasterTimelineView(viewModel: viewModel)
                .frame(minHeight: 200)
        }
    }
}

import AVKit

// Top: Live Preview
struct LivePreviewView: View {
    var viewModel: EditorViewModel
    @State private var isPortrait = false
    
    var body: some View {
        VStack {
            HStack {
                Text("Live Preview")
                    .foregroundColor(Theme.textSecondary)
                Spacer()
                
                Button(action: { isPortrait.toggle() }) {
                    Image(systemName: isPortrait ? "rectangle.portrait" : "rectangle")
                        .foregroundColor(Theme.accentPink)
                }
                .buttonStyle(.plain)
                
                Button(action: {}) {
                    Image(systemName: "crop")
                        .foregroundColor(Theme.textMain)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 4)
            }
            .padding(8)
            .background(Theme.panelBackground.opacity(0.8))
            
            // Actual Video Player
            ZStack {
                Color.black
                
                if viewModel.selectedClipId != nil || viewModel.isolatedClip != nil {
                    VideoPlayer(player: viewModel.engine.player)
                        .aspectRatio(isPortrait ? 9/16 : 16/9, contentMode: .fit)
                        .padding()
                } else {
                    Text("Select a clip or play the timeline to display preview")
                        .foregroundColor(Color(white: 0.3))
                }
            }
            
            // Controls
            HStack {
                Button(action: { viewModel.engine.togglePlayPause() }) {
                    Image(systemName: viewModel.engine.player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .foregroundColor(Theme.textMain)
                }
                .buttonStyle(.plain)
                .padding()
            }
        }
        .background(Color(white: 0.1))
    }
}

struct VideoPreviewPlaceholder: View {
    var adjustments: ColorAdjustments
    
    var body: some View {
        ZStack {
            // A fake "video frame"
            LinearGradient(
                colors: [Color(hue: 0.6 + adjustments.hue, saturation: 0.8 * adjustments.saturation, brightness: 0.5 + adjustments.exposure),
                         Color(hue: 0.8 + adjustments.hue, saturation: 0.5 * adjustments.saturation, brightness: 0.2 + adjustments.exposure)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            
            Image(systemName: "film.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 60)
                .foregroundColor(.white.opacity(0.3))
            
            // Apply a simple blur based on settings
            if adjustments.softBlur > 0 {
                Color.clear
                    .background(.regularMaterial)
                    .opacity(adjustments.softBlur / 10.0)
            }
        }
        .border(Theme.separator, width: 1)
        .overlay(
            // Vignette simulation
            RadialGradient(
                gradient: Gradient(colors: [.clear, .black.opacity(adjustments.vignette)]),
                center: .center, startRadius: 100, endRadius: 300
            )
        )
    }
}

// Middle: Active Clip Timeline
struct ActiveClipEditorView: View {
    var viewModel: EditorViewModel
    @State private var scrubValue: Double = 0
    @State private var isScrubbing: Bool = false
    
    private var hasActiveClip: Bool {
        viewModel.isolatedClip != nil || viewModel.selectedClipId != nil
    }
    
    private var effectiveDuration: Double {
        max(viewModel.engine.duration, 0.01)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Clip Editor")
                    .font(.caption)
                    .foregroundColor(Theme.accentGreen)
                    .padding(4)
                    .background(Theme.panelBackground.opacity(0.8))
                Spacer()
            }
            
            ZStack {
                Theme.panelBackground.opacity(0.5)
                
                if let isolatedClip = viewModel.isolatedClip {
                    // Fake waveform and trim handles that can be dragged down
                    HStack(spacing: 0) {
                        Rectangle().fill(Color.gray).frame(width: 10)
                        
                        ZStack {
                            Rectangle().fill(Theme.accentPink.opacity(0.3))
                            WaveformView()
                        }
                        
                        Rectangle().fill(Color.gray).frame(width: 10)
                    }
                    .padding()
                    .overlay(Text(isolatedClip.mediaItem.name).font(.caption).foregroundColor(.white))
                    .contentShape(Rectangle()) // ensure the whole area is draggable
                    .draggable(isolatedClip.id.uuidString)
                } else if let _ = viewModel.selectedClipId {
                    // Support legacy selected clip logic, though isolatedItem is preferred now
                    HStack(spacing: 0) {
                        Rectangle().fill(Color.gray).frame(width: 10)
                        
                        ZStack {
                            Rectangle().fill(Theme.accentPink.opacity(0.3))
                            WaveformView()
                        }
                        
                        Rectangle().fill(Color.gray).frame(width: 10)
                    }
                    .padding()
                } else {
                    Text("Drag a video here to isolate and edit")
                        .foregroundColor(Theme.textSecondary)
                }
            }
            .dropDestination(for: String.self) { items, location in
                guard let idString = items.first,
                      let uuid = UUID(uuidString: idString),
                      let item = viewModel.mediaLibrary.first(where: { $0.id == uuid }) else { return false }
                
                // Set the isolated item for the Middle view
                viewModel.isolatedClip = viewModel.makeTimelineClip(from: item)
                
                // Clear selected track clip if isolating a raw item
                viewModel.selectedClipId = nil
                
                return true
            }
            
            if hasActiveClip {
                VStack(spacing: 6) {
                    Slider(
                        value: Binding(
                            get: { isScrubbing ? scrubValue : viewModel.engine.currentTime },
                            set: { newValue in
                                scrubValue = newValue
                                if isScrubbing {
                                    viewModel.engine.seek(to: newValue, shouldPause: true)
                                }
                            }
                        ),
                        in: 0...effectiveDuration,
                        onEditingChanged: { editing in
                            isScrubbing = editing
                            if editing {
                                scrubValue = viewModel.engine.currentTime
                                viewModel.engine.pause()
                            } else {
                                viewModel.engine.seek(to: scrubValue, shouldPause: true)
                            }
                        }
                    )
                    .tint(Theme.accentPink)
                    
                    HStack {
                        Text(formatTime(isScrubbing ? scrubValue : viewModel.engine.currentTime))
                        Spacer()
                        Text(formatTime(viewModel.engine.duration))
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(Theme.textSecondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Theme.panelBackground.opacity(0.7))
            }
        }
        .onChange(of: viewModel.engine.currentTime) { _, newValue in
            if !isScrubbing {
                scrubValue = newValue
            }
        }
    }
    
    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds.rounded(.down))
        let mins = total / 60
        let secs = total % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}

struct WaveformView: View {
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<40) { _ in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Theme.accentGreen.opacity(0.6))
                    .frame(width: 3, height: CGFloat.random(in: 10...40))
            }
        }
    }
}

// Bottom: Master Timeline
struct MasterTimelineView: View {
    var viewModel: EditorViewModel
    private let pixelsPerSecond: CGFloat = 72
    private let laneHeaderWidth: CGFloat = 44
    
    private var timelineDuration: Double {
        let allTracks = viewModel.videoTracks + viewModel.audioTracks
        let longestTrack = allTracks
            .map { trackDuration($0) }
            .max() ?? 0
        return max(longestTrack, 1)
    }
    
    private var timelineWidth: CGFloat {
        max(CGFloat(timelineDuration) * pixelsPerSecond, 800)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Movie Timeline")
                .font(.caption)
                .foregroundColor(Theme.textMain)
                .padding(4)
                .background(Theme.panelBackground.opacity(0.8))
            
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 4) {
                    TimelineRulerView(
                        duration: timelineDuration,
                        width: timelineWidth,
                        pixelsPerSecond: pixelsPerSecond,
                        laneHeaderWidth: laneHeaderWidth
                    )
                    
                    // Video Tracks
                    ForEach(viewModel.videoTracks) { track in
                        TimelineTrackRow(
                            track: track,
                            timelineWidth: timelineWidth,
                            pixelsPerSecond: pixelsPerSecond,
                            laneHeaderWidth: laneHeaderWidth,
                            isSelected: .constant(false),
                            selectionAction: { id in
                            viewModel.selectClip(id: id)
                        }, dropStringAction: { idString, trackId in
                            if let uuid = UUID(uuidString: idString) {
                                if let isolated = viewModel.isolatedClip, isolated.id == uuid {
                                    if track.isAudioOnly && isolated.mediaItem.type == .video { return }
                                    viewModel.addExistingClip(clip: isolated, toTrack: trackId)
                                } else if let item = viewModel.mediaLibrary.first(where: { $0.id == uuid }) {
                                    if track.isAudioOnly && item.type == .video { return }
                                    Task {
                                        await viewModel.addClip(item: item, toTrack: trackId)
                                    }
                                }
                            }
                        })
                    }
                    
                    // Audio Tracks
                    ForEach(viewModel.audioTracks) { track in
                        TimelineTrackRow(
                            track: track,
                            timelineWidth: timelineWidth,
                            pixelsPerSecond: pixelsPerSecond,
                            laneHeaderWidth: laneHeaderWidth,
                            isSelected: .constant(false),
                            selectionAction: nil,
                            dropStringAction: { idString, trackId in
                            if let uuid = UUID(uuidString: idString) {
                                if let isolated = viewModel.isolatedClip, isolated.id == uuid {
                                    if track.isAudioOnly && isolated.mediaItem.type == .video { return }
                                    viewModel.addExistingClip(clip: isolated, toTrack: trackId)
                                } else if let item = viewModel.mediaLibrary.first(where: { $0.id == uuid }) {
                                    if track.isAudioOnly && item.type == .video { return }
                                    Task {
                                        await viewModel.addClip(item: item, toTrack: trackId)
                                    }
                                }
                            }
                        })
                    }
                    
                    Button(action: {}) {
                        Text("+ Add Audio Track")
                            .font(.caption)
                            .foregroundColor(Theme.accentGreen)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
                .padding()
            }
            .background(Color(white: 0.12))
        }
    }
    
    private func trackDuration(_ track: TimelineTrack) -> Double {
        track.clips.reduce(0) { partial, clip in
            partial + clipDurationSeconds(clip)
        }
    }
    
    private func clipDurationSeconds(_ clip: TimelineClip) -> Double {
        if clip.duration.isNumeric, clip.duration.seconds.isFinite, clip.duration.seconds > 0 {
            return clip.duration.seconds
        }
        if let libraryDuration = clip.mediaItem.durationSeconds, libraryDuration.isFinite, libraryDuration > 0 {
            return libraryDuration
        }
        return 5.0
    }
}

struct TimelineTrackRow: View {
    var track: TimelineTrack
    var timelineWidth: CGFloat
    var pixelsPerSecond: CGFloat
    var laneHeaderWidth: CGFloat
    @Binding var isSelected: Bool
    var selectionAction: ((UUID) -> Void)?
    var dropStringAction: ((String, UUID) -> Void)?
    
    @State private var isTargeted = false
    
    var body: some View {
        HStack {
            Text(track.name)
                .font(.caption)
                .foregroundColor(Theme.textSecondary)
                .frame(width: laneHeaderWidth, alignment: .leading)
            
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(isTargeted ? Theme.accentPink.opacity(0.3) : Theme.separator)
                    .frame(height: track.isAudioOnly ? 30 : 50)
                    .border(isTargeted ? Theme.accentPink : Color.clear, width: 2)
                
                // Render clips here
                if track.clips.isEmpty {
                    Text("Drop Media Here")
                        .font(.caption2)
                        .foregroundColor(Color(white: 0.3))
                        .padding(.leading, 8)
                } else {
                    HStack(spacing: 0) {
                        ForEach(track.clips) { clip in
                            ZStack(alignment: .bottomLeading) {
                                Rectangle()
                                .fill(track.isAudioOnly ? Theme.accentGreen : Theme.accentPink)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(clip.mediaItem.name)
                                        .font(.caption2.weight(.semibold))
                                        .lineLimit(1)
                                    Text(formatTime(clipDurationSeconds(clip)))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundColor(.white.opacity(0.9))
                                }
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                            }
                                .frame(width: clipWidth(clip))
                                .border(Theme.backgroundDark, width: 1)
                                .onTapGesture {
                                    selectionAction?(clip.id)
                                }
                        }
                        
                        let fillWidth = max(timelineWidth - usedTrackWidth, 0)
                        if fillWidth > 0 {
                            Color.clear.frame(width: fillWidth)
                        }
                    }
                }
            }
            .frame(width: timelineWidth, alignment: .leading)
            .dropDestination(for: String.self) { items, location in
                guard let idString = items.first else { return false }
                dropStringAction?(idString, track.id)
                return true
            } isTargeted: { targeted in
                isTargeted = targeted
            }
        }
    }
    
    private var usedTrackWidth: CGFloat {
        track.clips.reduce(0) { $0 + clipWidth($1) }
    }
    
    private func clipWidth(_ clip: TimelineClip) -> CGFloat {
        max(CGFloat(clipDurationSeconds(clip)) * pixelsPerSecond, 56)
    }
    
    private func clipDurationSeconds(_ clip: TimelineClip) -> Double {
        if clip.duration.isNumeric, clip.duration.seconds.isFinite, clip.duration.seconds > 0 {
            return clip.duration.seconds
        }
        if let libraryDuration = clip.mediaItem.durationSeconds, libraryDuration.isFinite, libraryDuration > 0 {
            return libraryDuration
        }
        return 5.0
    }
    
    private func formatTime(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        let total = Int(clamped.rounded(.down))
        let mins = total / 60
        let secs = total % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}

struct TimelineRulerView: View {
    var duration: Double
    var width: CGFloat
    var pixelsPerSecond: CGFloat
    var laneHeaderWidth: CGFloat
    
    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: laneHeaderWidth)
            
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Theme.panelBackground.opacity(0.85))
                    .frame(height: 24)
                
                ForEach(0...max(Int(ceil(duration)), 1), id: \.self) { second in
                    let x = CGFloat(second) * pixelsPerSecond
                    
                    Path { path in
                        path.move(to: CGPoint(x: x, y: 10))
                        path.addLine(to: CGPoint(x: x, y: 24))
                    }
                    .stroke(Theme.separator.opacity(0.9), lineWidth: 1)
                    
                    if second % 2 == 0 {
                        Text(formatTime(second))
                            .font(.caption2.monospacedDigit())
                            .foregroundColor(Theme.textSecondary)
                            .position(x: x + 16, y: 7)
                    }
                }
            }
            .frame(width: width, height: 24, alignment: .leading)
        }
    }
    
    private func formatTime(_ seconds: Int) -> String {
        let mins = seconds / 60
        let secs = seconds % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}
