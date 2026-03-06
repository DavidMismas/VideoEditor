import Foundation
import AVFoundation
import CoreMedia
import CoreImage
import CoreVideo

@MainActor
final class TimelineExporter {
    static let shared = TimelineExporter()
    
    private struct ClipSegment {
        let timeRange: CMTimeRange
        let adjustments: ColorAdjustments
        let lutURL: URL?
    }
    
    private final class TranscodeContext: @unchecked Sendable {
        let reader: AVAssetReader
        let writer: AVAssetWriter
        let readerVideoOutput: AVAssetReaderVideoCompositionOutput
        let writerVideoInput: AVAssetWriterInput
        let readerAudioOutput: AVAssetReaderAudioMixOutput?
        let writerAudioInput: AVAssetWriterInput?
        let durationSeconds: Double
        let sendProgress: @Sendable (Double) -> Void
        
        init(
            reader: AVAssetReader,
            writer: AVAssetWriter,
            readerVideoOutput: AVAssetReaderVideoCompositionOutput,
            writerVideoInput: AVAssetWriterInput,
            readerAudioOutput: AVAssetReaderAudioMixOutput?,
            writerAudioInput: AVAssetWriterInput?,
            durationSeconds: Double,
            onProgress: (@MainActor @Sendable (Double) -> Void)?
        ) {
            self.reader = reader
            self.writer = writer
            self.readerVideoOutput = readerVideoOutput
            self.writerVideoInput = writerVideoInput
            self.readerAudioOutput = readerAudioOutput
            self.writerAudioInput = writerAudioInput
            self.durationSeconds = durationSeconds
            self.sendProgress = { value in
                guard let onProgress else { return }
                Task { @MainActor in
                    onProgress(value)
                }
            }
        }
    }
    
    private init() {}
    
    func export(
        videoTracks: [TimelineTrack],
        audioTracks: [TimelineTrack],
        config: ProjectConfig,
        format: ExportFormat,
        quality: ExportQuality,
        destinationURL: URL,
        lutLibrary: [LUTItem] = [],
        onProgress: (@MainActor @Sendable (Double) -> Void)? = nil
    ) async throws {
        let build = try await buildComposition(
            videoTracks: videoTracks,
            audioTracks: audioTracks,
            config: config,
            lutLibrary: lutLibrary
        )

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        if let onProgress {
            onProgress(0)
        }
        
        do {
            try await transcode(
                composition: build.composition,
                videoComposition: build.videoComposition,
                totalDuration: build.totalDuration,
                config: config,
                format: format,
                quality: quality,
                destinationURL: destinationURL,
                onProgress: onProgress
            )
            if let onProgress {
                onProgress(1)
            }
        } catch is CancellationError {
            throw TimelineExportError.exportCancelled
        } catch let exportError as TimelineExportError {
            throw exportError
        } catch {
            throw TimelineExportError.exportFailed(error.localizedDescription)
        }
    }
    
    private func transcode(
        composition: AVMutableComposition,
        videoComposition: AVVideoComposition,
        totalDuration: CMTime,
        config: ProjectConfig,
        format: ExportFormat,
        quality: ExportQuality,
        destinationURL: URL,
        onProgress: (@MainActor @Sendable (Double) -> Void)?
    ) async throws {
        guard let reader = try? AVAssetReader(asset: composition) else {
            throw TimelineExportError.unableToCreateReader
        }
        guard let writer = try? AVAssetWriter(outputURL: destinationURL, fileType: format.preferredFileType) else {
            throw TimelineExportError.unableToCreateWriter
        }
        
        let compositionVideoTracks = composition.tracks(withMediaType: .video)
        guard !compositionVideoTracks.isEmpty else {
            throw TimelineExportError.noVideoClips
        }

        let readerVideoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: compositionVideoTracks,
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
        )
        readerVideoOutput.videoComposition = videoComposition
        readerVideoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerVideoOutput) else {
            throw TimelineExportError.exportFailed("Unable to add video output to asset reader.")
        }
        reader.add(readerVideoOutput)

        let renderWidth = max(Int(config.resolution.width.rounded()), 2)
        let renderHeight = max(Int(config.resolution.height.rounded()), 2)
        let fps = max(config.frameRate, 1)

        let compressionProperties: [String: Any] = [
            AVVideoAverageBitRateKey: quality.targetBitrate(for: format),
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalKey: fps * 2
        ]
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: format.videoCodec,
            AVVideoWidthKey: renderWidth,
            AVVideoHeightKey: renderHeight,
            AVVideoCompressionPropertiesKey: compressionProperties
        ]
        let writerVideoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        writerVideoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerVideoInput) else {
            throw TimelineExportError.exportFailed("Unable to add video input to asset writer.")
        }
        writer.add(writerVideoInput)

        var readerAudioOutput: AVAssetReaderAudioMixOutput?
        var writerAudioInput: AVAssetWriterInput?
        let compositionAudioTracks = composition.tracks(withMediaType: .audio)
        if !compositionAudioTracks.isEmpty {
            let audioOutput = AVAssetReaderAudioMixOutput(audioTracks: compositionAudioTracks, audioSettings: nil)
            audioOutput.alwaysCopiesSampleData = false
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 48_000,
                AVEncoderBitRateKey: 320_000
            ]
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioInput.expectsMediaDataInRealTime = false
            if reader.canAdd(audioOutput), writer.canAdd(audioInput) {
                reader.add(audioOutput)
                writer.add(audioInput)
                readerAudioOutput = audioOutput
                writerAudioInput = audioInput
            }
        }

        guard writer.startWriting() else {
            throw TimelineExportError.exportFailed(writer.error?.localizedDescription ?? "Unable to start writing export output.")
        }
        guard reader.startReading() else {
            throw TimelineExportError.exportFailed(reader.error?.localizedDescription ?? "Unable to start reading export input.")
        }
        writer.startSession(atSourceTime: .zero)

        let writingQueue = DispatchQueue(label: "TimelineExporter.WriterQueue", qos: .userInitiated)
        let group = DispatchGroup()
        let durationSeconds = max(totalDuration.seconds, 0.001)
        let context = TranscodeContext(
            reader: reader,
            writer: writer,
            readerVideoOutput: readerVideoOutput,
            writerVideoInput: writerVideoInput,
            readerAudioOutput: readerAudioOutput,
            writerAudioInput: writerAudioInput,
            durationSeconds: durationSeconds,
            onProgress: onProgress
        )

        group.enter()
        context.writerVideoInput.requestMediaDataWhenReady(on: writingQueue) {
            while context.writerVideoInput.isReadyForMoreMediaData {
                if context.reader.status != .reading {
                    context.writerVideoInput.markAsFinished()
                    group.leave()
                    break
                }

                guard let sampleBuffer = context.readerVideoOutput.copyNextSampleBuffer() else {
                    context.writerVideoInput.markAsFinished()
                    group.leave()
                    break
                }

                if !context.writerVideoInput.append(sampleBuffer) {
                    context.reader.cancelReading()
                    context.writerVideoInput.markAsFinished()
                    group.leave()
                    break
                }

                let current = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
                let normalized = min(max(current / context.durationSeconds, 0), 0.98)
                context.sendProgress(normalized)
            }
        }

        if context.readerAudioOutput != nil, context.writerAudioInput != nil {
            group.enter()
            context.writerAudioInput?.requestMediaDataWhenReady(on: writingQueue) {
                while let writerAudioInput = context.writerAudioInput, writerAudioInput.isReadyForMoreMediaData {
                    if context.reader.status != .reading && context.reader.status != .completed {
                        writerAudioInput.markAsFinished()
                        group.leave()
                        break
                    }

                    guard let readerAudioOutput = context.readerAudioOutput,
                          let sampleBuffer = readerAudioOutput.copyNextSampleBuffer()
                    else {
                        writerAudioInput.markAsFinished()
                        group.leave()
                        break
                    }

                    if !writerAudioInput.append(sampleBuffer) {
                        context.reader.cancelReading()
                        writerAudioInput.markAsFinished()
                        group.leave()
                        break
                    }
                }
            }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            group.notify(queue: writingQueue) {
                if context.reader.status == .failed {
                    context.writer.cancelWriting()
                    continuation.resume(
                        throwing: TimelineExportError.exportFailed(
                            context.reader.error?.localizedDescription ?? "Asset reader failed while exporting."
                        )
                    )
                    return
                }
                if context.reader.status == .cancelled {
                    context.writer.cancelWriting()
                    continuation.resume(throwing: TimelineExportError.exportCancelled)
                    return
                }

                context.writer.finishWriting {
                    switch context.writer.status {
                    case .completed:
                        continuation.resume()
                    case .cancelled:
                        continuation.resume(throwing: TimelineExportError.exportCancelled)
                    case .failed:
                        continuation.resume(
                            throwing: TimelineExportError.exportFailed(
                                context.writer.error?.localizedDescription ?? "Asset writer failed while exporting."
                            )
                        )
                    default:
                        continuation.resume(
                            throwing: TimelineExportError.exportFailed(
                                "Writer ended in unexpected state: \(context.writer.status)."
                            )
                        )
                    }
                }
            }
        }
    }
    
    private func buildComposition(
        videoTracks: [TimelineTrack],
        audioTracks: [TimelineTrack],
        config: ProjectConfig,
        lutLibrary: [LUTItem]
    ) async throws -> (composition: AVMutableComposition, videoComposition: AVVideoComposition, totalDuration: CMTime) {
        guard let primaryVideoTrack = videoTracks.first(where: { !$0.isAudioOnly && !$0.clips.isEmpty }) else {
            throw TimelineExportError.noVideoClips
        }
        
        let composition = AVMutableComposition()
        
        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw TimelineExportError.unableToCreateCompositionTrack
        }
        
        let primaryAudioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )
        
        var clipSegments: [ClipSegment] = []
        var timelineCursor = CMTime.zero
        var preferredTransformSet = false
        let lutMap = Dictionary(uniqueKeysWithValues: lutLibrary.map { ($0.id, $0.url) })
        
        for clip in primaryVideoTrack.clips {
            guard let sourceURL = clip.mediaItem.url else {
                throw TimelineExportError.clipMissingURL(clip.mediaItem.name)
            }
            
            let asset = AVURLAsset(url: sourceURL)
            guard let sourceVideoTrack = try await asset.loadTracks(withMediaType: .video).first else {
                continue
            }
            
            let sourceDuration = try await asset.load(.duration)
            guard sourceDuration.isNumeric else { continue }
            let sourceStart = clip.startTime.isNumeric ? clip.startTime : .zero
            let availableDurationRaw = CMTimeSubtract(sourceDuration, sourceStart)
            guard availableDurationRaw.isNumeric else { continue }
            let availableDuration = CMTimeMaximum(.zero, availableDurationRaw)
            guard availableDuration.isNumeric, availableDuration > .zero else { continue }
            
            let requestedDuration = (clip.duration.isNumeric && clip.duration > .zero) ? clip.duration : availableDuration
            let finalDuration = CMTimeMinimum(requestedDuration, availableDuration)
            guard finalDuration.isNumeric, finalDuration > .zero else { continue }
            let sourceRange = CMTimeRange(start: sourceStart, duration: finalDuration)
            
            try compositionVideoTrack.insertTimeRange(sourceRange, of: sourceVideoTrack, at: timelineCursor)
            
            if !preferredTransformSet {
                let preferredTransform = try await sourceVideoTrack.load(.preferredTransform)
                let naturalSize = try await sourceVideoTrack.load(.naturalSize)
                compositionVideoTrack.preferredTransform = preferredTransform
                composition.naturalSize = Self.orientedSize(for: naturalSize, preferredTransform: preferredTransform)
                preferredTransformSet = true
            }
            
            if !clip.isMuted,
               let sourceAudioTrack = try await asset.loadTracks(withMediaType: .audio).first,
               let primaryAudioTrack {
                try primaryAudioTrack.insertTimeRange(sourceRange, of: sourceAudioTrack, at: timelineCursor)
            }
            
            let segmentTimeRange = CMTimeRange(start: timelineCursor, duration: finalDuration)
            clipSegments.append(
                ClipSegment(
                    timeRange: segmentTimeRange,
                    adjustments: clip.adjustments,
                    lutURL: clip.appliedLUTID.flatMap { lutMap[$0] }
                )
            )
            timelineCursor = CMTimeAdd(timelineCursor, finalDuration)
        }
        
        for lane in audioTracks where !lane.clips.isEmpty {
            guard let compositionAudioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                continue
            }
            
            var laneCursor = CMTime.zero
            for clip in lane.clips {
                guard let sourceURL = clip.mediaItem.url else { continue }
                let asset = AVURLAsset(url: sourceURL)
                guard let sourceAudioTrack = try await asset.loadTracks(withMediaType: .audio).first else { continue }
                
                let sourceDuration = try await asset.load(.duration)
                guard sourceDuration.isNumeric else { continue }
                let sourceStart = clip.startTime.isNumeric ? clip.startTime : .zero
                let availableDurationRaw = CMTimeSubtract(sourceDuration, sourceStart)
                guard availableDurationRaw.isNumeric else { continue }
                let availableDuration = CMTimeMaximum(.zero, availableDurationRaw)
                guard availableDuration.isNumeric, availableDuration > .zero else { continue }
                
                let requestedDuration = (clip.duration.isNumeric && clip.duration > .zero) ? clip.duration : availableDuration
                let finalDuration = CMTimeMinimum(requestedDuration, availableDuration)
                guard finalDuration.isNumeric, finalDuration > .zero else { continue }
                let sourceRange = CMTimeRange(start: sourceStart, duration: finalDuration)
                
                try compositionAudioTrack.insertTimeRange(sourceRange, of: sourceAudioTrack, at: laneCursor)
                laneCursor = CMTimeAdd(laneCursor, finalDuration)
            }
        }
        
        if !timelineCursor.isNumeric || timelineCursor <= .zero {
            throw TimelineExportError.noVideoClips
        }
        
        let exportProcessor = CoreImageProcessor.shared
        let clipMap = clipSegments
        let defaultAdjustments = ColorAdjustments()
        let targetRenderSize = config.resolution
        
        if composition.naturalSize.width <= 0 || composition.naturalSize.height <= 0 {
            composition.naturalSize = targetRenderSize
        }
        
        let baseVideoComposition = try await AVVideoComposition(applyingFiltersTo: composition, applier: { params in
            let compositionTime = params.compositionTime
            let clipSegment = clipMap.first(where: { segment in
                guard segment.timeRange.start.isNumeric,
                      segment.timeRange.duration.isNumeric,
                      segment.timeRange.duration > .zero,
                      compositionTime.isNumeric
                else {
                    return false
                }
                let start = segment.timeRange.start
                let end = CMTimeAdd(start, segment.timeRange.duration)
                return CMTimeCompare(compositionTime, start) >= 0 && CMTimeCompare(compositionTime, end) < 0
            })
            let clipAdjustments = clipSegment?.adjustments ?? defaultAdjustments
            let clipLUTURL = clipSegment?.lutURL
            let filtered = exportProcessor.applyAdjustments(
                clipAdjustments,
                lutURL: clipLUTURL,
                timeSeconds: compositionTime.isNumeric ? compositionTime.seconds : nil,
                renderQuality: .export,
                to: params.sourceImage
            )
            let fitted = Self.aspectFit(filtered, into: targetRenderSize)
            return AVCIImageFilteringResult(resultImage: fitted)
        })
        
        var videoConfiguration = try await AVVideoComposition.Configuration(for: composition)
        videoConfiguration.instructions = baseVideoComposition.instructions
        videoConfiguration.customVideoCompositorClass = baseVideoComposition.customVideoCompositorClass
        videoConfiguration.sourceSampleDataTrackIDs = baseVideoComposition.sourceSampleDataTrackIDs
        let safeFrameRate = max(config.frameRate, 1)
        videoConfiguration.renderSize = config.resolution
        videoConfiguration.frameDuration = CMTime(value: 1, timescale: CMTimeScale(safeFrameRate))
        videoConfiguration.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid
        
        let videoComposition = AVVideoComposition(configuration: videoConfiguration)
        
        return (composition, videoComposition, timelineCursor)
    }
    
    nonisolated private static func orientedSize(for naturalSize: CGSize, preferredTransform: CGAffineTransform) -> CGSize {
        let transformedRect = CGRect(origin: .zero, size: naturalSize)
            .applying(preferredTransform)
            .standardized
        return CGSize(
            width: abs(transformedRect.width),
            height: abs(transformedRect.height)
        )
    }
    
    nonisolated private static func aspectFit(_ image: CIImage, into renderSize: CGSize) -> CIImage {
        guard renderSize.width > 1, renderSize.height > 1 else { return image }
        
        let sourceExtent = image.extent.standardized
        guard sourceExtent.width > 1, sourceExtent.height > 1 else { return image }
        
        let targetRect = CGRect(origin: .zero, size: renderSize)
        let normalized = image.transformed(by: CGAffineTransform(
            translationX: -sourceExtent.origin.x,
            y: -sourceExtent.origin.y
        ))
        
        let scale = min(
            renderSize.width / sourceExtent.width,
            renderSize.height / sourceExtent.height
        )
        let scaledWidth = sourceExtent.width * scale
        let scaledHeight = sourceExtent.height * scale
        let xOffset = (renderSize.width - scaledWidth) * 0.5
        let yOffset = (renderSize.height - scaledHeight) * 0.5
        
        let fitted = normalized
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: xOffset, y: yOffset))
        
        let background = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1))
            .cropped(to: targetRect)
        
        return fitted
            .composited(over: background)
            .cropped(to: targetRect)
    }
}
