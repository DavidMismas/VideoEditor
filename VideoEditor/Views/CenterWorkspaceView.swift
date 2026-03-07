import SwiftUI
import CoreMedia
import AppKit

private let clipEditorTrimCoordinateSpace = "ClipEditorTrimCoordinateSpace"

struct CenterWorkspaceView: View {
    @Bindable var viewModel: EditorViewModel
    
    var body: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 8
            let availableHeight = max(geo.size.height - (spacing * 2), 300)
            let previewHeight = availableHeight * 0.60
            let clipEditorHeight = availableHeight * 0.15
            let timelineSectionHeight = max(availableHeight - previewHeight - clipEditorHeight, 120)
            
            VStack(spacing: spacing) {
                LivePreviewView(viewModel: viewModel)
                    .frame(height: previewHeight)
                
                ActiveClipEditorView(viewModel: viewModel)
                    .frame(height: clipEditorHeight)
                
                MasterTimelineView(viewModel: viewModel)
                    .frame(height: timelineSectionHeight)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

import AVKit

// Top: Live Preview
struct LivePreviewView: View {
    var viewModel: EditorViewModel
    @State private var isPortrait = false
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Live Preview")
                    .foregroundColor(Theme.textSecondary)
                Spacer()

                Button(action: { viewModel.engine.togglePlayPause() }) {
                    Image(systemName: viewModel.engine.isPlaying ? "pause.fill" : "play.fill")
                        .foregroundColor(Theme.textMain)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 6)
                
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
    @State private var splitCursorArmed: Bool = false
    
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

                if hasActiveClip {
                    Button {
                        let newValue = !viewModel.clipEditorTrimModeEnabled
                        viewModel.clipEditorTrimModeEnabled = newValue
                        if newValue {
                            viewModel.clipEditorSplitModeEnabled = false
                        }
                    } label: {
                        Label("Trim", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                viewModel.clipEditorTrimModeEnabled
                                ? Theme.accentGreen.opacity(0.95)
                                : Theme.panelBackground.opacity(0.92)
                            )
                            .foregroundColor(.white)
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)

                    Button {
                        let newValue = !viewModel.clipEditorSplitModeEnabled
                        viewModel.clipEditorSplitModeEnabled = newValue
                        if newValue {
                            viewModel.clipEditorTrimModeEnabled = false
                        }
                    } label: {
                        Label("Cut", systemImage: "scissors")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                viewModel.clipEditorSplitModeEnabled
                                ? Theme.accentPink.opacity(0.95)
                                : Theme.panelBackground.opacity(0.92)
                            )
                            .foregroundColor(viewModel.clipEditorSplitModeEnabled ? .white : Theme.textMain)
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .padding(.bottom, 4)
            
            ZStack {
                Theme.panelBackground.opacity(0.5)
                
                if viewModel.isolatedClip != nil {
                    VStack(alignment: .leading, spacing: 4) {
                        GeometryReader { geo in
                            let segments = viewModel.clipEditorSegments
                            let occupiedDuration = max(viewModel.clipEditorTotalDurationSeconds(), 0.01)
                            let displayDuration = max(viewModel.clipEditorReferenceDurationSeconds, occupiedDuration, 0.01)
                            let horizontalPadding: CGFloat = 6
                            let availableWidth = max(geo.size.width - (horizontalPadding * 2.0), 1)
                            let transform = ClipEditorTimelineTransform(
                                contentWidth: availableWidth,
                                timelineDuration: displayDuration,
                                horizontalPadding: horizontalPadding
                            )
                            
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Theme.backgroundDark.opacity(0.5))

                                ForEach(segments) { segment in
                                    let segmentDuration = max(viewModel.clipEditorSegmentDurationSeconds(segment), 0.01)
                                    let segmentStart = max(viewModel.clipEditorTimelineStartSeconds(for: segment.id), 0.0)
                                    let width = max(transform.timeToWidth(segmentDuration), 2)
                                    let left = transform.timeToScreenX(segmentStart)

                                    ClipEditorSegmentView(
                                        viewModel: viewModel,
                                        segment: segment,
                                        width: width,
                                        transform: transform,
                                        trimEnabled: viewModel.clipEditorTrimModeEnabled && !viewModel.clipEditorSplitModeEnabled,
                                        dragEnabled: !viewModel.clipEditorTrimModeEnabled && !viewModel.clipEditorSplitModeEnabled
                                    )
                                    .offset(x: left, y: 6)
                                }
                            }
                            .coordinateSpace(name: clipEditorTrimCoordinateSpace)
                            .contentShape(Rectangle())
                            .simultaneousGesture(
                                SpatialTapGesture()
                                    .onEnded { value in
                                        guard viewModel.clipEditorSplitModeEnabled else { return }
                                        let localX = min(max(value.location.x - horizontalPadding, 0), availableWidth)
                                        let splitAt = (Double(localX) / max(Double(availableWidth), 1.0)) * displayDuration
                                        if viewModel.splitEditorSegment(atTimelineSeconds: splitAt) {
                                            viewModel.clipEditorSplitModeEnabled = false
                                        }
                                    }
                            )
                            .onHover { inside in
                                updateSplitCursor(inside: inside)
                            }
                        }
                        .frame(height: 74)
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                    .padding(.bottom, 6)
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
            .dropDestination(for: String.self) { items, _ in
                guard let idString = items.first else { return false }
                
                if idString.hasPrefix("lut:"),
                   let lutID = UUID(uuidString: String(idString.dropFirst(4))) {
                    let targetClipID = viewModel.isolatedClip?.id ?? viewModel.selectedClipId
                    guard let targetClipID else { return false }
                    return viewModel.applyLUT(lutID, toClip: targetClipID)
                }
                
                guard let uuid = UUID(uuidString: idString),
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
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Theme.panelBackground.opacity(0.7))
            }
        }
        .onChange(of: viewModel.engine.currentTime) { _, newValue in
            if !isScrubbing {
                scrubValue = newValue
            }
        }
        .onChange(of: viewModel.clipEditorSplitModeEnabled) { _, enabled in
            if !enabled {
                releaseSplitCursorIfNeeded()
            }
        }
        .onDisappear {
            releaseSplitCursorIfNeeded()
        }
    }
    
    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00.0" }
        let total = Int(seconds.rounded(.down))
        let mins = total / 60
        let secs = total % 60
        let tenths = Int(((seconds - floor(seconds)) * 10).rounded(.down))
        return String(format: "%02d:%02d.%01d", mins, secs, max(0, min(tenths, 9)))
    }
    
    private func updateSplitCursor(inside: Bool) {
        if viewModel.clipEditorSplitModeEnabled && inside {
            guard !splitCursorArmed else { return }
            Self.scissorsCursor.push()
            splitCursorArmed = true
        } else {
            releaseSplitCursorIfNeeded()
        }
    }
    
    private func releaseSplitCursorIfNeeded() {
        guard splitCursorArmed else { return }
        NSCursor.pop()
        splitCursorArmed = false
    }
    
    private static var scissorsCursor: NSCursor = {
        let size = NSSize(width: 24, height: 24)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.clear.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        if let symbol = NSImage(systemSymbolName: "scissors", accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfig) {
            symbol.draw(in: NSRect(x: 5, y: 5, width: 14, height: 14))
        }
        image.unlockFocus()
        return NSCursor(image: image, hotSpot: NSPoint(x: 4, y: 20))
    }()
}

struct ClipEditorSegmentView: View {
    var viewModel: EditorViewModel
    var segment: TimelineClip
    var width: CGFloat
    var transform: ClipEditorTimelineTransform
    var trimEnabled: Bool
    var dragEnabled: Bool

    @State private var moveHoverArmed = false
    @State private var leadingHoverArmed = false
    @State private var trailingHoverArmed = false
    @State private var activeMode: ClipInteractionMode?
    
    private let visibleHandleWidth: CGFloat = 6
    private let handleHitWidth: CGFloat = 16
    
    var body: some View {
        ZStack(alignment: .leading) {
            segmentBody
                .frame(width: width, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.black.opacity(0.35), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.22), radius: 6, y: 2)

            if trimEnabled {
                interactionHitArea(for: .trimLeft)
                    .frame(width: effectiveHandleHitWidth, height: 72)

                interactionHitArea(for: .trimRight)
                    .frame(width: effectiveHandleHitWidth, height: 72)
                    .offset(x: max(width - effectiveHandleHitWidth, 0))
            }

            if dragEnabled {
                moveArea
                    .frame(width: width, height: 72)
            }
        }
        .frame(width: width, height: 72, alignment: .leading)
        .onDisappear {
            releaseAllCursors()
            if activeMode != nil {
                viewModel.endClipEditorInteraction()
                activeMode = nil
            }
        }
    }
    
    private var segmentBody: some View {
        ZStack {
            HStack(spacing: 0) {
                handleVisual(color: Theme.accentGreen.opacity(trimEnabled ? 0.95 : 0.72))
                    .frame(width: actualHandleWidth)

                Rectangle()
                    .fill(Theme.accentPink.opacity(0.48))
                    .frame(width: actualBodyWidth)

                handleVisual(color: Theme.accentPink.opacity(trimEnabled ? 0.95 : 0.72))
                    .frame(width: actualHandleWidth)
            }

            WaveformView()
                .padding(.horizontal, waveformHorizontalPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            
            Text(durationLabel)
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundColor(.white.opacity(0.95))
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.35))
                .clipShape(Capsule())
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }
    
    private var durationSeconds: Double {
        max(0.10, segment.duration.seconds.isFinite ? segment.duration.seconds : 0.10)
    }
    
    private var durationLabel: String {
        formatTime(durationSeconds)
    }
    
    private var actualHandleWidth: CGFloat {
        min(visibleHandleWidth, max(width * 0.18, 2))
    }

    private var actualBodyWidth: CGFloat {
        max(width - (actualHandleWidth * 2), 0)
    }

    private var waveformHorizontalPadding: CGFloat {
        min(11, max(actualBodyWidth * 0.08, 2))
    }

    private var effectiveHandleHitWidth: CGFloat {
        min(handleHitWidth, max(width / 2, actualHandleWidth))
    }

    private func handleVisual(color: Color) -> some View {
        Rectangle()
            .fill(color)
    }

    private var moveArea: some View {
        Color.clear
            .contentShape(Rectangle())
            .draggable(segment.id.uuidString)
            .onHover { inside in
                guard dragEnabled else {
                    releaseMoveCursorIfNeeded()
                    return
                }
                if inside && !moveHoverArmed {
                    NSCursor.openHand.push()
                    moveHoverArmed = true
                } else if !inside {
                    releaseMoveCursorIfNeeded()
                }
            }
    }

    private func interactionHitArea(for mode: ClipInteractionMode) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onHover { inside in
                guard trimEnabled else {
                    releaseHandleCursorIfNeeded(for: mode)
                    return
                }
                if inside {
                    armHandleCursorIfNeeded(for: mode)
                } else {
                    releaseHandleCursorIfNeeded(for: mode)
                }
            }
            .highPriorityGesture(dragGesture(for: mode))
    }

    private func dragGesture(for mode: ClipInteractionMode) -> some Gesture {
        DragGesture(
            minimumDistance: 0,
            coordinateSpace: .named(clipEditorTrimCoordinateSpace)
        )
        .onChanged { value in
            guard trimEnabled else { return }
            if activeMode == nil {
                viewModel.beginClipEditorInteraction(
                    id: segment.id,
                    mode: mode,
                    mouseDownX: value.startLocation.x,
                    transform: transform
                )
                activeMode = mode
            }
            viewModel.updateClipEditorInteraction(currentMouseX: value.location.x)
        }
        .onEnded { _ in
            guard activeMode == mode else { return }
            viewModel.endClipEditorInteraction()
            activeMode = nil
        }
    }

    private func armHandleCursorIfNeeded(for mode: ClipInteractionMode) {
        switch mode {
        case .trimLeft:
            guard !leadingHoverArmed else { return }
            NSCursor.resizeLeftRight.push()
            leadingHoverArmed = true
        case .trimRight:
            guard !trailingHoverArmed else { return }
            NSCursor.resizeLeftRight.push()
            trailingHoverArmed = true
        case .move:
            break
        }
    }

    private func releaseHandleCursorIfNeeded(for mode: ClipInteractionMode) {
        switch mode {
        case .trimLeft:
            guard leadingHoverArmed else { return }
            NSCursor.pop()
            leadingHoverArmed = false
        case .trimRight:
            guard trailingHoverArmed else { return }
            NSCursor.pop()
            trailingHoverArmed = false
        case .move:
            break
        }
    }

    private func releaseMoveCursorIfNeeded() {
        guard moveHoverArmed else { return }
        NSCursor.pop()
        moveHoverArmed = false
    }

    private func releaseAllCursors() {
        releaseMoveCursorIfNeeded()
        releaseHandleCursorIfNeeded(for: .trimLeft)
        releaseHandleCursorIfNeeded(for: .trimRight)
    }
    
    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00.0" }
        let total = Int(seconds.rounded(.down))
        let mins = total / 60
        let secs = total % 60
        let tenths = Int(((seconds - floor(seconds)) * 10).rounded(.down))
        return String(format: "%02d:%02d.%01d", mins, secs, max(0, min(tenths, 9)))
    }
}

struct WaveformView: View {
    private static let barHeights: [CGFloat] = [
        10, 16, 24, 20, 14, 26, 30, 22, 18, 28,
        12, 20, 26, 16, 14, 24, 30, 18, 12, 22,
        28, 16, 10, 18, 24, 30, 20, 14, 26, 18,
        12, 20, 28, 16, 14, 24, 30, 22, 18, 12
    ]
    
    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(Self.barHeights.enumerated()), id: \.offset) { _, height in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Theme.accentGreen.opacity(0.6))
                    .frame(width: 3, height: height)
            }
        }
    }
}

struct ScrubbableWaveformView: View {
    @Bindable var engine: VideoPlaybackEngine
    @Binding var isScrubbing: Bool
    @Binding var scrubValue: Double
    var effectiveDuration: Double
    
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.accentPink.opacity(0.3))
                WaveformView()
                
                // Playhead indicator
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2)
                    .offset(x: max(0, min((isScrubbing ? scrubValue : engine.currentTime) / effectiveDuration, 1)) * geo.size.width)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isScrubbing = true
                        let percent = max(0, min(value.location.x / geo.size.width, 1))
                        let newTime = percent * effectiveDuration
                        scrubValue = newTime
                        engine.seek(to: newTime, shouldPause: true)
                    }
                    .onEnded { _ in
                        isScrubbing = false
                    }
            )
        }
    }
}

// Bottom: Master Timeline
struct MasterTimelineView: View {
    var viewModel: EditorViewModel
    @State private var timelineZoom: Double = 1.0
    @State private var playheadSeconds: Double = 0
    
    private let basePixelsPerSecond: CGFloat = 72
    private let laneHeaderWidth: CGFloat = 44
    private let minTimelineZoom: Double = 0.5
    private let maxTimelineZoom: Double = 4.0
    private let zoomStep: Double = 0.25
    
    private var pixelsPerSecond: CGFloat {
        basePixelsPerSecond * CGFloat(timelineZoom)
    }
    
    private var zoomLabel: String {
        "\(Int((timelineZoom * 100).rounded()))%"
    }
    
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
    
    private var playheadOffset: CGFloat {
        CGFloat(min(max(playheadSeconds, 0), timelineDuration)) * pixelsPerSecond
    }
    
    private var playheadHeight: CGFloat {
        let videoHeight = CGFloat(viewModel.videoTracks.count) * 50
        let audioHeight = CGFloat(viewModel.audioTracks.count) * 30
        let rowSpacing = CGFloat(max(viewModel.videoTracks.count + viewModel.audioTracks.count - 1, 0)) * 4
        return 24 + 4 + videoHeight + audioHeight + rowSpacing
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("Movie Timeline")
                    .font(.caption)
                    .foregroundColor(Theme.textMain)
                
                Spacer()
                
                HStack(spacing: 6) {
                    Button(action: { changeZoom(by: -zoomStep) }) {
                        Image(systemName: "minus.magnifyingglass")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(Theme.textSecondary)
                    
                    Slider(value: $timelineZoom, in: minTimelineZoom...maxTimelineZoom)
                        .frame(width: 120)
                        .tint(Theme.accentPink)
                    
                    Text(zoomLabel)
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(Theme.textSecondary)
                        .frame(width: 42, alignment: .trailing)
                    
                    Button(action: { changeZoom(by: zoomStep) }) {
                        Image(systemName: "plus.magnifyingglass")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(Theme.textSecondary)
                }
            }
            .padding(6)
            .background(Theme.panelBackground.opacity(0.8))
            
            ScrollView(.horizontal) {
                ZStack(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 4) {
                        TimelineRulerView(
                            duration: timelineDuration,
                            width: timelineWidth,
                            pixelsPerSecond: pixelsPerSecond,
                            laneHeaderWidth: laneHeaderWidth,
                            playheadSeconds: playheadSeconds
                        ) { seconds in
                            playheadSeconds = seconds
                        }
                        
                        // Video Tracks
                        ForEach(viewModel.videoTracks) { track in
                            TimelineTrackRow(
                                track: track,
                                timelineWidth: timelineWidth,
                                pixelsPerSecond: pixelsPerSecond,
                                laneHeaderWidth: laneHeaderWidth,
                                isSelected: .constant(false),
                                lutNameProvider: { viewModel.lutName(for: $0) },
                                selectionAction: { id in
                                viewModel.selectClip(id: id)
                            }, dropStringAction: { idString, trackId, _ in
                                if let uuid = UUID(uuidString: idString) {
                                    if let draggedClip = viewModel.draggableClip(for: uuid) {
                                        if track.isAudioOnly && draggedClip.mediaItem.type == .video { return }
                                        viewModel.addExistingClip(clip: draggedClip, toTrack: trackId)
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
                                lutNameProvider: nil,
                                selectionAction: nil,
                                dropStringAction: { idString, trackId, _ in
                                if let uuid = UUID(uuidString: idString) {
                                    if let draggedClip = viewModel.draggableClip(for: uuid) {
                                        if track.isAudioOnly && draggedClip.mediaItem.type == .video { return }
                                        viewModel.addExistingClip(clip: draggedClip, toTrack: trackId)
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
                    
                    Rectangle()
                        .fill(Theme.accentPink.opacity(0.9))
                        .frame(width: 2, height: playheadHeight)
                        .offset(x: laneHeaderWidth + playheadOffset)
                        .allowsHitTesting(false)
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
    
    private func changeZoom(by delta: Double) {
        timelineZoom = min(max(timelineZoom + delta, minTimelineZoom), maxTimelineZoom)
    }
}

struct TimelineTrackRow: View {
    var track: TimelineTrack
    var timelineWidth: CGFloat
    var pixelsPerSecond: CGFloat
    var laneHeaderWidth: CGFloat
    @Binding var isSelected: Bool
    var lutNameProvider: ((UUID) -> String?)?
    var selectionAction: ((UUID) -> Void)?
    var dropStringAction: ((String, UUID, UUID?) -> Void)?
    
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
                                    if let lutID = clip.appliedLUTID,
                                       let lutName = lutNameProvider?(lutID) {
                                        Text("LUT: \(lutName)")
                                            .font(.caption2)
                                            .lineLimit(1)
                                            .foregroundColor(.white.opacity(0.9))
                                    }
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
                                .dropDestination(for: String.self) { items, _ in
                                    guard let idString = items.first, !idString.hasPrefix("lut:") else { return false }
                                    dropStringAction?(idString, track.id, clip.id)
                                    return true
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
                guard let idString = items.first, !idString.hasPrefix("lut:") else { return false }
                let targetClipId = clipID(at: location.x)
                dropStringAction?(idString, track.id, targetClipId)
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
        let tenths = Int(((clamped - floor(clamped)) * 10).rounded(.down))
        return String(format: "%02d:%02d.%01d", mins, secs, max(0, min(tenths, 9)))
    }
    
    private func clipID(at xPosition: CGFloat) -> UUID? {
        guard !track.clips.isEmpty else { return nil }
        
        var cursor: CGFloat = 0
        for clip in track.clips {
            let width = clipWidth(clip)
            if xPosition >= cursor, xPosition <= (cursor + width) {
                return clip.id
            }
            cursor += width
        }
        
        return nil
    }
}

struct TimelineRulerView: View {
    var duration: Double
    var width: CGFloat
    var pixelsPerSecond: CGFloat
    var laneHeaderWidth: CGFloat
    var playheadSeconds: Double
    var onSeek: (Double) -> Void
    
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
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let seconds = max(0, min(Double(value.location.x) / max(pixelsPerSecond, 1), duration))
                        onSeek(seconds)
                    }
            )
        }
    }
    
    private func formatTime(_ seconds: Int) -> String {
        let mins = seconds / 60
        let secs = seconds % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}
