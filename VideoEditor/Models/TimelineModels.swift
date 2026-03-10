import Foundation
import CoreMedia
import CoreGraphics

enum CanvasOrientation: String, CaseIterable, Codable, Identifiable {
    case landscape
    case portrait
    case cinema

    var id: String { rawValue }

    var aspectRatio: CGFloat {
        switch self {
        case .landscape:
            return 16.0 / 9.0
        case .portrait:
            return 9.0 / 16.0
        case .cinema:
            return 21.0 / 9.0
        }
    }

    var previewSymbolName: String {
        switch self {
        case .landscape:
            return "rectangle"
        case .portrait:
            return "rectangle.portrait"
        case .cinema:
            return "film"
        }
    }

    var displayName: String {
        switch self {
        case .landscape:
            return "Landscape 16:9"
        case .portrait:
            return "Portrait 9:16"
        case .cinema:
            return "Cinema 21:9"
        }
    }

    var shortLabel: String {
        switch self {
        case .landscape:
            return "16:9"
        case .portrait:
            return "9:16"
        case .cinema:
            return "21:9"
        }
    }

    func applied(to size: CGSize) -> CGSize {
        let baseWidth = max(size.width, size.height)
        switch self {
        case .landscape:
            return CGSize(width: baseWidth, height: roundedEven(baseWidth / aspectRatio))
        case .portrait:
            let height = baseWidth
            return CGSize(width: roundedEven(height * aspectRatio), height: height)
        case .cinema:
            return CGSize(width: baseWidth, height: roundedEven(baseWidth / aspectRatio))
        }
    }

    private func roundedEven(_ value: CGFloat) -> CGFloat {
        let rounded = Int(value.rounded())
        let even = rounded % 2 == 0 ? rounded : rounded + 1
        return CGFloat(max(even, 2))
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = CanvasOrientation(rawValue: rawValue) ?? .landscape
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum ProjectResolutionPreset: String, CaseIterable, Codable, Identifiable {
    case fullHD
    case uhd4k

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fullHD:
            return "1080p"
        case .uhd4k:
            return "4K"
        }
    }

    var pixelLabel: String {
        let size = baseLandscapeSize
        return "\(Int(size.width))x\(Int(size.height))"
    }

    var baseLandscapeSize: CGSize {
        switch self {
        case .fullHD:
            return CGSize(width: 1920, height: 1080)
        case .uhd4k:
            return CGSize(width: 3840, height: 2160)
        }
    }

    var fullLabel: String {
        "\(displayName) (\(pixelLabel))"
    }

    static func closest(to size: CGSize, orientation: CanvasOrientation) -> ProjectResolutionPreset {
        let normalized = orientation == .portrait
            ? CGSize(width: max(size.width, size.height), height: min(size.width, size.height))
            : CGSize(width: max(size.width, size.height), height: min(size.width, size.height))

        let presets = ProjectResolutionPreset.allCases
        return presets.min { lhs, rhs in
            let lhsDistance = abs(lhs.baseLandscapeSize.width - normalized.width) + abs(lhs.baseLandscapeSize.height - normalized.height)
            let rhsDistance = abs(rhs.baseLandscapeSize.width - normalized.width) + abs(rhs.baseLandscapeSize.height - normalized.height)
            return lhsDistance < rhsDistance
        } ?? .fullHD
    }
}

struct TimelineClip: Identifiable, Codable {
    var id: UUID = UUID()
    let mediaItem: MediaItem
    var startTime: CMTime
    var duration: CMTime
    var timelineStart: CMTime = .zero
    var appliedLUTID: UUID? = nil
    
    // Custom adjustments for this specific clip
    var adjustments: ColorAdjustments = ColorAdjustments()
    var transforms: Transforms = Transforms()
    
    // Volume control for this clip if audio is present
    var volume: Float = 1.0
    var isMuted: Bool = false

    init(
        id: UUID = UUID(),
        mediaItem: MediaItem,
        startTime: CMTime,
        duration: CMTime,
        timelineStart: CMTime = .zero,
        appliedLUTID: UUID? = nil,
        adjustments: ColorAdjustments = ColorAdjustments(),
        transforms: Transforms = Transforms(),
        volume: Float = 1.0,
        isMuted: Bool = false
    ) {
        self.id = id
        self.mediaItem = mediaItem
        self.startTime = startTime
        self.duration = duration
        self.timelineStart = timelineStart
        self.appliedLUTID = appliedLUTID
        self.adjustments = adjustments
        self.transforms = transforms
        self.volume = volume
        self.isMuted = isMuted
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case mediaItem
        case startTimeSeconds
        case durationSeconds
        case timelineStartSeconds
        case appliedLUTID
        case adjustments
        case transforms
        case volume
        case isMuted
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        mediaItem = try container.decode(MediaItem.self, forKey: .mediaItem)
        startTime = CMTime(seconds: try container.decode(Double.self, forKey: .startTimeSeconds), preferredTimescale: 600)
        duration = CMTime(seconds: try container.decode(Double.self, forKey: .durationSeconds), preferredTimescale: 600)
        timelineStart = CMTime(seconds: try container.decode(Double.self, forKey: .timelineStartSeconds), preferredTimescale: 600)
        appliedLUTID = try container.decodeIfPresent(UUID.self, forKey: .appliedLUTID)
        adjustments = try container.decode(ColorAdjustments.self, forKey: .adjustments)
        transforms = try container.decode(Transforms.self, forKey: .transforms)
        volume = try container.decode(Float.self, forKey: .volume)
        isMuted = try container.decode(Bool.self, forKey: .isMuted)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(mediaItem, forKey: .mediaItem)
        try container.encode(startTime.seconds, forKey: .startTimeSeconds)
        try container.encode(duration.seconds, forKey: .durationSeconds)
        try container.encode(timelineStart.seconds, forKey: .timelineStartSeconds)
        try container.encodeIfPresent(appliedLUTID, forKey: .appliedLUTID)
        try container.encode(adjustments, forKey: .adjustments)
        try container.encode(transforms, forKey: .transforms)
        try container.encode(volume, forKey: .volume)
        try container.encode(isMuted, forKey: .isMuted)
    }
}

struct TimelineTrack: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String
    var clips: [TimelineClip]
    var isAudioOnly: Bool = false
}

struct ProjectConfig: Codable {
    var resolutionPreset: ProjectResolutionPreset = .fullHD
    var frameRate: Int = 30
    var canvasOrientation: CanvasOrientation = .landscape

    var resolution: CGSize {
        canvasOrientation.applied(to: resolutionPreset.baseLandscapeSize)
    }

    private enum CodingKeys: String, CodingKey {
        case resolutionPreset
        case frameRate
        case canvasOrientation
        case resolution
        case orientation
    }

    init(
        resolutionPreset: ProjectResolutionPreset = .fullHD,
        frameRate: Int = 30,
        canvasOrientation: CanvasOrientation = .landscape
    ) {
        self.resolutionPreset = resolutionPreset
        self.frameRate = frameRate
        self.canvasOrientation = canvasOrientation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        frameRate = try container.decodeIfPresent(Int.self, forKey: .frameRate) ?? 30
        let explicitOrientation = try container.decodeIfPresent(CanvasOrientation.self, forKey: .canvasOrientation)
        let legacyOrientation = try container.decodeIfPresent(CanvasOrientation.self, forKey: .orientation)
        canvasOrientation = explicitOrientation ?? legacyOrientation ?? .landscape

        if let preset = try container.decodeIfPresent(ProjectResolutionPreset.self, forKey: .resolutionPreset) {
            resolutionPreset = preset
        } else if let legacyResolution = try container.decodeIfPresent(CGSize.self, forKey: .resolution) {
            resolutionPreset = ProjectResolutionPreset.closest(to: legacyResolution, orientation: canvasOrientation)
        } else {
            resolutionPreset = .fullHD
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(resolutionPreset, forKey: .resolutionPreset)
        try container.encode(frameRate, forKey: .frameRate)
        try container.encode(canvasOrientation, forKey: .canvasOrientation)
    }
}
