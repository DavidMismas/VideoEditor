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
        let transforms: Transforms
        let layerIndex: Int
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
                audioMix: build.audioMix,
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

    func makePreviewItem(
        videoTracks: [TimelineTrack],
        audioTracks: [TimelineTrack],
        config: ProjectConfig,
        lutLibrary: [LUTItem] = []
    ) async throws -> (item: AVPlayerItem, totalDuration: CMTime) {
        let build = try await buildComposition(
            videoTracks: videoTracks,
            audioTracks: audioTracks,
            config: config,
            lutLibrary: lutLibrary
        )

        let item = AVPlayerItem(asset: build.composition)
        item.videoComposition = build.videoComposition
        item.audioMix = build.audioMix
        return (item, build.totalDuration)
    }
    
    private func transcode(
        composition: AVMutableComposition,
        videoComposition: AVVideoComposition,
        audioMix: AVAudioMix?,
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
            audioOutput.audioMix = audioMix
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
    ) async throws -> (composition: AVMutableComposition, videoComposition: AVVideoComposition, audioMix: AVAudioMix?, totalDuration: CMTime) {
        let populatedVideoTracks = videoTracks.enumerated().filter { !$0.element.isAudioOnly && !$0.element.clips.isEmpty }
        guard !populatedVideoTracks.isEmpty else {
            throw TimelineExportError.noVideoClips
        }
        
        let composition = AVMutableComposition()

        var clipSegments: [ClipSegment] = []
        var totalTimelineDuration = CMTime.zero
        var naturalSizeSet = false
        let lutMap = Dictionary(uniqueKeysWithValues: lutLibrary.map { ($0.id, $0.url) })

        struct AudioMixLane {
            let track: AVMutableCompositionTrack
            var segments: [(timeRange: CMTimeRange, volume: Float)]
        }

        var audioMixLanes: [AudioMixLane] = []

        for (layerIndex, lane) in populatedVideoTracks {
            guard let compositionVideoTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                throw TimelineExportError.unableToCreateCompositionTrack
            }

            let laneAudioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
            if let laneAudioTrack {
                audioMixLanes.append(AudioMixLane(track: laneAudioTrack, segments: []))
            }

            var laneCursor = CMTime.zero
            for clip in lane.clips {
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

                try compositionVideoTrack.insertTimeRange(sourceRange, of: sourceVideoTrack, at: laneCursor)

                if !naturalSizeSet {
                    let naturalSize = try await sourceVideoTrack.load(.naturalSize)
                    composition.naturalSize = naturalSize
                    naturalSizeSet = true
                }

                if !clip.isMuted,
                   let sourceAudioTrack = try await asset.loadTracks(withMediaType: .audio).first,
                   let laneAudioTrack,
                   let laneIndex = audioMixLanes.firstIndex(where: { $0.track.trackID == laneAudioTrack.trackID }) {
                    try laneAudioTrack.insertTimeRange(sourceRange, of: sourceAudioTrack, at: laneCursor)
                    let segmentTimeRange = CMTimeRange(start: laneCursor, duration: finalDuration)
                    let clampedVolume = min(max(clip.volume, 0), 1)
                    audioMixLanes[laneIndex].segments.append((timeRange: segmentTimeRange, volume: clampedVolume))
                }

                let segmentTimeRange = CMTimeRange(start: laneCursor, duration: finalDuration)
                clipSegments.append(
                    ClipSegment(
                        timeRange: segmentTimeRange,
                        adjustments: clip.adjustments,
                        lutURL: clip.appliedLUTID.flatMap { lutMap[$0] },
                        transforms: clip.transforms,
                        layerIndex: layerIndex
                    )
                )
                laneCursor = CMTimeAdd(laneCursor, finalDuration)
            }

            totalTimelineDuration = CMTimeMaximum(totalTimelineDuration, laneCursor)
        }
        
        for lane in audioTracks where !lane.clips.isEmpty {
            guard let compositionAudioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                continue
            }

            audioMixLanes.append(AudioMixLane(track: compositionAudioTrack, segments: []))
            let laneMixIndex = audioMixLanes.count - 1
            
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
                let segmentTimeRange = CMTimeRange(start: laneCursor, duration: finalDuration)
                let clampedVolume = clip.isMuted ? Float(0) : min(max(clip.volume, 0), 1)
                audioMixLanes[laneMixIndex].segments.append((timeRange: segmentTimeRange, volume: clampedVolume))
                laneCursor = CMTimeAdd(laneCursor, finalDuration)
            }

            totalTimelineDuration = CMTimeMaximum(totalTimelineDuration, laneCursor)
        }
        
        if !totalTimelineDuration.isNumeric || totalTimelineDuration <= .zero {
            throw TimelineExportError.noVideoClips
        }
        
        let audioMix: AVAudioMix? = {
            let inputParameters = audioMixLanes.compactMap { lane -> AVAudioMixInputParameters? in
                guard !lane.segments.isEmpty else { return nil }
                let parameters = AVMutableAudioMixInputParameters(track: lane.track)
                for segment in lane.segments {
                    parameters.setVolumeRamp(
                        fromStartVolume: segment.volume,
                        toEndVolume: segment.volume,
                        timeRange: segment.timeRange
                    )
                }
                return parameters
            }
            guard !inputParameters.isEmpty else { return nil }
            let mix = AVMutableAudioMix()
            mix.inputParameters = inputParameters
            return mix
        }()

        let exportProcessor = CoreImageProcessor.shared
        let clipMap = clipSegments
        let defaultAdjustments = ColorAdjustments()
        let targetRenderSize = config.resolution
        
        if composition.naturalSize.width <= 0 || composition.naturalSize.height <= 0 {
            composition.naturalSize = targetRenderSize
        }
        
        let baseVideoComposition = try await AVVideoComposition(applyingFiltersTo: composition, applier: { params in
            let compositionTime = params.compositionTime
            let clipSegment = clipMap
                .filter { segment in
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
                }
                .max(by: { lhs, rhs in lhs.layerIndex < rhs.layerIndex })
            let clipAdjustments = clipSegment?.adjustments ?? defaultAdjustments
            let clipLUTURL = clipSegment?.lutURL
            let clipTransforms = clipSegment?.transforms ?? Transforms()
            let filtered = exportProcessor.applyAdjustments(
                clipAdjustments,
                lutURL: clipLUTURL,
                timeSeconds: compositionTime.isNumeric ? compositionTime.seconds : nil,
                renderQuality: .export,
                to: params.sourceImage
            )
            let cropped = Self.applyCanvasCrop(clipTransforms.cropRect, to: filtered, renderSize: targetRenderSize)
            return AVCIImageFilteringResult(resultImage: cropped)
        })
        
        var videoConfiguration = try await AVVideoComposition.Configuration(for: composition)
        videoConfiguration.instructions = Self.makeIdentityTransformInstructions(
            for: composition.tracks(withMediaType: .video),
            duration: totalTimelineDuration
        )
        videoConfiguration.customVideoCompositorClass = baseVideoComposition.customVideoCompositorClass
        videoConfiguration.sourceSampleDataTrackIDs = baseVideoComposition.sourceSampleDataTrackIDs
        let safeFrameRate = max(config.frameRate, 1)
        videoConfiguration.renderSize = config.resolution
        videoConfiguration.frameDuration = CMTime(value: 1, timescale: CMTimeScale(safeFrameRate))
        videoConfiguration.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid
        
        let videoComposition = AVVideoComposition(configuration: videoConfiguration)
        
        return (composition, videoComposition, audioMix, totalTimelineDuration)
    }

    nonisolated private static func makeIdentityTransformInstructions(
        for videoTracks: [AVAssetTrack],
        duration: CMTime
    ) -> [AVVideoCompositionInstructionProtocol] {
        let layerInstructions: [AVVideoCompositionLayerInstruction] = videoTracks.reversed().map { track in
            let instruction = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
            instruction.setTransform(.identity, at: .zero)
            return instruction
        }

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = layerInstructions
        instruction.enablePostProcessing = true
        return [instruction]
    }
    
    nonisolated private static func applyCanvasCrop(_ normalizedCropRect: CGRect?, to image: CIImage, renderSize: CGSize) -> CIImage {
        guard renderSize.width > 1, renderSize.height > 1 else { return image }

        let sourceExtent = image.extent.standardized
        guard sourceExtent.width > 1, sourceExtent.height > 1 else { return image }

        let sourceAspect = sourceExtent.width / sourceExtent.height
        let canvasAspect = renderSize.width / renderSize.height
        let fittedCrop = CanvasCropMath.fittedNormalizedCropRect(
            normalizedCropRect,
            sourceAspect: sourceAspect,
            canvasAspect: canvasAspect
        )

        let clamped = CGRect(
            x: min(max(fittedCrop.origin.x, 0), 1),
            y: min(max(fittedCrop.origin.y, 0), 1),
            width: min(max(fittedCrop.size.width, 0.05), 1),
            height: min(max(fittedCrop.size.height, 0.05), 1)
        )
        let maxX = min(clamped.maxX, 1)
        let maxY = min(clamped.maxY, 1)
        let cropRect = CGRect(
            x: sourceExtent.minX + (clamped.minX * sourceExtent.width),
            y: sourceExtent.minY + (clamped.minY * sourceExtent.height),
            width: max((maxX - clamped.minX) * sourceExtent.width, 1),
            height: max((maxY - clamped.minY) * sourceExtent.height, 1)
        ).integral

        guard cropRect.width > 1, cropRect.height > 1 else { return image }

        let cropped = image.cropped(to: cropRect)
        let scale = max(renderSize.width / cropRect.width, renderSize.height / cropRect.height)
        let scaled = cropped
            .transformed(by: CGAffineTransform(translationX: -cropRect.origin.x, y: -cropRect.origin.y))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let xOffset = (renderSize.width - (cropRect.width * scale)) * 0.5
        let yOffset = (renderSize.height - (cropRect.height * scale)) * 0.5
        let translated = scaled.transformed(by: CGAffineTransform(translationX: xOffset, y: yOffset))
        let targetRect = CGRect(origin: .zero, size: renderSize)
        let background = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1))
            .cropped(to: targetRect)

        return translated
            .composited(over: background)
            .cropped(to: targetRect)
    }
}
