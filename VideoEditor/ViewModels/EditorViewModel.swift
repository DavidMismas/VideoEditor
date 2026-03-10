import Foundation
import SwiftUI
import CoreMedia
import AVFoundation
import CoreVideo
import Observation

enum TimelinePreviewMode {
    case clip
    case movie
}

struct WorkspaceAlert: Identifiable, Equatable {
    let id: UUID = UUID()
    let title: String
    let message: String
}

@Observable
class EditorViewModel {
    // Project Settings
    var config = ProjectConfig()
    var projectName: String?
    var projectFileURL: URL?
    var pendingAlert: WorkspaceAlert?
    
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
    var selectedTimelineClipID: UUID?
    var previewMode: TimelinePreviewMode = .clip
    
    // Middle clip-editor segments (trim/split source for drag into bottom timeline)
    var clipEditorSegments: [TimelineClip] = []
    var clipEditorReferenceDurationSeconds: Double = 0
    var clipEditorSplitModeEnabled: Bool = false
    var clipEditorTrimModeEnabled: Bool = false
    var activeClipEditorDragSession: ClipDragSession?
    
    var isolatedClip: TimelineClip? {
        didSet {
            guard let isolated = isolatedClip else {
                if oldValue != nil {
                    engine.currentAdjustments = ColorAdjustments()
                    engine.currentLUTURL = nil
                    engine.clearCurrentItem()
                    clipEditorSegments = []
                    clipEditorReferenceDurationSeconds = 0
                    clipEditorSplitModeEnabled = false
                    clipEditorTrimModeEnabled = false
                    activeClipEditorDragSession = nil
                }
                return
            }

            previewMode = .clip
            selectedTimelineClipID = nil
            moviePreviewLoadTask?.cancel()
            moviePreviewLoadTask = nil
            engine.currentAdjustments = isolated.adjustments
            engine.currentLUTURL = lutURL(for: isolated.appliedLUTID)
            
            // Only reload media when the isolated clip itself changes.
            // Slider-driven adjustment changes mutate the same clip instance and should not reset playback.
            let clipChanged = oldValue?.id != isolated.id || oldValue?.mediaItem.url != isolated.mediaItem.url
            if clipChanged, let url = existingURL(for: isolated.mediaItem.url) {
                engine.loadMedia(from: url)
                clipEditorSegments = [makeClipEditorRootSegment(from: isolated)]
                clipEditorReferenceDurationSeconds = max(
                    sourceDurationSeconds(for: isolated),
                    max(isolated.duration.seconds, minimumEditorSegmentDurationSeconds)
                )
            } else if clipChanged {
                engine.pause()
                engine.clearCurrentItem()
            } else if clipEditorSegments.isEmpty {
                clipEditorSegments = [makeClipEditorRootSegment(from: isolated)]
                clipEditorReferenceDurationSeconds = max(
                    sourceDurationSeconds(for: isolated),
                    max(isolated.duration.seconds, minimumEditorSegmentDurationSeconds)
                )
            } else if clipEditorSegments.count == 1, clipEditorSegments[0].mediaItem.id == isolated.mediaItem.id {
                clipEditorSegments[0].startTime = isolated.startTime
                clipEditorSegments[0].duration = isolated.duration
                clipEditorSegments[0].appliedLUTID = isolated.appliedLUTID
                clipEditorSegments[0].adjustments = isolated.adjustments
                clipEditorSegments[0].transforms = isolated.transforms
            } else if oldValue?.appliedLUTID != isolated.appliedLUTID {
                for index in clipEditorSegments.indices {
                    clipEditorSegments[index].appliedLUTID = isolated.appliedLUTID
                }
            } else if oldValue?.transforms != isolated.transforms {
                for index in clipEditorSegments.indices {
                    clipEditorSegments[index].transforms = isolated.transforms
                }
            }

            clipEditorReferenceDurationSeconds = max(
                sourceDurationSeconds(for: isolated),
                clipEditorTotalDurationSeconds(),
                minimumEditorSegmentDurationSeconds
            )

            activeClipEditorDragSession = nil
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
    
    private let fallbackClipDurationSeconds: Double = 5.0
    private let minimumEditorSegmentDurationSeconds: Double = 0.10
    private let clipEditorInteractionDebugLogging = true
    @ObservationIgnored private var moviePreviewLoadTask: Task<Void, Never>?
    @ObservationIgnored private var mediaAccessBookmarks: [UUID: Data] = [:]
    @ObservationIgnored private var lutAccessBookmarks: [UUID: Data] = [:]
    @ObservationIgnored private var activeSecurityScopedURLs: Set<URL> = []

    var hasActiveProject: Bool {
        projectName != nil
    }

    var resolvedProjectName: String {
        projectName ?? "Untitled Project"
    }

    var projectCanvasDescription: String {
        "\(config.resolutionPreset.displayName) • \(config.canvasOrientation.displayName)"
    }

    var projectResolutionDescription: String {
        let size = config.resolution
        return "\(Int(size.width))x\(Int(size.height))"
    }

    var missingMediaItems: [MediaItem] {
        mediaLibrary.filter { item in
            guard let url = item.url else { return true }
            return !Self.canAccessFile(at: url)
        }
    }

    var missingLUTItems: [LUTItem] {
        importedLUTs.filter { !Self.canAccessFile(at: $0.url) }
    }

    var hasMissingProjectAssets: Bool {
        !missingMediaItems.isEmpty || !missingLUTItems.isEmpty
    }

    var missingAssetsSummary: String {
        var parts: [String] = []
        if !missingMediaItems.isEmpty {
            parts.append("\(missingMediaItems.count) media")
        }
        if !missingLUTItems.isEmpty {
            parts.append("\(missingLUTItems.count) LUT")
        }
        return parts.joined(separator: " and ")
    }

    var missingAssetsDetail: String {
        let missingMediaNames = missingMediaItems.prefix(3).map(\.name)
        let missingLUTNames = missingLUTItems.prefix(3).map(\.name)
        let names = missingMediaNames + missingLUTNames
        return names.joined(separator: ", ")
    }
    
    // MARK: - Intents

    func createProject(
        name: String,
        resolutionPreset: ProjectResolutionPreset,
        canvasOrientation: CanvasOrientation
    ) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw ProjectPersistenceError.invalidProjectName
        }

        resetEditorState()
        projectName = trimmedName
        projectFileURL = nil
        config = ProjectConfig(
            resolutionPreset: resolutionPreset,
            frameRate: exportFrameRate.rawValue,
            canvasOrientation: canvasOrientation
        )
    }

    func closeProject() {
        resetEditorState()
        projectName = nil
        projectFileURL = nil
    }

    func openProject(at url: URL) throws {
        let project = try ProjectFileStore.load(from: url)

        resetEditorState()
        projectName = project.name
        projectFileURL = url
        config = project.config
        mediaAccessBookmarks = Dictionary(uniqueKeysWithValues: project.mediaAccessBookmarks.map { ($0.id, $0.bookmarkData) })
        lutAccessBookmarks = Dictionary(uniqueKeysWithValues: project.lutAccessBookmarks.map { ($0.id, $0.bookmarkData) })
        mediaLibrary = project.mediaLibrary.map { item in
            var item = item
            item.url = item.url?.standardizedFileURL
            return item
        }
        importedLUTs = project.importedLUTs.map { item in
            var item = item
            item.url = item.url.standardizedFileURL
            item.descriptor = ImportedLUTManager.shared.descriptor(for: item.url)
            return item
        }
        videoTracks = project.videoTracks.isEmpty ? [TimelineTrack(name: "V1", clips: [])] : project.videoTracks
        audioTracks = project.audioTracks.isEmpty ? [TimelineTrack(name: "A1", clips: [], isAudioOnly: true)] : project.audioTracks
        exportFormat = project.exportFormat
        exportQuality = project.exportQuality
        exportFrameRate = project.exportFrameRate
        restoreProjectAssetAccess()
        refreshImportedLUTDescriptors()
        reconcileProjectAssetReferences()
        refreshLibraryMetadata()
    }

    func saveProject() throws {
        guard let projectFileURL else {
            throw ProjectPersistenceError.noProjectLoaded
        }
        try saveProject(to: projectFileURL)
    }

    func saveProject(to url: URL) throws {
        guard hasActiveProject else {
            throw ProjectPersistenceError.noProjectLoaded
        }

        ensureProjectAssetBookmarks()

        let project = SavedProjectState(
            name: resolvedProjectName,
            config: config,
            mediaLibrary: mediaLibrary,
            importedLUTs: importedLUTs,
            videoTracks: videoTracks,
            audioTracks: audioTracks,
            exportFormat: exportFormat,
            exportQuality: exportQuality,
            exportFrameRate: exportFrameRate,
            mediaAccessBookmarks: mediaAccessBookmarks.map { SavedSecurityScopedBookmark(id: $0.key, bookmarkData: $0.value) }
                .sorted { $0.id.uuidString < $1.id.uuidString },
            lutAccessBookmarks: lutAccessBookmarks.map { SavedSecurityScopedBookmark(id: $0.key, bookmarkData: $0.value) }
                .sorted { $0.id.uuidString < $1.id.uuidString }
        )
        try ProjectFileStore.save(project, to: url)
        projectFileURL = url
        projectName = project.name
    }

    func importMedia(url: URL, type: MediaItem.MediaType) {
        let normalizedURL = url.standardizedFileURL
        let name = normalizedURL.lastPathComponent
        let item = MediaItem(name: name, url: normalizedURL, type: type)
        mediaLibrary.append(item)
        if let bookmark = Self.makeSecurityScopedBookmark(for: normalizedURL) {
            mediaAccessBookmarks[item.id] = bookmark
        }
        
        let itemID = item.id
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let metadata = await Self.loadMediaMetadata(for: normalizedURL, type: type)
            
            await MainActor.run {
                guard let idx = self.mediaLibrary.firstIndex(where: { $0.id == itemID }) else { return }
                if let durationSeconds = metadata.durationSeconds {
                    self.mediaLibrary[idx].durationSeconds = durationSeconds
                    self.refreshClipDurations(for: itemID, loadedDurationSeconds: durationSeconds)
                }
                self.replaceMediaItemReferences(with: self.mediaLibrary[idx])
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
            url: normalizedURL,
            descriptor: ImportedLUTManager.shared.descriptor(for: normalizedURL)
        )
        importedLUTs.append(item)
        if let bookmark = Self.makeSecurityScopedBookmark(for: normalizedURL) {
            lutAccessBookmarks[item.id] = bookmark
        }
        return true
    }
    
    func addExistingClip(clip: TimelineClip, toTrack trackId: UUID) {
        // Clone clip so repeated drags create independent timeline entries.
        let duplicatedClip = TimelineClip(
            mediaItem: clip.mediaItem,
            startTime: clip.startTime,
            duration: clip.duration,
            timelineStart: clip.timelineStart,
            appliedLUTID: clip.appliedLUTID,
            adjustments: clip.adjustments,
            transforms: clip.transforms,
            volume: clip.volume,
            isMuted: clip.isMuted
        )
        // Search in video tracks
        if let idx = videoTracks.firstIndex(where: { $0.id == trackId }) {
            videoTracks[idx].clips.append(duplicatedClip)
            refreshMovieTimelinePreviewIfNeeded()
            return
        }
        // Search in audio tracks
        if let idx = audioTracks.firstIndex(where: { $0.id == trackId }) {
            audioTracks[idx].clips.append(duplicatedClip)
            refreshMovieTimelinePreviewIfNeeded()
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
            refreshMovieTimelinePreviewIfNeeded()
            return
        }
        // Search in audio tracks
        if let idx = audioTracks.firstIndex(where: { $0.id == trackId }) {
            audioTracks[idx].clips.append(newClip)
            refreshMovieTimelinePreviewIfNeeded()
            return
        }
    }

    func deleteMediaItem(_ itemID: UUID) {
        mediaLibrary.removeAll { $0.id == itemID }
        mediaAccessBookmarks[itemID] = nil
        removeTimelineClips(where: { $0.mediaItem.id == itemID })

        if isolatedClip?.mediaItem.id == itemID {
            isolatedClip = nil
        }
        if selectedMediaLibraryItemId == itemID {
            selectedMediaLibraryItemId = nil
        }
        syncSelectionAfterTimelineMutation()
    }

    func deleteClipEditorSegment(_ segmentID: UUID) {
        guard let index = clipEditorSegments.firstIndex(where: { $0.id == segmentID }) else { return }

        clipEditorSegments.remove(at: index)
        activeClipEditorDragSession = nil

        guard let firstRemaining = clipEditorSegments.first else {
            isolatedClip = nil
            return
        }

        clipEditorReferenceDurationSeconds = max(
            sourceDurationSeconds(for: firstRemaining),
            clipEditorTotalDurationSeconds(),
            minimumEditorSegmentDurationSeconds
        )

        if var isolated = isolatedClip {
            isolated.startTime = firstRemaining.startTime
            isolated.duration = firstRemaining.duration
            isolated.appliedLUTID = firstRemaining.appliedLUTID
            isolated.adjustments = firstRemaining.adjustments
            isolated.transforms = firstRemaining.transforms
            isolated.volume = firstRemaining.volume
            isolated.isMuted = firstRemaining.isMuted
            isolatedClip = isolated
        }
    }

    func deleteTimelineClip(_ clipID: UUID) {
        removeTimelineClips(where: { $0.id == clipID })
        syncSelectionAfterTimelineMutation()
    }
    
    func makeTimelineClip(from item: MediaItem) -> TimelineClip {
        TimelineClip(
            mediaItem: item,
            startTime: .zero,
            duration: resolvedClipDuration(for: item),
            timelineStart: .zero
        )
    }
    
    func selectClip(id: UUID?) {
        previewMode = .clip
        selectedTimelineClipID = nil
        selectedClipId = id
        guard let id = id,
              let clip = findClip(id: id),
              let url = existingURL(for: clip.mediaItem.url)
        else {
            if id == nil {
                engine.currentAdjustments = ColorAdjustments()
                engine.currentLUTURL = nil
                engine.clearCurrentItem()
            } else {
                engine.pause()
                engine.clearCurrentItem()
            }
            return
        }
        
        engine.currentAdjustments = clip.adjustments
        engine.currentLUTURL = lutURL(for: clip.appliedLUTID)
        engine.loadMedia(from: url)
    }

    var isMovieTimelinePreviewActive: Bool {
        previewMode == .movie
    }

    var hasMovieTimelineContent: Bool {
        videoTracks.contains(where: { !$0.clips.isEmpty })
    }

    var activePreviewClip: TimelineClip? {
        guard !isMovieTimelinePreviewActive else { return nil }
        if let isolatedClip {
            return isolatedClip
        }
        guard let selectedClipId else { return nil }
        return findClip(id: selectedClipId)
    }

    var activePreviewClipID: UUID? {
        activePreviewClip?.id
    }

    var activePreviewTransforms: Transforms {
        activePreviewClip?.transforms ?? Transforms()
    }

    var canvasOrientation: CanvasOrientation {
        config.canvasOrientation
    }

    var canvasAspectRatio: CGFloat {
        config.canvasOrientation.aspectRatio
    }

    var previewSourceAspectRatio: CGFloat {
        let size = engine.presentationSize
        guard size.width > 1, size.height > 1 else { return canvasAspectRatio }
        return max(size.width / size.height, 0.001)
    }

    func updateTransforms(for id: UUID?, _ newTransforms: Transforms) {
        guard let id else { return }

        for trackIndex in videoTracks.indices {
            if let clipIndex = videoTracks[trackIndex].clips.firstIndex(where: { $0.id == id }) {
                videoTracks[trackIndex].clips[clipIndex].transforms = newTransforms
                refreshMovieTimelinePreviewIfNeeded()
                break
            }
        }

        if isolatedClip?.id == id {
            isolatedClip?.transforms = newTransforms
            for index in clipEditorSegments.indices {
                clipEditorSegments[index].transforms = newTransforms
            }
        }
    }

    func setActivePreviewCropRect(_ rect: CGRect?) {
        guard let clipID = activePreviewClipID else { return }
        var transforms = activePreviewTransforms
        if let rect {
            transforms.cropRect = CanvasCropMath.fittedNormalizedCropRect(
                rect,
                sourceAspect: previewSourceAspectRatio,
                canvasAspect: canvasAspectRatio
            )
        } else {
            transforms.cropRect = nil
        }
        updateTransforms(for: clipID, transforms)
    }

    func resetActivePreviewCropRect() {
        setActivePreviewCropRect(nil)
    }

    func updateAdjustments(for id: UUID?, _ newAdjustments: ColorAdjustments) {
        guard let id = id else { return }
        
        // Search in video tracks
        for (trackIndex, track) in videoTracks.enumerated() {
            if let clipIndex = track.clips.firstIndex(where: { $0.id == id }) {
                videoTracks[trackIndex].clips[clipIndex].adjustments = newAdjustments
                refreshMovieTimelinePreviewIfNeeded()
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

    func activateMovieTimelinePreview(selecting clipID: UUID? = nil) {
        previewMode = .movie
        selectedTimelineClipID = clipID
        selectedClipId = nil
        refreshMovieTimelinePreview()
    }

    func deactivateMovieTimelinePreview() {
        previewMode = .clip
        selectedTimelineClipID = nil
        moviePreviewLoadTask?.cancel()
        moviePreviewLoadTask = nil
    }

    func timelineClipVolume(for clipID: UUID) -> Double {
        if let clip = findTimelineClip(id: clipID) {
            return Double(clip.volume)
        }
        return 1.0
    }

    func timelineClipIsMuted(for clipID: UUID) -> Bool {
        findTimelineClip(id: clipID)?.isMuted ?? false
    }

    func timelineClipName(for clipID: UUID) -> String {
        findTimelineClip(id: clipID)?.mediaItem.name ?? "Clip"
    }

    func setTimelineClipVolume(_ value: Double, for clipID: UUID) {
        let clamped = Float(min(max(value, 0), 1))

        for trackIndex in videoTracks.indices {
            if let clipIndex = videoTracks[trackIndex].clips.firstIndex(where: { $0.id == clipID }) {
                videoTracks[trackIndex].clips[clipIndex].volume = clamped
                videoTracks[trackIndex].clips[clipIndex].isMuted = clamped <= 0.001
                refreshMovieTimelinePreviewIfNeeded()
                return
            }
        }

        for trackIndex in audioTracks.indices {
            if let clipIndex = audioTracks[trackIndex].clips.firstIndex(where: { $0.id == clipID }) {
                audioTracks[trackIndex].clips[clipIndex].volume = clamped
                audioTracks[trackIndex].clips[clipIndex].isMuted = clamped <= 0.001
                refreshMovieTimelinePreviewIfNeeded()
                return
            }
        }
    }

    func toggleTimelineClipMute(_ clipID: UUID) {
        for trackIndex in videoTracks.indices {
            if let clipIndex = videoTracks[trackIndex].clips.firstIndex(where: { $0.id == clipID }) {
                videoTracks[trackIndex].clips[clipIndex].isMuted.toggle()
                refreshMovieTimelinePreviewIfNeeded()
                return
            }
        }

        for trackIndex in audioTracks.indices {
            if let clipIndex = audioTracks[trackIndex].clips.firstIndex(where: { $0.id == clipID }) {
                audioTracks[trackIndex].clips[clipIndex].isMuted.toggle()
                refreshMovieTimelinePreviewIfNeeded()
                return
            }
        }
    }

    private func findTimelineClip(id: UUID) -> TimelineClip? {
        for track in videoTracks {
            if let clip = track.clips.first(where: { $0.id == id }) {
                return clip
            }
        }
        for track in audioTracks {
            if let clip = track.clips.first(where: { $0.id == id }) {
                return clip
            }
        }
        return nil
    }

    private func refreshMovieTimelinePreviewIfNeeded() {
        guard isMovieTimelinePreviewActive else { return }
        refreshMovieTimelinePreview()
    }

    private func refreshMovieTimelinePreview() {
        moviePreviewLoadTask?.cancel()

        guard hasMovieTimelineContent else {
            engine.clearCurrentItem()
            return
        }

        let videoTracksSnapshot = videoTracks
        let audioTracksSnapshot = audioTracks
        let configSnapshot = config
        let lutSnapshot = importedLUTs

        moviePreviewLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let preview = try await TimelineExporter.shared.makePreviewItem(
                    videoTracks: videoTracksSnapshot,
                    audioTracks: audioTracksSnapshot,
                    config: configSnapshot,
                    lutLibrary: lutSnapshot
                )
                guard !Task.isCancelled, self.isMovieTimelinePreviewActive else { return }
                self.engine.loadPreviewItem(preview.item, duration: preview.totalDuration.seconds)
            } catch {
                guard !Task.isCancelled else { return }
                print("Failed to build movie preview: \(error)")
            }
        }
    }
    
    @discardableResult
    func applyLUT(_ lutID: UUID, toClip clipID: UUID) -> Bool {
        guard let lut = importedLUTs.first(where: { $0.id == lutID }) else {
            return false
        }

        if let clip = findClip(id: clipID) ?? isolatedClip, clip.id == clipID,
           let alert = lutCompatibilityAlert(for: lut, clip: clip) {
            pendingAlert = alert
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
                refreshMovieTimelinePreviewIfNeeded()
                return true
            }
        }
        
        if isolatedClip?.id == clipID {
            isolatedClip?.appliedLUTID = lutID
            for index in clipEditorSegments.indices {
                clipEditorSegments[index].appliedLUTID = lutID
            }
            engine.currentLUTURL = lut.url
            refreshMovieTimelinePreviewIfNeeded()
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
        let total = clipEditorSegments.reduce(0.0) { partial, segment in
            max(partial, clipEditorTimelineStartSeconds(for: segment.id) + clipEditorSegmentDurationSeconds(segment))
        }
        return max(total, clipEditorReferenceDurationSeconds, minimumEditorSegmentDurationSeconds)
    }
    
    func clipEditorTimelineStartSeconds(for id: UUID) -> Double {
        guard let segment = clipEditorSegments.first(where: { $0.id == id }) else { return 0.0 }
        let seconds = segment.timelineStart.seconds
        return seconds.isFinite ? max(seconds, 0.0) : 0.0
    }
    
    func clipEditorSegmentDurationSeconds(_ segment: TimelineClip) -> Double {
        let duration = segment.duration.seconds
        if duration.isFinite, duration > 0 {
            return duration
        }
        return minimumEditorSegmentDurationSeconds
    }
    
    func beginClipEditorInteraction(
        id: UUID,
        mode: ClipInteractionMode,
        mouseDownX: CGFloat,
        transform: ClipEditorTimelineTransform
    ) {
        guard let index = clipEditorSegments.firstIndex(where: { $0.id == id }) else { return }
        let segment = clipEditorSegments[index]
        let timelineStart = clipEditorTimelineStartSeconds(for: id)
        let duration = clipEditorSegmentDurationSeconds(segment)
        let timelineEnd = timelineStart + duration
        let inPoint = max(segment.startTime.seconds, 0.0)
        let outPoint = inPoint + duration
        let previousClipEnd = clipEditorPreviousEnd(for: id)
        let nextClipStart = clipEditorNextStart(for: id)
        let sourceDuration = max(sourceDurationSeconds(for: segment), outPoint, minimumEditorSegmentDurationSeconds)

        activeClipEditorDragSession = ClipDragSession(
            clipID: id,
            clipIndex: index,
            mode: mode,
            snapshot: ClipInteractionSnapshot(
                initialClipStart: timelineStart,
                initialClipEnd: timelineEnd,
                initialDuration: duration,
                initialInPoint: inPoint,
                initialOutPoint: outPoint,
                initialMouseDownX: mouseDownX
            ),
            secondsPerPoint: transform.secondsPerPoint,
            minimumDuration: minimumEditorSegmentDurationSeconds,
            minimumStart: max(0.0, previousClipEnd ?? 0.0),
            maximumEnd: min(nextClipStart ?? clipEditorTotalDurationSeconds(), clipEditorTotalDurationSeconds()),
            minimumInPoint: 0.0,
            maximumOutPoint: sourceDuration
        )

        if let session = activeClipEditorDragSession {
            debugClipEditorInteraction(
                phase: "begin",
                session: session,
                deltaX: 0,
                update: ClipInteractionUpdate(
                    start: timelineStart,
                    end: timelineEnd,
                    inPoint: inPoint,
                    outPoint: outPoint
                )
            )
        }
    }

    func updateClipEditorInteraction(currentMouseX: CGFloat) {
        guard let session = activeClipEditorDragSession else { return }
        guard session.clipIndex < clipEditorSegments.count else { return }

        let deltaX = currentMouseX - session.snapshot.initialMouseDownX
        let updatedClip = ClipInteractionEngine.update(session, deltaX: deltaX)
        applyClipEditorInteractionUpdate(updatedClip, to: session.clipIndex)

        debugClipEditorInteraction(phase: "update", session: session, deltaX: deltaX, update: updatedClip)
    }

    func endClipEditorInteraction() {
        if let session = activeClipEditorDragSession, session.clipIndex < clipEditorSegments.count {
            let segment = clipEditorSegments[session.clipIndex]
            debugClipEditorInteraction(
                phase: "end",
                session: session,
                deltaX: 0,
                update: ClipInteractionUpdate(
                    start: clipEditorTimelineStartSeconds(for: segment.id),
                    end: clipEditorTimelineStartSeconds(for: segment.id) + clipEditorSegmentDurationSeconds(segment),
                    inPoint: max(segment.startTime.seconds, 0.0),
                    outPoint: max(segment.startTime.seconds, 0.0) + clipEditorSegmentDurationSeconds(segment)
                )
            )
        }
        activeClipEditorDragSession = nil
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
            let timelineStart = clipEditorTimelineStartSeconds(for: segment.id)
            let sourceStart = max(segment.startTime.seconds, 0.0)
            let duration = clipEditorSegmentDurationSeconds(segment)
            let end = timelineStart + duration
            if safeTimeline <= timelineStart || safeTimeline >= end {
                continue
            }
            
            let localSplit = safeTimeline - timelineStart
            let minDuration = minimumEditorSegmentDurationSeconds
            guard localSplit > minDuration, (duration - localSplit) > minDuration else {
                return false
            }
            
            let first = makeSegment(
                from: segment,
                startSeconds: sourceStart,
                durationSeconds: localSplit,
                timelineStartSeconds: timelineStart
            )
            let second = makeSegment(
                from: segment,
                startSeconds: sourceStart + localSplit,
                durationSeconds: duration - localSplit,
                timelineStartSeconds: timelineStart + localSplit
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
        onProgress: (@MainActor @Sendable (Double) -> Void)? = nil
    ) async throws {
        var exportConfig = config
        exportConfig.frameRate = frameRate.rawValue
        
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
    
    private func makeClipEditorRootSegment(from source: TimelineClip) -> TimelineClip {
        TimelineClip(
            mediaItem: source.mediaItem,
            startTime: source.startTime,
            duration: source.duration,
            timelineStart: .zero,
            appliedLUTID: source.appliedLUTID,
            adjustments: source.adjustments,
            transforms: source.transforms,
            volume: source.volume,
            isMuted: source.isMuted
        )
    }

    private func makeSegment(
        from source: TimelineClip,
        startSeconds: Double,
        durationSeconds: Double,
        timelineStartSeconds: Double
    ) -> TimelineClip {
        TimelineClip(
            mediaItem: source.mediaItem,
            startTime: CMTime(seconds: max(0.0, startSeconds), preferredTimescale: 600),
            duration: CMTime(seconds: max(minimumEditorSegmentDurationSeconds, durationSeconds), preferredTimescale: 600),
            timelineStart: CMTime(seconds: max(0.0, timelineStartSeconds), preferredTimescale: 600),
            appliedLUTID: source.appliedLUTID,
            adjustments: source.adjustments,
            transforms: source.transforms,
            volume: source.volume,
            isMuted: source.isMuted
        )
    }

    private func clipEditorPreviousEnd(for id: UUID) -> Double? {
        let sorted = clipEditorSegments.sorted { lhs, rhs in
            clipEditorTimelineStartSeconds(for: lhs.id) < clipEditorTimelineStartSeconds(for: rhs.id)
        }
        guard let index = sorted.firstIndex(where: { $0.id == id }), index > 0 else { return nil }
        let previous = sorted[index - 1]
        return clipEditorTimelineStartSeconds(for: previous.id) + clipEditorSegmentDurationSeconds(previous)
    }

    private func clipEditorNextStart(for id: UUID) -> Double? {
        let sorted = clipEditorSegments.sorted { lhs, rhs in
            clipEditorTimelineStartSeconds(for: lhs.id) < clipEditorTimelineStartSeconds(for: rhs.id)
        }
        guard let index = sorted.firstIndex(where: { $0.id == id }), index + 1 < sorted.count else { return nil }
        return clipEditorTimelineStartSeconds(for: sorted[index + 1].id)
    }

    private func applyClipEditorInteractionUpdate(_ update: ClipInteractionUpdate, to index: Int) {
        clipEditorSegments[index].timelineStart = CMTime(seconds: update.start, preferredTimescale: 600)
        clipEditorSegments[index].startTime = CMTime(seconds: update.inPoint, preferredTimescale: 600)
        clipEditorSegments[index].duration = CMTime(seconds: max(update.duration, minimumEditorSegmentDurationSeconds), preferredTimescale: 600)
    }

    private func debugClipEditorInteraction(
        phase: String,
        session: ClipDragSession,
        deltaX: CGFloat,
        update: ClipInteractionUpdate
    ) {
        guard clipEditorInteractionDebugLogging else { return }
        print(
            "[ClipEditor] phase=\(phase) mode=\(session.mode.rawValue) " +
            "initialStart=\(String(format: "%.3f", session.snapshot.initialClipStart)) " +
            "initialEnd=\(String(format: "%.3f", session.snapshot.initialClipEnd)) " +
            "deltaX=\(String(format: "%.2f", deltaX)) " +
            "clampedStart=\(String(format: "%.3f", update.start)) " +
            "clampedEnd=\(String(format: "%.3f", update.end))"
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

    private func replaceMediaItemReferences(with mediaItem: MediaItem) {
        let remap: (TimelineClip) -> TimelineClip = { clip in
            guard clip.mediaItem.id == mediaItem.id else { return clip }
            return TimelineClip(
                id: clip.id,
                mediaItem: mediaItem,
                startTime: clip.startTime,
                duration: clip.duration,
                timelineStart: clip.timelineStart,
                appliedLUTID: clip.appliedLUTID,
                adjustments: clip.adjustments,
                transforms: clip.transforms,
                volume: clip.volume,
                isMuted: clip.isMuted
            )
        }

        for trackIndex in videoTracks.indices {
            videoTracks[trackIndex].clips = videoTracks[trackIndex].clips.map(remap)
        }

        for trackIndex in audioTracks.indices {
            audioTracks[trackIndex].clips = audioTracks[trackIndex].clips.map(remap)
        }

        if let isolatedClip, isolatedClip.mediaItem.id == mediaItem.id {
            self.isolatedClip = remap(isolatedClip)
        }

        clipEditorSegments = clipEditorSegments.map(remap)

        if previewMode == .clip,
           isolatedClip == nil,
           let selectedClipId,
           let selectedClip = findClip(id: selectedClipId) {
            _ = selectedClip
        }
    }
    
    private func shouldReplaceClipDuration(_ duration: CMTime) -> Bool {
        guard duration.isNumeric else { return true }
        let seconds = duration.seconds
        guard seconds.isFinite, seconds > 0 else { return true }
        return abs(seconds - fallbackClipDurationSeconds) < 0.001
    }
    
    private nonisolated static func loadMediaMetadata(
        for url: URL,
        type: MediaItem.MediaType
    ) async -> (durationSeconds: Double?, signalSpace: SignalSpace?) {
        let durationSeconds = await loadMediaDurationSeconds(for: url, type: type)
        return (durationSeconds, nil)
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

    private func resetEditorState() {
        stopAccessingProjectAssets()
        moviePreviewLoadTask?.cancel()
        moviePreviewLoadTask = nil
        config = ProjectConfig()
        mediaLibrary = []
        importedLUTs = []
        mediaAccessBookmarks = [:]
        lutAccessBookmarks = [:]
        videoTracks = [TimelineTrack(name: "V1", clips: [])]
        audioTracks = [TimelineTrack(name: "A1", clips: [], isAudioOnly: true)]
        selectedClipId = nil
        selectedMediaLibraryItemId = nil
        selectedTimelineClipID = nil
        previewMode = .clip
        clipEditorSegments = []
        clipEditorReferenceDurationSeconds = 0
        clipEditorSplitModeEnabled = false
        clipEditorTrimModeEnabled = false
        activeClipEditorDragSession = nil
        isolatedClip = nil
        pendingAlert = nil
        exportFormat = .mp4
        exportQuality = .medium
        exportFrameRate = .fps30
        engine.pause()
        engine.clearCurrentItem()
    }

    private func refreshLibraryMetadata() {
        for item in mediaLibrary {
            guard let url = item.url else { continue }
            let itemID = item.id
            let itemType = item.type
            Task.detached(priority: .utility) { [weak self] in
                guard let self else { return }
                let metadata = await Self.loadMediaMetadata(for: url, type: itemType)

                await MainActor.run {
                    guard let idx = self.mediaLibrary.firstIndex(where: { $0.id == itemID }) else { return }
                    if let durationSeconds = metadata.durationSeconds {
                        self.mediaLibrary[idx].durationSeconds = durationSeconds
                        self.refreshClipDurations(for: itemID, loadedDurationSeconds: durationSeconds)
                    }
                    self.replaceMediaItemReferences(with: self.mediaLibrary[idx])
                }
            }
        }
    }

    private func restoreProjectAssetAccess() {
        stopAccessingProjectAssets()

        for index in mediaLibrary.indices {
            let restored = restoredURL(
                fallbackURL: mediaLibrary[index].url,
                bookmarkData: mediaAccessBookmarks[mediaLibrary[index].id]
            )
            mediaLibrary[index].url = restored.url
            if let bookmarkData = restored.bookmarkData {
                mediaAccessBookmarks[mediaLibrary[index].id] = bookmarkData
            }
        }

        for index in importedLUTs.indices {
            let restored = restoredURL(
                fallbackURL: importedLUTs[index].url,
                bookmarkData: lutAccessBookmarks[importedLUTs[index].id]
            )
            importedLUTs[index].url = restored.url ?? importedLUTs[index].url.standardizedFileURL
            if let bookmarkData = restored.bookmarkData {
                lutAccessBookmarks[importedLUTs[index].id] = bookmarkData
            }
        }
    }

    private func refreshImportedLUTDescriptors() {
        for index in importedLUTs.indices {
            importedLUTs[index].descriptor = ImportedLUTManager.shared.descriptor(for: importedLUTs[index].url)
        }
    }

    private func ensureProjectAssetBookmarks() {
        for item in mediaLibrary {
            guard let url = item.url else { continue }
            if let bookmark = Self.makeSecurityScopedBookmark(for: url) {
                mediaAccessBookmarks[item.id] = bookmark
            }
        }

        for item in importedLUTs {
            if let bookmark = Self.makeSecurityScopedBookmark(for: item.url) {
                lutAccessBookmarks[item.id] = bookmark
            }
        }
    }

    private func reconcileProjectAssetReferences() {
        let mediaByID = Dictionary(uniqueKeysWithValues: mediaLibrary.map { ($0.id, $0) })
        let lutIDs = Set(importedLUTs.map(\.id))

        videoTracks = videoTracks.map { track in
            canonicalizedTrack(track, mediaByID: mediaByID, validLUTIDs: lutIDs)
        }
        audioTracks = audioTracks.map { track in
            canonicalizedTrack(track, mediaByID: mediaByID, validLUTIDs: lutIDs)
        }

        if let isolatedClip {
            self.isolatedClip = canonicalizedClip(isolatedClip, mediaByID: mediaByID, validLUTIDs: lutIDs)
        }

        clipEditorSegments = clipEditorSegments.map { clip in
            canonicalizedClip(clip, mediaByID: mediaByID, validLUTIDs: lutIDs)
        }
    }

    private func canonicalizedTrack(
        _ track: TimelineTrack,
        mediaByID: [UUID: MediaItem],
        validLUTIDs: Set<UUID>
    ) -> TimelineTrack {
        var track = track
        track.clips = track.clips.map { clip in
            canonicalizedClip(clip, mediaByID: mediaByID, validLUTIDs: validLUTIDs)
        }
        return track
    }

    private func canonicalizedClip(
        _ clip: TimelineClip,
        mediaByID: [UUID: MediaItem],
        validLUTIDs: Set<UUID>
    ) -> TimelineClip {
        let mediaItem = mediaByID[clip.mediaItem.id] ?? clip.mediaItem
        let lutID = clip.appliedLUTID.flatMap { validLUTIDs.contains($0) ? $0 : nil }
        return TimelineClip(
            id: clip.id,
            mediaItem: mediaItem,
            startTime: clip.startTime,
            duration: clip.duration,
            timelineStart: clip.timelineStart,
            appliedLUTID: lutID,
            adjustments: clip.adjustments,
            transforms: clip.transforms,
            volume: clip.volume,
            isMuted: clip.isMuted
        )
    }

    private func restoredURL(
        fallbackURL: URL?,
        bookmarkData: Data?
    ) -> (url: URL?, bookmarkData: Data?) {
        let normalizedFallbackURL = fallbackURL?.standardizedFileURL

        if let bookmarkData {
            var isStale = false
            if let resolvedURL = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ).standardizedFileURL {
                let startedAccess = resolvedURL.startAccessingSecurityScopedResource()
                if startedAccess {
                    activeSecurityScopedURLs.insert(resolvedURL)
                }
                if Self.canAccessFile(at: resolvedURL) {
                    if isStale {
                        return (resolvedURL, Self.makeSecurityScopedBookmark(for: resolvedURL) ?? bookmarkData)
                    }
                    return (resolvedURL, bookmarkData)
                }
            }
        }

        guard let normalizedFallbackURL else { return (nil, bookmarkData) }
        if let bookmark = Self.makeSecurityScopedBookmark(for: normalizedFallbackURL) {
            var isStale = false
            if let resolvedURL = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ).standardizedFileURL {
                let startedAccess = resolvedURL.startAccessingSecurityScopedResource()
                if startedAccess {
                    activeSecurityScopedURLs.insert(resolvedURL)
                }
                if Self.canAccessFile(at: resolvedURL) {
                    if isStale {
                        return (resolvedURL, Self.makeSecurityScopedBookmark(for: resolvedURL) ?? bookmark)
                    }
                    return (resolvedURL, bookmark)
                }
            }
        }

        return (normalizedFallbackURL, bookmarkData)
    }

    private func stopAccessingProjectAssets() {
        for url in activeSecurityScopedURLs {
            url.stopAccessingSecurityScopedResource()
        }
        activeSecurityScopedURLs.removeAll()
    }

    private nonisolated static func makeSecurityScopedBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private nonisolated static func canAccessFile(at url: URL) -> Bool {
        let normalizedURL = url.standardizedFileURL
        return FileManager.default.isReadableFile(atPath: normalizedURL.path)
    }

    private func existingURL(for url: URL?) -> URL? {
        guard let url else { return nil }
        let normalizedURL = url.standardizedFileURL
        return Self.canAccessFile(at: normalizedURL) ? normalizedURL : nil
    }

    private func lutCompatibilityAlert(for lut: LUTItem, clip: TimelineClip) -> WorkspaceAlert? {
        _ = lut
        _ = clip
        return nil
    }

    private func removeTimelineClips(where shouldRemove: (TimelineClip) -> Bool) {
        for index in videoTracks.indices {
            videoTracks[index].clips.removeAll(where: shouldRemove)
        }
        for index in audioTracks.indices {
            audioTracks[index].clips.removeAll(where: shouldRemove)
        }
        refreshMovieTimelinePreviewIfNeeded()
    }

    private func syncSelectionAfterTimelineMutation() {
        if let selectedClipId, findClip(id: selectedClipId) == nil {
            self.selectedClipId = nil
            if isolatedClip == nil && !isMovieTimelinePreviewActive {
                engine.clearCurrentItem()
            }
        }

        if let selectedTimelineClipID, findTimelineClip(id: selectedTimelineClipID) == nil {
            self.selectedTimelineClipID = nil
        }

        if isMovieTimelinePreviewActive {
            refreshMovieTimelinePreview()
        }
    }
}
