import Foundation
import CoreMedia
import CoreGraphics

enum CanvasOrientation: String, CaseIterable {
    case landscape
    case portrait

    var aspectRatio: CGFloat {
        switch self {
        case .landscape:
            return 16.0 / 9.0
        case .portrait:
            return 9.0 / 16.0
        }
    }

    var previewSymbolName: String {
        switch self {
        case .landscape:
            return "rectangle"
        case .portrait:
            return "rectangle.portrait"
        }
    }

    func applied(to size: CGSize) -> CGSize {
        switch self {
        case .landscape:
            return size.width >= size.height ? size : CGSize(width: size.height, height: size.width)
        case .portrait:
            return size.height >= size.width ? size : CGSize(width: size.height, height: size.width)
        }
    }
}

struct TimelineClip: Identifiable {
    let id: UUID = UUID()
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
}

struct TimelineTrack: Identifiable {
    let id: UUID = UUID()
    var name: String
    var clips: [TimelineClip]
    var isAudioOnly: Bool = false
}

struct ProjectConfig {
    var resolution: CGSize = CGSize(width: 1920, height: 1080)
    var frameRate: Int = 30
    var canvasOrientation: CanvasOrientation = .landscape
}
