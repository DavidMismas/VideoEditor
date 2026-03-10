import Foundation
import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import CoreGraphics
import Observation

nonisolated private final class AdjustmentSnapshotStore: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ProcessingSnapshot()
    
    func set(_ newValue: ProcessingSnapshot) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
    
    func get() -> ProcessingSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

nonisolated private struct ProcessingSnapshot {
    var adjustments: ColorAdjustments = ColorAdjustments()
    var lutURL: URL? = nil
}

@Observable
class VideoPlaybackEngine {
    private enum PreviewRenderMode {
        case clipSource
        case passthroughPlayerItem
    }

    var player: AVPlayer = AVPlayer()
    var currentTime: Double = 0
    var duration: Double = 0
    var isPlaying: Bool = false
    var presentationSize: CGSize = .zero
    
    private var timeObserverToken: Any?
    private let adjustmentsStore = AdjustmentSnapshotStore()
    private let previewStateLock = NSLock()
    private var videoOutput: AVPlayerItemVideoOutput?
    private var previewRenderMode: PreviewRenderMode = .clipSource
    private var previewRevision: Int = 0
    private var lastRenderedRevision: Int = -1
    private var lastRenderedImage: CGImage?
    private var lastRenderedItemTime: CMTime = .invalid
    private var lastPixelBuffer: CVPixelBuffer?
    private let displayColorSpace = CGColorSpace(name: CGColorSpace.sRGB)
    
    // We store the current adjustments to apply during playback
    var currentAdjustments: ColorAdjustments = ColorAdjustments() {
        didSet {
            updateSnapshotStore()
            invalidatePreviewCache()
        }
    }
    
    var currentLUTURL: URL? {
        didSet {
            updateSnapshotStore()
            invalidatePreviewCache()
        }
    }

    init() {
        attachTimeObserver()
    }
    
    deinit {
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
        }
    }
    
    func loadMedia(from url: URL) {
        let asset = AVURLAsset(url: url)
        
        Task {
            do {
                let isPlayable = try await asset.load(.isPlayable)
                guard isPlayable else { return }
                let mediaDuration = try await asset.load(.duration)
                let durationSeconds = max(mediaDuration.seconds, 0)
                
                let item = AVPlayerItem(asset: asset)
                self.attachVideoOutput(to: item, renderMode: .clipSource)
                self.player.replaceCurrentItem(with: item)
                self.duration = durationSeconds
                self.currentTime = 0
                self.isPlaying = false
                self.presentationSize = item.presentationSize
                await self.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            } catch {
                print("Failed to load asset: \(error)")
            }
        }
    }

    func loadPreviewItem(_ item: AVPlayerItem, duration: Double? = nil) {
        attachVideoOutput(to: item, renderMode: .passthroughPlayerItem)
        player.replaceCurrentItem(with: item)
        self.duration = max(duration ?? item.duration.seconds, 0)
        currentTime = 0
        isPlaying = false
        presentationSize = item.presentationSize
        Task {
            await player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    func togglePlayPause() {
        if player.isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }
    
    func pause() {
        player.pause()
        isPlaying = false
    }

    func clearCurrentItem() {
        pause()

        if let currentItem = player.currentItem,
           let videoOutput {
            currentItem.remove(videoOutput)
        }

        previewStateLock.lock()
        self.videoOutput = nil
        previewRenderMode = .clipSource
        lastRenderedImage = nil
        lastRenderedItemTime = .invalid
        lastPixelBuffer = nil
        previewRevision &+= 1
        lastRenderedRevision = -1
        previewStateLock.unlock()

        player.replaceCurrentItem(with: nil)
        currentTime = 0
        duration = 0
        presentationSize = .zero
    }

    func copyPreviewImage(forHostTime hostTime: CFTimeInterval) -> CGImage? {
        let output: AVPlayerItemVideoOutput?
        let renderMode: PreviewRenderMode
        let revision: Int
        let cachedImage: CGImage?
        let cachedRevision: Int
        let cachedItemTime: CMTime
        let cachedPixelBuffer: CVPixelBuffer?

        previewStateLock.lock()
        output = videoOutput
        renderMode = previewRenderMode
        revision = previewRevision
        cachedImage = lastRenderedImage
        cachedRevision = lastRenderedRevision
        cachedItemTime = lastRenderedItemTime
        cachedPixelBuffer = lastPixelBuffer
        previewStateLock.unlock()

        guard let output else { return cachedImage }

        let requestedItemTime = output.itemTime(forHostTime: hostTime)
        var pixelBuffer: CVPixelBuffer?
        var renderItemTime = requestedItemTime

        if output.hasNewPixelBuffer(forItemTime: requestedItemTime) {
            pixelBuffer = output.copyPixelBuffer(forItemTime: requestedItemTime, itemTimeForDisplay: &renderItemTime)
        } else {
            pixelBuffer = cachedPixelBuffer
            renderItemTime = cachedItemTime
        }

        if !player.isPlaying,
           revision == cachedRevision,
           let cachedImage {
            return cachedImage
        }

        guard let pixelBuffer else {
            return cachedImage
        }

        let sourceImage = CIImage(
            cvPixelBuffer: pixelBuffer,
            options: [.colorSpace: NSNull()]
        )

        let processor = CoreImageProcessor.shared
        let outputImage: CIImage
        let renderContext: CIContext

        switch renderMode {
        case .clipSource:
            let snapshot = adjustmentsStore.get()
            outputImage = processor.applyAdjustments(
                snapshot.adjustments,
                lutURL: snapshot.lutURL,
                timeSeconds: renderItemTime.isNumeric ? renderItemTime.seconds : nil,
                renderQuality: .preview,
                to: sourceImage
            )
            renderContext = processor.renderContext(for: snapshot.adjustments)
        case .passthroughPlayerItem:
            outputImage = sourceImage
            renderContext = processor.renderContext(workingSpace: .linearSRGB, outputSpace: .rec709)
        }

        guard let renderedImage = renderContext.createCGImage(
            outputImage,
            from: outputImage.extent,
            format: .RGBA8,
            colorSpace: displayColorSpace
        ) else {
            return cachedImage
        }

        previewStateLock.lock()
        lastPixelBuffer = pixelBuffer
        lastRenderedImage = renderedImage
        lastRenderedItemTime = renderItemTime
        lastRenderedRevision = revision
        previewStateLock.unlock()

        return renderedImage
    }
    
    func seek(to seconds: Double, shouldPause: Bool = true) {
        guard player.currentItem != nil else { return }
        let safeDuration = max(duration, 0)
        let clampedTime = min(max(seconds, 0), safeDuration)
        let time = CMTime(seconds: clampedTime, preferredTimescale: 600)
        
        if shouldPause {
            player.pause()
            isPlaying = false
        }
        
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = clampedTime
    }
    
    private func attachTimeObserver() {
        let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            if time.isNumeric {
                self.currentTime = max(0, time.seconds)
            }
            self.isPlaying = self.player.isPlaying
            
            if let currentItem = self.player.currentItem, currentItem.duration.isNumeric {
                self.duration = max(currentItem.duration.seconds, 0)
                self.presentationSize = currentItem.presentationSize
            }
        }
    }
    
    private func updateSnapshotStore() {
        adjustmentsStore.set(
            ProcessingSnapshot(
                adjustments: currentAdjustments,
                lutURL: currentLUTURL
            )
        )
    }

    private func invalidatePreviewCache() {
        previewStateLock.lock()
        previewRevision &+= 1
        lastRenderedRevision = -1
        lastRenderedImage = nil
        previewStateLock.unlock()
    }

    private func attachVideoOutput(to item: AVPlayerItem, renderMode: PreviewRenderMode) {
        if let currentItem = player.currentItem,
           let videoOutput {
            currentItem.remove(videoOutput)
        }

        let output = AVPlayerItemVideoOutput(
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_64RGBAHalf),
                AVVideoAllowWideColorKey: true
            ]
        )
        output.suppressesPlayerRendering = true
        item.add(output)

        previewStateLock.lock()
        videoOutput = output
        previewRenderMode = renderMode
        previewRevision &+= 1
        lastRenderedRevision = -1
        lastRenderedImage = nil
        lastRenderedItemTime = .invalid
        lastPixelBuffer = nil
        previewStateLock.unlock()
    }

}

extension AVPlayer {
    var isPlaying: Bool {
        return rate != 0 && error == nil
    }
}
