import Foundation
import CoreMedia

struct TimelineClip: Identifiable {
    let id: UUID = UUID()
    let mediaItem: MediaItem
    var startTime: CMTime
    var duration: CMTime
    
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
}
