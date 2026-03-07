import SwiftUI

enum ClipInteractionMode: String {
    case trimLeft
    case trimRight
    case move
}

struct ClipEditorTimelineTransform {
    let contentWidth: CGFloat
    let timelineDuration: Double
    let horizontalPadding: CGFloat

    private var safeWidth: CGFloat {
        max(contentWidth, 1)
    }

    private var safeDuration: Double {
        max(timelineDuration, 0.10)
    }

    var secondsPerPoint: Double {
        safeDuration / Double(safeWidth)
    }

    func screenXToTimelineX(_ screenX: CGFloat) -> CGFloat {
        let timelineX = screenX - horizontalPadding
        return max(0, min(timelineX, safeWidth))
    }

    func timeToScreenX(_ time: Double) -> CGFloat {
        horizontalPadding + (CGFloat(max(time, 0)) * safeWidth / CGFloat(safeDuration))
    }

    func timeToWidth(_ time: Double) -> CGFloat {
        CGFloat(max(time, 0)) * safeWidth / CGFloat(safeDuration)
    }
}

struct ClipInteractionSnapshot {
    let initialClipStart: Double
    let initialClipEnd: Double
    let initialDuration: Double
    let initialInPoint: Double
    let initialOutPoint: Double
    let initialMouseDownX: CGFloat
}

struct ClipDragSession {
    let clipID: UUID
    let clipIndex: Int
    let mode: ClipInteractionMode
    let snapshot: ClipInteractionSnapshot
    let secondsPerPoint: Double
    let minimumDuration: Double
    let minimumStart: Double
    let maximumEnd: Double
    let minimumInPoint: Double
    let maximumOutPoint: Double
}

struct ClipInteractionUpdate {
    let start: Double
    let end: Double
    let inPoint: Double
    let outPoint: Double

    var duration: Double {
        end - start
    }
}

enum ClipInteractionEngine {
    static func update(_ session: ClipDragSession, deltaX: CGFloat) -> ClipInteractionUpdate {
        let deltaTime = Double(deltaX) * session.secondsPerPoint

        switch session.mode {
        case .trimLeft:
            return trimLeft(session: session, deltaTime: deltaTime)
        case .trimRight:
            return trimRight(session: session, deltaTime: deltaTime)
        case .move:
            return move(session: session, deltaTime: deltaTime)
        }
    }

    private static func trimLeft(session: ClipDragSession, deltaTime: Double) -> ClipInteractionUpdate {
        let snapshot = session.snapshot
        let minimumStartFromDuration = snapshot.initialClipEnd - session.minimumDuration
        let minimumStartFromInPoint = snapshot.initialClipStart - (snapshot.initialInPoint - session.minimumInPoint)
        let minimumAllowedStart = max(session.minimumStart, minimumStartFromInPoint)
        let maximumAllowedStart = min(snapshot.initialClipEnd, minimumStartFromDuration)
        let proposedStart = snapshot.initialClipStart + deltaTime
        let start = clamp(proposedStart, min: minimumAllowedStart, max: maximumAllowedStart)
        let inPoint = snapshot.initialInPoint + (start - snapshot.initialClipStart)

        return ClipInteractionUpdate(
            start: start,
            end: snapshot.initialClipEnd,
            inPoint: inPoint,
            outPoint: snapshot.initialOutPoint
        )
    }

    private static func trimRight(session: ClipDragSession, deltaTime: Double) -> ClipInteractionUpdate {
        let snapshot = session.snapshot
        let minimumEndFromDuration = snapshot.initialClipStart + session.minimumDuration
        let maximumEndFromOutPoint = snapshot.initialClipEnd + (session.maximumOutPoint - snapshot.initialOutPoint)
        let maximumAllowedEnd = min(session.maximumEnd, maximumEndFromOutPoint)
        let proposedEnd = snapshot.initialClipEnd + deltaTime
        let end = clamp(proposedEnd, min: minimumEndFromDuration, max: maximumAllowedEnd)
        let outPoint = snapshot.initialOutPoint + (end - snapshot.initialClipEnd)

        return ClipInteractionUpdate(
            start: snapshot.initialClipStart,
            end: end,
            inPoint: snapshot.initialInPoint,
            outPoint: outPoint
        )
    }

    private static func move(session: ClipDragSession, deltaTime: Double) -> ClipInteractionUpdate {
        let snapshot = session.snapshot
        let startDeltaLowerBound = session.minimumStart - snapshot.initialClipStart
        let startDeltaUpperBound = session.maximumEnd - snapshot.initialClipEnd
        let clampedDelta = clamp(deltaTime, min: startDeltaLowerBound, max: startDeltaUpperBound)

        return ClipInteractionUpdate(
            start: snapshot.initialClipStart + clampedDelta,
            end: snapshot.initialClipEnd + clampedDelta,
            inPoint: snapshot.initialInPoint,
            outPoint: snapshot.initialOutPoint
        )
    }

    private static func clamp(_ value: Double, min lower: Double, max upper: Double) -> Double {
        Swift.max(lower, Swift.min(upper, value))
    }
}
