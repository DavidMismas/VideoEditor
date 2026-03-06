import Foundation
import AVFoundation
import CoreImage
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
    var player: AVPlayer = AVPlayer()
    var currentTime: Double = 0
    var duration: Double = 0
    
    // Custom video compositor reference
    private var videoComposition: AVVideoComposition?
    private var timeObserverToken: Any?
    private let adjustmentsStore = AdjustmentSnapshotStore()
    
    // We store the current adjustments to apply during playback
    var currentAdjustments: ColorAdjustments = ColorAdjustments() {
        didSet {
            updateSnapshotStore()
            refreshCurrentFrameIfNeeded()
        }
    }
    
    var currentLUTURL: URL? {
        didSet {
            updateSnapshotStore()
            refreshCurrentFrameIfNeeded()
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
                let composition = try await makeVideoComposition(for: asset)
                
                // Set up the custom video compositor
                self.videoComposition = composition
                item.videoComposition = composition
                self.player.replaceCurrentItem(with: item)
                self.duration = durationSeconds
                self.currentTime = 0
                await self.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            } catch {
                print("Failed to load asset: \(error)")
            }
        }
    }
    
    private func makeVideoComposition(for asset: AVAsset) async throws -> AVVideoComposition {
        let adjustmentsStore = self.adjustmentsStore
        
        // We use AVVideoComposition to intercept frames and apply CoreImage filters
        return try await AVVideoComposition(applyingFiltersTo: asset, applier: { params in
            let processingSnapshot = adjustmentsStore.get()
            // Apply our CoreImage Processor logic
            let filteredImage = CoreImageProcessor.shared.applyAdjustments(
                processingSnapshot.adjustments,
                lutURL: processingSnapshot.lutURL,
                timeSeconds: params.compositionTime.isNumeric ? params.compositionTime.seconds : nil,
                renderQuality: .preview,
                to: params.sourceImage
            )
            return AVCIImageFilteringResult(resultImage: filteredImage)
        })
    }
    
    func togglePlayPause() {
        if player.isPlaying {
            player.pause()
        } else {
            player.play()
        }
    }
    
    func pause() {
        player.pause()
    }
    
    func seek(to seconds: Double, shouldPause: Bool = true) {
        guard player.currentItem != nil else { return }
        let safeDuration = max(duration, 0)
        let clampedTime = min(max(seconds, 0), safeDuration)
        let time = CMTime(seconds: clampedTime, preferredTimescale: 600)
        
        if shouldPause {
            player.pause()
        }
        
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = clampedTime
    }
    
    private func refreshCurrentFrameIfNeeded() {
        // Force a paused-frame re-render. Seeking to the exact same time can be ignored by AVPlayer,
        // so we seek by a tiny epsilon to trigger compositor refresh without visibly advancing video.
        guard let currentItem = player.currentItem, !player.isPlaying else { return }

        let baseTime = currentItem.currentTime()
        let epsilon = CMTime(value: 1, timescale: 60000) // ~0.000016s
        var nudgedTime = CMTimeAdd(baseTime, epsilon)

        if currentItem.duration.isNumeric, CMTimeCompare(nudgedTime, currentItem.duration) > 0 {
            nudgedTime = CMTimeSubtract(baseTime, epsilon)
        }
        if CMTimeCompare(nudgedTime, .zero) < 0 {
            nudgedTime = baseTime
        }

        currentItem.cancelPendingSeeks()
        player.seek(to: nudgedTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            self?.player.seek(to: baseTime, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }
    
    private func attachTimeObserver() {
        let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            if time.isNumeric {
                self.currentTime = max(0, time.seconds)
            }
            
            if let currentItem = self.player.currentItem, currentItem.duration.isNumeric {
                self.duration = max(currentItem.duration.seconds, 0)
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
}

extension AVPlayer {
    var isPlaying: Bool {
        return rate != 0 && error == nil
    }
}
