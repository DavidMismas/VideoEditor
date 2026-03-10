import Foundation
import AVFoundation
import CoreMedia
import CoreImage
import CoreVideo

@MainActor
final class TimelineExporter {
    static let shared = TimelineExporter()
    
    private struct SourceVideoColorProperties {
        let primaries: String?
        let transferFunction: String?
        let yCbCrMatrix: String?
    }

    private struct ClipSegment {
        let timeRange: CMTimeRange
        let adjustments: ColorAdjustments
        let lutURL: URL?
        let transforms: Transforms
        let layerIndex: Int
        let preferredTransform: CGAffineTransform
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
                outputColorSpace: build.outputColorSpace,
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
        outputColorSpace: ColorSpace,
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
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_64RGBAHalf)]
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
            AVVideoCompressionPropertiesKey: compressionProperties,
            AVVideoColorPropertiesKey: Self.videoColorProperties(for: outputColorSpace)
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
    ) async throws -> (composition: AVMutableComposition, videoComposition: AVVideoComposition, audioMix: AVAudioMix?, totalDuration: CMTime, outputColorSpace: ColorSpace) {
        let populatedVideoTracks = videoTracks.enumerated().filter { !$0.element.isAudioOnly && !$0.element.clips.isEmpty }
        guard !populatedVideoTracks.isEmpty else {
            throw TimelineExportError.noVideoClips
        }
        
        let composition = AVMutableComposition()

        var clipSegments: [ClipSegment] = []
        var totalTimelineDuration = CMTime.zero
        var naturalSizeSet = false
        let lutMap = Dictionary(uniqueKeysWithValues: lutLibrary.map { ($0.id, $0.url) })
        var compositionTrackTransforms: [CMPersistentTrackID: CGAffineTransform] = [:]

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
                let preferredTransform = try await sourceVideoTrack.load(.preferredTransform)

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
                if laneCursor == .zero {
                    compositionVideoTrack.preferredTransform = preferredTransform
                    compositionTrackTransforms[compositionVideoTrack.trackID] = preferredTransform
                }

                if !naturalSizeSet {
                    let naturalSize = try await sourceVideoTrack.load(.naturalSize)
                    composition.naturalSize = Self.displaySize(
                        for: naturalSize,
                        preferredTransform: preferredTransform
                    )
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
                        layerIndex: layerIndex,
                        preferredTransform: preferredTransform
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

        let clipMap = clipSegments
        let defaultAdjustments = ColorAdjustments()
        let targetRenderSize = config.resolution
        
        if composition.naturalSize.width <= 0 || composition.naturalSize.height <= 0 {
            composition.naturalSize = targetRenderSize
        }
        
        let safeFrameRate = max(config.frameRate, 1)
        let compositionVideoTracks = composition.tracks(withMediaType: .video)

        let videoComposition: AVVideoComposition
        if populatedVideoTracks.count == 1 {
            videoComposition = try await Self.makeFilteredVideoComposition(for: composition) { request in
                let compositionTime = request.compositionTime
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
                let clipPreferredTransform = clipSegment?.preferredTransform
                let filtered = CoreImageProcessor.shared.applyAdjustments(
                    clipAdjustments,
                    lutURL: clipLUTURL,
                    timeSeconds: compositionTime.isNumeric ? compositionTime.seconds : nil,
                    renderQuality: .export,
                    to: request.sourceImage
                )
                let cropped = Self.applyCanvasCrop(
                    clipTransforms.cropRect,
                    to: filtered,
                    renderSize: targetRenderSize,
                    preferredTransform: clipPreferredTransform
                )
                request.finish(
                    with: cropped,
                    context: CoreImageProcessor.shared.renderContext(for: clipAdjustments)
                )
            }
        } else {
            // AVVideoComposition(applyingFiltersTo:) installs AVCoreImageFilter instructions internally.
            // Replacing those instructions with standard AVVideoCompositionInstruction objects crashes playback.
            var videoConfiguration = try await AVVideoComposition.Configuration(for: composition)
            videoConfiguration.instructions = Self.makeIdentityTransformInstructions(
                for: compositionVideoTracks,
                transforms: compositionTrackTransforms,
                duration: totalTimelineDuration
            )
            videoConfiguration.renderSize = targetRenderSize
            videoConfiguration.frameDuration = CMTime(value: 1, timescale: CMTimeScale(safeFrameRate))
            videoConfiguration.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid
            videoComposition = AVVideoComposition(configuration: videoConfiguration)
        }
        
        let outputColorSpace = clipSegments.first.map { ColorSpace($0.adjustments.outputColorSpace) } ?? .rec709
        return (composition, videoComposition, audioMix, totalTimelineDuration, outputColorSpace)
    }

    nonisolated private static func makeIdentityTransformInstructions(
        for videoTracks: [AVAssetTrack],
        transforms: [CMPersistentTrackID: CGAffineTransform],
        duration: CMTime
    ) -> [AVVideoCompositionInstructionProtocol] {
        let layerInstructions: [AVVideoCompositionLayerInstruction] = videoTracks.reversed().map { track in
            var configuration = AVVideoCompositionLayerInstruction.Configuration(assetTrack: track)
            configuration.setTransform(transforms[track.trackID] ?? .identity, at: .zero)
            return AVVideoCompositionLayerInstruction(configuration: configuration)
        }

        let configuration = AVVideoCompositionInstruction.Configuration(
            backgroundColor: nil,
            enablePostProcessing: true,
            layerInstructions: layerInstructions,
            requiredSourceSampleDataTrackIDs: [],
            timeRange: CMTimeRange(start: .zero, duration: duration)
        )
        return [AVVideoCompositionInstruction(configuration: configuration)]
    }

    nonisolated private static func makeFilteredVideoComposition(
        for asset: AVAsset,
        handler: @escaping @Sendable (AVAsynchronousCIImageFilteringRequest) -> Void
    ) async throws -> AVVideoComposition {
        let sourceColorProperties = try await loadSourceColorProperties(for: asset)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AVVideoComposition, Error>) in
            AVMutableVideoComposition.videoComposition(
                with: asset,
                applyingCIFiltersWithHandler: handler,
                completionHandler: { composition, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let composition else {
                        continuation.resume(
                            throwing: NSError(
                                domain: "TimelineExporter",
                                code: -1,
                                userInfo: [NSLocalizedDescriptionKey: "AVVideoComposition returned no composition."]
                            )
                        )
                        return
                    }
                    if let sourceColorProperties {
                        composition.colorPrimaries = sourceColorProperties.primaries
                        composition.colorTransferFunction = sourceColorProperties.transferFunction
                        composition.colorYCbCrMatrix = sourceColorProperties.yCbCrMatrix
                    }
                    continuation.resume(returning: composition)
                }
            )
        }
    }

    nonisolated private static func loadSourceColorProperties(
        for asset: AVAsset
    ) async throws -> SourceVideoColorProperties? {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        return try await sourceColorProperties(from: tracks)
    }

    nonisolated private static func sourceColorProperties(
        from tracks: [AVAssetTrack]
    ) async throws -> SourceVideoColorProperties? {
        for track in tracks {
            let formatDescriptions = try await track.load(.formatDescriptions)
            guard let properties = sourceColorProperties(from: formatDescriptions) else {
                continue
            }
            return properties
        }

        return nil
    }

    nonisolated private static func sourceColorProperties(
        from formatDescriptions: [CMFormatDescription]
    ) -> SourceVideoColorProperties? {
        for formatDescription in formatDescriptions {
            let extensions = (CMFormatDescriptionGetExtensions(formatDescription) as NSDictionary?) as? [String: Any] ?? [:]
            let primaries = extensions[kCVImageBufferColorPrimariesKey as String] as? String
            let transferFunction = extensions[kCVImageBufferTransferFunctionKey as String] as? String
            let yCbCrMatrix = extensions[kCVImageBufferYCbCrMatrixKey as String] as? String

            if primaries != nil || transferFunction != nil || yCbCrMatrix != nil {
                return SourceVideoColorProperties(
                    primaries: primaries,
                    transferFunction: transferFunction,
                    yCbCrMatrix: yCbCrMatrix
                )
            }
        }

        return nil
    }

    nonisolated private static func displaySize(for naturalSize: CGSize, preferredTransform: CGAffineTransform) -> CGSize {
        let displayRect = CGRect(origin: .zero, size: naturalSize)
            .applying(preferredTransform)
            .standardized
        return CGSize(width: abs(displayRect.width), height: abs(displayRect.height))
    }

    nonisolated private static func videoColorProperties(for outputColorSpace: ColorSpace) -> [String: String] {
        switch outputColorSpace {
        case .rec709, .linearSRGB, .acescg:
            return [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        case .displayP3:
            return [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_P3_D65,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        case .bt2020:
            return [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020
            ]
        }
    }
    
    nonisolated private static func applyCanvasCrop(
        _ normalizedCropRect: CGRect?,
        to image: CIImage,
        renderSize: CGSize,
        preferredTransform: CGAffineTransform?
    ) -> CIImage {
        guard renderSize.width > 1, renderSize.height > 1 else { return image }

        let sourceExtent = image.extent.standardized
        guard sourceExtent.width > 1, sourceExtent.height > 1 else { return image }

        let cropRect = resolvedCropRect(
            normalizedCropRect,
            sourceExtent: sourceExtent,
            renderSize: renderSize,
            preferredTransform: preferredTransform
        )

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

    nonisolated private static func resolvedCropRect(
        _ normalizedCropRect: CGRect?,
        sourceExtent: CGRect,
        renderSize: CGSize,
        preferredTransform: CGAffineTransform?
    ) -> CGRect {
        let canvasAspect = renderSize.width / renderSize.height
        let imageAspect = sourceExtent.width / sourceExtent.height

        guard let preferredTransform else {
            return directCropRect(
                normalizedCropRect,
                sourceExtent: sourceExtent,
                sourceAspect: imageAspect,
                canvasAspect: canvasAspect
            )
        }

        let displaySize = displaySize(for: sourceExtent.size, preferredTransform: preferredTransform)
        let displayAspect = max(displaySize.width / max(displaySize.height, 0.001), 0.001)

        if abs(displayAspect - imageAspect) < 0.01 {
            return directCropRect(
                normalizedCropRect,
                sourceExtent: sourceExtent,
                sourceAspect: displayAspect,
                canvasAspect: canvasAspect
            )
        }

        let fittedCrop = CanvasCropMath.fittedNormalizedCropRect(
            normalizedCropRect,
            sourceAspect: displayAspect,
            canvasAspect: canvasAspect
        )
        let displayCropRect = rect(
            from: fittedCrop,
            in: CGRect(origin: .zero, size: displaySize)
        )

        let zeroOriginSource = CGRect(origin: .zero, size: sourceExtent.size)
        let transformedBounds = zeroOriginSource
            .applying(preferredTransform)
            .standardized
        let transformToDisplayOrigin = preferredTransform.concatenating(
            CGAffineTransform(
                translationX: -transformedBounds.minX,
                y: -transformedBounds.minY
            )
        )

        let imageSpaceCrop = displayCropRect
            .applying(transformToDisplayOrigin.inverted())
            .standardized
            .offsetBy(dx: sourceExtent.minX, dy: sourceExtent.minY)

        return clampedCropRect(imageSpaceCrop, inside: sourceExtent)
    }

    nonisolated private static func directCropRect(
        _ normalizedCropRect: CGRect?,
        sourceExtent: CGRect,
        sourceAspect: CGFloat,
        canvasAspect: CGFloat
    ) -> CGRect {
        let fittedCrop = CanvasCropMath.fittedNormalizedCropRect(
            normalizedCropRect,
            sourceAspect: sourceAspect,
            canvasAspect: canvasAspect
        )
        return clampedCropRect(
            rect(from: fittedCrop, in: sourceExtent),
            inside: sourceExtent
        )
    }

    nonisolated private static func rect(from normalizedRect: CGRect, in extent: CGRect) -> CGRect {
        let clamped = CGRect(
            x: min(max(normalizedRect.origin.x, 0), 1),
            y: min(max(normalizedRect.origin.y, 0), 1),
            width: min(max(normalizedRect.size.width, 0.05), 1),
            height: min(max(normalizedRect.size.height, 0.05), 1)
        )
        let maxX = min(clamped.maxX, 1)
        let maxY = min(clamped.maxY, 1)
        return CGRect(
            x: extent.minX + (clamped.minX * extent.width),
            y: extent.minY + (clamped.minY * extent.height),
            width: max((maxX - clamped.minX) * extent.width, 1),
            height: max((maxY - clamped.minY) * extent.height, 1)
        ).integral
    }

    nonisolated private static func clampedCropRect(_ rect: CGRect, inside extent: CGRect) -> CGRect {
        let intersected = rect.intersection(extent).integral
        if intersected.width > 1, intersected.height > 1 {
            return intersected
        }
        return extent.integral
    }
}
