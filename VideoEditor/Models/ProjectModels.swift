import Foundation
import UniformTypeIdentifiers

struct SavedProjectState: Codable {
    var version: Int = 2
    var name: String
    var config: ProjectConfig
    var mediaLibrary: [MediaItem]
    var importedLUTs: [LUTItem]
    var videoTracks: [TimelineTrack]
    var audioTracks: [TimelineTrack]
    var exportFormat: ExportFormat
    var exportQuality: ExportQuality
    var exportFrameRate: ExportFrameRate
    var mediaAccessBookmarks: [SavedSecurityScopedBookmark] = []
    var lutAccessBookmarks: [SavedSecurityScopedBookmark] = []

    private enum CodingKeys: String, CodingKey {
        case version
        case name
        case projectName
        case config
        case mediaLibrary
        case importedLUTs
        case videoTracks
        case audioTracks
        case exportFormat
        case exportQuality
        case exportFrameRate
        case mediaAccessBookmarks
        case lutAccessBookmarks
    }

    init(
        version: Int = 2,
        name: String,
        config: ProjectConfig,
        mediaLibrary: [MediaItem],
        importedLUTs: [LUTItem],
        videoTracks: [TimelineTrack],
        audioTracks: [TimelineTrack],
        exportFormat: ExportFormat,
        exportQuality: ExportQuality,
        exportFrameRate: ExportFrameRate,
        mediaAccessBookmarks: [SavedSecurityScopedBookmark] = [],
        lutAccessBookmarks: [SavedSecurityScopedBookmark] = []
    ) {
        self.version = version
        self.name = name
        self.config = config
        self.mediaLibrary = mediaLibrary
        self.importedLUTs = importedLUTs
        self.videoTracks = videoTracks
        self.audioTracks = audioTracks
        self.exportFormat = exportFormat
        self.exportQuality = exportQuality
        self.exportFrameRate = exportFrameRate
        self.mediaAccessBookmarks = mediaAccessBookmarks
        self.lutAccessBookmarks = lutAccessBookmarks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        let explicitName = try container.decodeIfPresent(String.self, forKey: .name)
        let legacyProjectName = try container.decodeIfPresent(String.self, forKey: .projectName)
        name = explicitName ?? legacyProjectName ?? "Untitled Project"
        config = try container.decodeIfPresent(ProjectConfig.self, forKey: .config) ?? ProjectConfig()
        mediaLibrary = try container.decodeIfPresent([MediaItem].self, forKey: .mediaLibrary) ?? []
        importedLUTs = try container.decodeIfPresent([LUTItem].self, forKey: .importedLUTs) ?? []
        videoTracks = try container.decodeIfPresent([TimelineTrack].self, forKey: .videoTracks) ?? []
        audioTracks = try container.decodeIfPresent([TimelineTrack].self, forKey: .audioTracks) ?? []
        exportFormat = try container.decodeIfPresent(ExportFormat.self, forKey: .exportFormat) ?? .mp4
        exportQuality = try container.decodeIfPresent(ExportQuality.self, forKey: .exportQuality) ?? .medium
        exportFrameRate = try container.decodeIfPresent(ExportFrameRate.self, forKey: .exportFrameRate) ?? .fps30
        mediaAccessBookmarks = try container.decodeIfPresent([SavedSecurityScopedBookmark].self, forKey: .mediaAccessBookmarks) ?? []
        lutAccessBookmarks = try container.decodeIfPresent([SavedSecurityScopedBookmark].self, forKey: .lutAccessBookmarks) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(name, forKey: .name)
        try container.encode(config, forKey: .config)
        try container.encode(mediaLibrary, forKey: .mediaLibrary)
        try container.encode(importedLUTs, forKey: .importedLUTs)
        try container.encode(videoTracks, forKey: .videoTracks)
        try container.encode(audioTracks, forKey: .audioTracks)
        try container.encode(exportFormat, forKey: .exportFormat)
        try container.encode(exportQuality, forKey: .exportQuality)
        try container.encode(exportFrameRate, forKey: .exportFrameRate)
        try container.encode(mediaAccessBookmarks, forKey: .mediaAccessBookmarks)
        try container.encode(lutAccessBookmarks, forKey: .lutAccessBookmarks)
    }
}

struct SavedSecurityScopedBookmark: Codable {
    var id: UUID
    var bookmarkData: Data
}

enum ProjectPersistenceError: LocalizedError {
    case invalidProjectName
    case noProjectLoaded
    case unsupportedProjectVersion(Int)

    var errorDescription: String? {
        switch self {
        case .invalidProjectName:
            return "Project name cannot be empty."
        case .noProjectLoaded:
            return "No project is currently open."
        case .unsupportedProjectVersion(let version):
            return "This project file uses unsupported version \(version)."
        }
    }
}

enum ProjectFileFormat {
    static let fileExtension = "veproj"

    static var contentType: UTType {
        UTType(filenameExtension: fileExtension) ?? .json
    }
}

enum ProjectFileStore {
    static func load(from url: URL) throws -> SavedProjectState {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        let project = try decoder.decode(SavedProjectState.self, from: data)
        guard [1, 2].contains(project.version) else {
            throw ProjectPersistenceError.unsupportedProjectVersion(project.version)
        }
        return project
    }

    static func save(_ project: SavedProjectState, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(project)
        try data.write(to: url, options: .atomic)
    }
}
