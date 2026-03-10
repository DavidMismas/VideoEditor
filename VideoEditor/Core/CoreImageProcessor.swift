import Foundation
import CoreImage
import AVFoundation
import CoreGraphics
import CoreVideo
import Metal

nonisolated enum ColorPipelineRenderQuality {
    case preview
    case export
}

nonisolated class CoreImageProcessor {
    static let shared = CoreImageProcessor()

    private struct ContextKey: Hashable {
        let working: ColorSpace
        let output: ColorSpace
    }

    private struct RawPixelBufferPoolKey: Hashable {
        let width: Int
        let height: Int
    }

    private struct ColorPipelineConfiguration {
        let working: ColorSpace
        let output: ColorSpace
    }

    private enum LUTPipelineError: Error, CustomStringConvertible {
        case missingCreativeLUTSpace
        case missingTechnicalLUTSpaces
        case unsupportedSourceToWorkingTransform(SignalSpace, ColorSpace)
        case unsupportedSourceToLUTTransform(SignalSpace, SignalSpace)
        case unsupportedLUTOutputToWorkingTransform(SignalSpace, ColorSpace)

        var description: String {
            switch self {
            case .missingCreativeLUTSpace:
                return "Creative LUT is missing an explicit LUT space."
            case .missingTechnicalLUTSpaces:
                return "Technical LUT is missing explicit input/output spaces."
            case let .unsupportedSourceToWorkingTransform(source, working):
                return "Missing explicit transform from \(source.displayName) to working space \(working.rawValue)."
            case let .unsupportedSourceToLUTTransform(source, lutInput):
                return "Missing explicit transform from \(source.displayName) to LUT input space \(lutInput.displayName)."
            case let .unsupportedLUTOutputToWorkingTransform(lutOutput, working):
                return "Missing explicit transform from LUT output space \(lutOutput.displayName) to working space \(working.rawValue)."
            }
        }
    }

    private var contextCache: [ContextKey: CIContext] = [:]
    private let contextCacheQueue = DispatchQueue(label: "CoreImageProcessor.contextCacheQueue")
    private let metalDevice = MTLCreateSystemDefaultDevice()
    private var rawPixelBufferPools: [RawPixelBufferPoolKey: CVPixelBufferPool] = [:]

    private let noiseReductionFilter = CIFilter(name: "CINoiseReduction")
    private let sharpenFilter = CIFilter(name: "CISharpenLuminance")
    private let bloomFilter = CIFilter(name: "CIBloom")
    private let vignetteGradientFilter = CIFilter(name: "CIRadialGradient")
    private let vignetteDarkenFilter = CIFilter(name: "CIColorMatrix")
    private let vignetteBlendFilter = CIFilter(name: "CIBlendWithMask")
    private let gaussianBlurFilter = CIFilter(name: "CIGaussianBlur")
    private let primaryToneKernel = CIColorKernel(source: """
float smoothstep_ci(float edge0, float edge1, float x) {
    float t = clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
    return t * t * (3.0 - (2.0 * t));
}

float encoded_perceptual_luma(float y) {
    float scaled = max(y, 0.0) * 15.0;
    return log2(1.0 + scaled) / 4.0;
}

float decoded_perceptual_luma(float tone) {
    return (pow(16.0, tone) - 1.0) / 15.0;
}

float compress_highlights(float y, float start, float strength) {
    if (y <= start) {
        return y;
    }

    float x = y - start;
    float k = 1.0 + (strength * 8.0);
    return start + (x / (1.0 + (k * x)));
}

vec3 remap_luma(vec3 rgb, float sourceLuma, float targetLuma) {
    float safeTarget = max(targetLuma, 0.0);
    float safeSource = max(sourceLuma, 1.0e-6);
    vec3 scaled = rgb * (safeTarget / safeSource);

    if (sourceLuma <= 1.0e-4) {
        vec3 neutral = vec3(safeTarget);
        float blend = smoothstep_ci(0.0, 1.0e-4, sourceLuma);
        return vec3(
            neutral.r + ((scaled.r - neutral.r) * blend),
            neutral.g + ((scaled.g - neutral.g) * blend),
            neutral.b + ((scaled.b - neutral.b) * blend)
        );
    }

    return scaled;
}

kernel vec4 primaryTone(
    __sample image,
    float exposureValue,
    float contrastValue,
    float highlightsValue,
    float shadowsValue,
    float filmicValue,
    vec3 coefficients
) {
    float exposureScale = pow(2.0, exposureValue);
    vec3 rgb = image.rgb * exposureScale;
    float sourceLuma = max(dot(rgb, coefficients), 0.0);
    float tone = encoded_perceptual_luma(sourceLuma);
    float pivot = encoded_perceptual_luma(0.18);
    float contrastSlope = pow(max(0.01, contrastValue), 1.2);

    if (abs(contrastValue - 1.0) > 1.0e-6) {
        tone = pivot + ((tone - pivot) * contrastSlope);
    }

    float shadowAmount = clamp(shadowsValue / 2.0, -1.0, 1.0);
    float highlightAmount = clamp(highlightsValue / 2.0, -1.0, 1.0);
    float shadowMask = 1.0 - smoothstep_ci(0.16, 0.60, tone);
    float highlightMask = smoothstep_ci(0.40, 0.92, tone);

    if (abs(shadowAmount) > 1.0e-6) {
        float strength = shadowAmount >= 0.0 ? 0.18 : 0.16;
        tone += shadowAmount * strength * pow(shadowMask, 1.2);
    }

    if (abs(highlightAmount) > 1.0e-6) {
        float strength = highlightAmount >= 0.0 ? 0.15 : 0.20;
        tone += highlightAmount * strength * pow(highlightMask, 1.05);
    }

    float targetLuma = decoded_perceptual_luma(tone);
    if (highlightAmount > 1.0e-6) {
        float extended = targetLuma * (1.0 + (0.35 * highlightAmount));
        float compressedHighlights = compress_highlights(extended, 0.82, 0.45 * highlightAmount);
        targetLuma = mix(targetLuma, compressedHighlights, highlightMask);
    } else if (highlightAmount < -1.0e-6) {
        float recovered = compress_highlights(targetLuma, 0.34, abs(highlightAmount) * 2.8);
        targetLuma = mix(targetLuma, recovered, highlightMask);
    }

    float filmicStrength = clamp(filmicValue, 0.0, 2.5);
    if (filmicStrength > 1.0e-6) {
        targetLuma = compress_highlights(max(targetLuma, 0.0), 0.64, filmicStrength);
    }

    vec3 resultRGB = remap_luma(rgb, sourceLuma, targetLuma);
    return vec4(resultRGB, image.a);
}
""")
    private let processingQueue = DispatchQueue(label: "CoreImageProcessor.processingQueue")
    private let rawPassthroughContext: CIContext

    private init() {
        let options: [CIContextOption: Any] = [
            .cacheIntermediates: false,
            .workingColorSpace: NSNull(),
            .outputColorSpace: NSNull()
        ]

        if let metalDevice {
            rawPassthroughContext = CIContext(mtlDevice: metalDevice, options: options)
        } else {
            rawPassthroughContext = CIContext(options: options)
        }
    }

    func applyAdjustments(
        _ adjustments: ColorAdjustments,
        lutURL: URL? = nil,
        sourceSignalSpace: SignalSpace? = nil,
        timeSeconds: Double? = nil,
        renderQuality: ColorPipelineRenderQuality = .preview,
        to image: CIImage
    ) -> CIImage {
        processingQueue.sync {
            _ = timeSeconds
            _ = sourceSignalSpace
            let pipeline = colorPipeline(for: adjustments)
            _ = managedContext(working: pipeline.working, output: pipeline.output)
            let resolvedSourceSignalSpace: SignalSpace = .rec709
            let normalizedSourceImage = image
            let importedDescriptor = lutURL.map { ImportedLUTManager.shared.descriptor(for: $0) }
            let baseWorkingSourceSignalSpace = resolvedSourceSignalSpace

            let baseWorkingImage: CIImage? = {
                return convertSourceImageToWorkingSpace(
                    normalizedSourceImage,
                    sourceSignalSpace: resolvedSourceSignalSpace,
                    workingSpace: pipeline.working
                )
            }()

            var currentImage = baseWorkingImage
            var appliedPrimaryTonePreTechnicalLUT = false
            if let lutURL, let descriptor = importedDescriptor {
                if descriptor.role == .technicalTransform,
                   adjustments.hasDirectPrimaryToneAdjustments,
                   let baseWorkingImage {
                    let preLUTWorkingImage = applyDirectPrimaryToneControls(
                        baseWorkingImage,
                        adjustments: adjustments,
                        workingSpace: pipeline.working
                    )

                    switch applyTechnicalImportedLUT(
                        workingImage: preLUTWorkingImage,
                        descriptor: descriptor,
                        workingSpace: pipeline.working,
                        lutURL: lutURL
                    ) {
                    case let .success(lutWorkingImage):
                        currentImage = lutWorkingImage
                        appliedPrimaryTonePreTechnicalLUT = true
                    case let .failure(error):
                        logLUTPipelineError(error, lutURL: lutURL)
                    }
                }

                if !appliedPrimaryTonePreTechnicalLUT {
                    switch applyImportedLUT(
                        sourceImage: normalizedSourceImage,
                        sourceSignalSpace: resolvedSourceSignalSpace,
                        descriptor: descriptor,
                        workingSpace: pipeline.working,
                        lutURL: lutURL
                    ) {
                    case let .success(lutWorkingImage):
                        currentImage = lutWorkingImage
                    case let .failure(error):
                        logLUTPipelineError(error, lutURL: lutURL)
                    }
                }
            }

            guard var currentImage else {
                logSourcePipelineError(
                    sourceSignalSpace: baseWorkingSourceSignalSpace,
                    workingSpace: pipeline.working
                )
                return image
            }

            let cubeDimension = lutDimension(for: renderQuality, extent: image.extent)
            let generatedLUTAdjustments = adjustments.generatedLUTAdjustments
            if let lutFilter = LUTGenerator.shared.filter(for: generatedLUTAdjustments, dimension: cubeDimension) {
                lutFilter.setValue(currentImage, forKey: kCIInputImageKey)
                if let out = lutFilter.outputImage {
                    currentImage = out
                }
            }

            if !appliedPrimaryTonePreTechnicalLUT {
                currentImage = applyDirectPrimaryToneControls(
                    currentImage,
                    adjustments: adjustments,
                    workingSpace: pipeline.working
                )
            }

            if adjustments.clarity > 0.001 {
                currentImage = applyProfessionalClarity(currentImage, amount: adjustments.clarity)
            } else if adjustments.clarity < -0.001 {
                noiseReductionFilter?.setValue(currentImage, forKey: kCIInputImageKey)
                noiseReductionFilter?.setValue(abs(adjustments.clarity) * 0.08, forKey: "inputNoiseLevel")
                noiseReductionFilter?.setValue(0.0, forKey: "inputSharpness")
                if let out = noiseReductionFilter?.outputImage { currentImage = out }
            }

            if adjustments.sharpness > 0 {
                sharpenFilter?.setValue(currentImage, forKey: kCIInputImageKey)
                // Slightly stronger response so useful detail appears earlier on the slider.
                sharpenFilter?.setValue(adjustments.sharpness * 1.75, forKey: kCIInputSharpnessKey)
                if let out = sharpenFilter?.outputImage { currentImage = out }
            }

            if adjustments.softBlur > 0.001 {
                let blurNormalized = min(max(adjustments.softBlur / 10.0, 0.0), 1.0)
                bloomFilter?.setValue(currentImage, forKey: kCIInputImageKey)
                bloomFilter?.setValue(2.0 + (blurNormalized * 22.0), forKey: kCIInputRadiusKey)
                bloomFilter?.setValue(blurNormalized * 0.85, forKey: kCIInputIntensityKey)
                if let out = bloomFilter?.outputImage {
                    currentImage = out.cropped(to: image.extent)
                }
            }

            if adjustments.vignette > 0.001 {
                let vignetteNormalized = min(max(adjustments.vignette / 2.0, 0.0), 1.0)
                let vignetteEased = pow(vignetteNormalized, 1.10)
                let center = CGPoint(x: image.extent.midX, y: image.extent.midY)
                let cornerDistance = hypot(image.extent.width, image.extent.height) * 0.5
                let innerRadius = cornerDistance * (1.00 - (0.60 * vignetteEased))
                let outerRadius = cornerDistance * (1.08 - (0.10 * vignetteEased))

                vignetteGradientFilter?.setValue(CIVector(cgPoint: center), forKey: "inputCenter")
                vignetteGradientFilter?.setValue(innerRadius, forKey: "inputRadius0")
                vignetteGradientFilter?.setValue(outerRadius, forKey: "inputRadius1")
                vignetteGradientFilter?.setValue(CIColor(red: 0, green: 0, blue: 0, alpha: 0), forKey: "inputColor0")
                vignetteGradientFilter?.setValue(CIColor(red: 1, green: 1, blue: 1, alpha: 1), forKey: "inputColor1")
                let vignetteMask = (vignetteGradientFilter?.outputImage ?? CIImage(color: .clear)).cropped(to: image.extent)

                let darkenScale = max(0.15, 1.0 - (0.80 * pow(vignetteNormalized, 1.05)))
                vignetteDarkenFilter?.setValue(currentImage, forKey: kCIInputImageKey)
                vignetteDarkenFilter?.setValue(CIVector(x: darkenScale, y: 0, z: 0, w: 0), forKey: "inputRVector")
                vignetteDarkenFilter?.setValue(CIVector(x: 0, y: darkenScale, z: 0, w: 0), forKey: "inputGVector")
                vignetteDarkenFilter?.setValue(CIVector(x: 0, y: 0, z: darkenScale, w: 0), forKey: "inputBVector")
                vignetteDarkenFilter?.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
                vignetteDarkenFilter?.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputBiasVector")
                let darkened = vignetteDarkenFilter?.outputImage ?? currentImage

                vignetteBlendFilter?.setValue(darkened, forKey: kCIInputImageKey)
                vignetteBlendFilter?.setValue(currentImage, forKey: kCIInputBackgroundImageKey)
                vignetteBlendFilter?.setValue(vignetteMask, forKey: kCIInputMaskImageKey)
                if let out = vignetteBlendFilter?.outputImage {
                    currentImage = out.cropped(to: image.extent)
                }
            }

            return convertWorkingImageToOutputSpace(
                currentImage,
                workingSpace: pipeline.working,
                outputSpace: pipeline.output
            ) ?? currentImage
        }
    }

    func applyLUT(
        image: CIImage,
        lutURL: URL,
        inputSpace: ColorSpace,
        workingSpace: ColorSpace,
        outputSpace: ColorSpace
    ) -> CIImage {
        processingQueue.sync {
            _ = managedContext(working: workingSpace, output: outputSpace)
            let descriptor = ImportedLUTManager.shared.descriptor(for: lutURL)
            let resolvedSourceSignalSpace: SignalSpace = .rec709
            let normalizedSourceImage = image

            switch applyImportedLUT(
                sourceImage: normalizedSourceImage,
                sourceSignalSpace: resolvedSourceSignalSpace,
                descriptor: descriptor,
                workingSpace: workingSpace,
                lutURL: lutURL
            ) {
            case let .success(lutWorkingImage):
                return convertWorkingImageToOutputSpace(
                    lutWorkingImage,
                    workingSpace: workingSpace,
                    outputSpace: outputSpace
                ) ?? lutWorkingImage
            case let .failure(error):
                logLUTPipelineError(error, lutURL: lutURL)
                guard let workingImage = convertSourceImageToWorkingSpace(
                    normalizedSourceImage,
                    sourceSignalSpace: resolvedSourceSignalSpace,
                    workingSpace: workingSpace
                ) else {
                    logSourcePipelineError(
                        sourceSignalSpace: resolvedSourceSignalSpace,
                        workingSpace: workingSpace
                    )
                    return image
                }
                return convertWorkingImageToOutputSpace(
                    workingImage,
                    workingSpace: workingSpace,
                    outputSpace: outputSpace
                ) ?? workingImage
            }
        }
    }

    func renderContext(for adjustments: ColorAdjustments) -> CIContext {
        _ = adjustments
        return managedContext(working: .linearSRGB, output: .rec709)
    }

    func renderContext(workingSpace: ColorSpace, outputSpace: ColorSpace) -> CIContext {
        managedContext(working: workingSpace, output: outputSpace)
    }

    private func managedContext(working: ColorSpace, output: ColorSpace) -> CIContext {
        let key = ContextKey(working: working, output: output)
        if let cached = contextCacheQueue.sync(execute: { contextCache[key] }) {
            return cached
        }

        let workingColorSpace = working.cgColorSpace ?? CGColorSpace(name: CGColorSpace.linearSRGB)
        let outputColorSpace = output.cgColorSpace ?? CGColorSpace(name: CGColorSpace.itur_709)
        let options: [CIContextOption: Any] = [
            .cacheIntermediates: false,
            .workingColorSpace: workingColorSpace as Any,
            .outputColorSpace: outputColorSpace as Any
        ]
        let context: CIContext
        if let metalDevice {
            context = CIContext(mtlDevice: metalDevice, options: options)
        } else {
            context = CIContext(options: options)
        }

        contextCacheQueue.sync {
            contextCache[key] = context
        }
        return context
    }

    private func colorPipeline(for adjustments: ColorAdjustments) -> ColorPipelineConfiguration {
        _ = adjustments
        return ColorPipelineConfiguration(working: .linearSRGB, output: .rec709)
    }

    private func convertSourceImageToWorkingSpace(
        _ image: CIImage,
        sourceSignalSpace: SignalSpace,
        workingSpace: ColorSpace
    ) -> CIImage? {
        let inputTransform = InputTransform(source: sourceSignalSpace, destinationWorkingSpace: SignalSpace(workingSpace))
        return inputTransform.process(image)
    }

    private func applyImportedLUT(
        sourceImage: CIImage,
        sourceSignalSpace: SignalSpace,
        descriptor: ImportedLUTDescriptor,
        workingSpace: ColorSpace,
        lutURL: URL
    ) -> Result<CIImage, LUTPipelineError> {
        switch descriptor.role {
        case .creative:
            return applyCreativeImportedLUT(
                sourceImage: sourceImage,
                sourceSignalSpace: sourceSignalSpace,
                descriptor: descriptor,
                workingSpace: workingSpace,
                lutURL: lutURL
            )
        case .technicalTransform:
            return applyTechnicalImportedLUT(
                sourceImage: sourceImage,
                sourceSignalSpace: sourceSignalSpace,
                descriptor: descriptor,
                workingSpace: workingSpace,
                lutURL: lutURL
            )
        }
    }

    private func applyCreativeImportedLUT(
        sourceImage: CIImage,
        sourceSignalSpace: SignalSpace,
        descriptor: ImportedLUTDescriptor,
        workingSpace: ColorSpace,
        lutURL: URL
    ) -> Result<CIImage, LUTPipelineError> {
        guard let lutSpace = descriptor.creativeLUTSpace else {
            return .failure(.missingCreativeLUTSpace)
        }
        let workingSignalSpace = SignalSpace(workingSpace)

        guard let workingImage = convertSourceImageToWorkingSpace(
            sourceImage,
            sourceSignalSpace: sourceSignalSpace,
            workingSpace: workingSpace
        ) else {
            return .failure(.unsupportedSourceToWorkingTransform(sourceSignalSpace, workingSpace))
        }

        let lutInputImage: CIImage
        if lutSpace == workingSignalSpace {
            lutInputImage = workingImage
        } else {
            let transform = OutputTransform(sourceWorkingSpace: workingSignalSpace, destination: lutSpace)
            guard let converted = transform.process(workingImage) else {
                return .failure(.unsupportedSourceToLUTTransform(SignalSpace(workingSpace), lutSpace))
            }
            lutInputImage = converted
        }

        let lutOutput = ImportedLUTManager.shared.applyCube(
            at: lutURL,
            to: lutInputImage
        ) ?? lutInputImage

        if lutSpace == workingSignalSpace {
            return .success(lutOutput)
        }

        let transform = InputTransform(source: lutSpace, destinationWorkingSpace: workingSignalSpace)
        guard let workingResult = transform.process(lutOutput) else {
            return .failure(.unsupportedLUTOutputToWorkingTransform(lutSpace, workingSpace))
        }

        return .success(workingResult)
    }

    private func applyTechnicalImportedLUT(
        sourceImage: CIImage,
        sourceSignalSpace: SignalSpace,
        descriptor: ImportedLUTDescriptor,
        workingSpace: ColorSpace,
        lutURL: URL
    ) -> Result<CIImage, LUTPipelineError> {
        guard let lutInputSpace = descriptor.inputSignalSpace,
              let lutOutputSpace = descriptor.outputSignalSpace else {
            return .failure(.missingTechnicalLUTSpaces)
        }

        guard let lutInputImage = convertSourceImageToLUTInputSpace(
            sourceImage,
            sourceSignalSpace: sourceSignalSpace,
            lutInputSpace: lutInputSpace,
            workingSpace: workingSpace
        ) else {
            return .failure(.unsupportedSourceToLUTTransform(sourceSignalSpace, lutInputSpace))
        }

        let lutOutput = ImportedLUTManager.shared.applyCube(
            at: lutURL,
            to: lutInputImage
        ) ?? lutInputImage

        guard let workingResult = convertLUTOutputImageToWorkingSpace(
            lutOutput,
            lutOutputSpace: lutOutputSpace,
            workingSpace: workingSpace
        ) else {
            return .failure(.unsupportedLUTOutputToWorkingTransform(lutOutputSpace, workingSpace))
        }

        return .success(workingResult)
    }

    private func applyTechnicalImportedLUT(
        workingImage: CIImage,
        descriptor: ImportedLUTDescriptor,
        workingSpace: ColorSpace,
        lutURL: URL
    ) -> Result<CIImage, LUTPipelineError> {
        guard let lutInputSpace = descriptor.inputSignalSpace,
              let lutOutputSpace = descriptor.outputSignalSpace else {
            return .failure(.missingTechnicalLUTSpaces)
        }

        let workingSignalSpace = SignalSpace(workingSpace)
        let lutInputImage: CIImage
        if lutInputSpace == workingSignalSpace {
            lutInputImage = workingImage
        } else {
            let transform = OutputTransform(
                sourceWorkingSpace: workingSignalSpace,
                destination: lutInputSpace
            )
            guard let converted = transform.process(workingImage) else {
                return .failure(.unsupportedSourceToLUTTransform(workingSignalSpace, lutInputSpace))
            }
            lutInputImage = converted
        }

        let lutOutput = ImportedLUTManager.shared.applyCube(
            at: lutURL,
            to: lutInputImage
        ) ?? lutInputImage

        if lutOutputSpace == workingSignalSpace {
            return .success(lutOutput)
        }

        guard let workingResult = convertLUTOutputImageToWorkingSpace(
            lutOutput,
            lutOutputSpace: lutOutputSpace,
            workingSpace: workingSpace
        ) else {
            return .failure(.unsupportedLUTOutputToWorkingTransform(lutOutputSpace, workingSpace))
        }

        return .success(workingResult)
    }

    private func convertSourceImageToLUTInputSpace(
        _ image: CIImage,
        sourceSignalSpace: SignalSpace,
        lutInputSpace: SignalSpace,
        workingSpace: ColorSpace
    ) -> CIImage? {
        if sourceSignalSpace == lutInputSpace {
            return image
        }

        let transform = InputTransform(
            source: sourceSignalSpace,
            destinationWorkingSpace: lutInputSpace
        )
        return transform.process(image)
    }

    private func convertLUTOutputImageToWorkingSpace(
        _ image: CIImage,
        lutOutputSpace: SignalSpace,
        workingSpace: ColorSpace
    ) -> CIImage? {
        let transform = InputTransform(
            source: lutOutputSpace,
            destinationWorkingSpace: SignalSpace(workingSpace)
        )
        return transform.process(image)
    }

    private func convertWorkingImageToOutputSpace(
        _ image: CIImage,
        workingSpace: ColorSpace,
        outputSpace: ColorSpace
    ) -> CIImage? {
        let outputTransform = OutputTransform(sourceWorkingSpace: SignalSpace(workingSpace), destination: SignalSpace(outputSpace))
        return outputTransform.process(image)
    }

    private func logLUTPipelineError(_ error: LUTPipelineError, lutURL: URL) {
        print("LUT pipeline skipped '\(lutURL.lastPathComponent)': \(error.description)")
    }

    private func logSourcePipelineError(
        sourceSignalSpace: SignalSpace,
        workingSpace: ColorSpace
    ) {
        print(
            "Color pipeline skipped grading: missing explicit transform from \(sourceSignalSpace.displayName) to working space \(workingSpace.rawValue)."
        )
    }

    private func lutDimension(for quality: ColorPipelineRenderQuality, extent: CGRect) -> Int {
        switch quality {
        case .preview:
            return 17
        case .export:
            let maxDimension = max(extent.width, extent.height)
            return maxDimension >= 3000 ? 65 : 33
        }
    }

    private func normalizeManagedSourceImageIfNeeded(
        _ image: CIImage,
        sourceSignalSpace: SignalSpace
    ) -> CIImage {
        guard sourceSignalSpace.definition?.isLogEncoded == true,
              image.colorSpace != nil,
              let pixelBuffer = makeRawPixelBuffer(for: image.extent) else {
            return image
        }

        rawPassthroughContext.render(
            image,
            to: pixelBuffer,
            bounds: image.extent,
            colorSpace: nil
        )

        var rawImage = CIImage(
            cvPixelBuffer: pixelBuffer,
            options: [.colorSpace: NSNull()]
        )

        if image.extent.origin != .zero {
            rawImage = rawImage.transformed(
                by: CGAffineTransform(
                    translationX: image.extent.origin.x,
                    y: image.extent.origin.y
                )
            )
        }

        return rawImage.cropped(to: image.extent)
    }

    private func makeRawPixelBuffer(for extent: CGRect) -> CVPixelBuffer? {
        let key = RawPixelBufferPoolKey(
            width: max(Int(extent.width.rounded(.up)), 1),
            height: max(Int(extent.height.rounded(.up)), 1)
        )

        let pool: CVPixelBufferPool
        if let cached = rawPixelBufferPools[key] {
            pool = cached
        } else {
            let poolAttributes: [String: Any] = [
                kCVPixelBufferPoolMinimumBufferCountKey as String: 3
            ]
            let pixelBufferAttributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_64RGBAHalf),
                kCVPixelBufferWidthKey as String: key.width,
                kCVPixelBufferHeightKey as String: key.height,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]

            var createdPool: CVPixelBufferPool?
            let status = CVPixelBufferPoolCreate(
                kCFAllocatorDefault,
                poolAttributes as CFDictionary,
                pixelBufferAttributes as CFDictionary,
                &createdPool
            )

            guard status == kCVReturnSuccess, let createdPool else {
                return nil
            }

            rawPixelBufferPools[key] = createdPool
            pool = createdPool
        }

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault,
            pool,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess else {
            return nil
        }

        return pixelBuffer
    }

    private func applyDirectPrimaryToneControls(
        _ image: CIImage,
        adjustments: ColorAdjustments,
        workingSpace: ColorSpace
    ) -> CIImage {
        guard adjustments.hasDirectPrimaryToneAdjustments,
              let primaryToneKernel else {
            return image
        }

        let coefficients = lumaCoefficients(for: workingSpace)
        let arguments: [Any] = [
            image,
            adjustments.exposure,
            adjustments.contrast,
            adjustments.highlights,
            adjustments.shadows,
            adjustments.filmicHighlightRolloff,
            CIVector(x: coefficients.red, y: coefficients.green, z: coefficients.blue)
        ]

        return primaryToneKernel.apply(extent: image.extent, arguments: arguments) ?? image
    }

    private func lumaCoefficients(for workingSpace: ColorSpace) -> (red: Double, green: Double, blue: Double) {
        switch workingSpace {
        case .displayP3:
            return (0.22897456, 0.69173852, 0.07928691)
        case .bt2020:
            return (0.26270021, 0.67799807, 0.05930172)
        case .acescg:
            return (0.27222872, 0.67408177, 0.05368952)
        case .rec709, .linearSRGB:
            return (0.2126729, 0.7151522, 0.0721750)
        }
    }

    private func applyProfessionalClarity(_ image: CIImage, amount: Double) -> CIImage {
        let clampedAmount = min(max(amount, 0.0), 1.0)
        guard clampedAmount > 0.0001 else { return image }

        let base = image.cropped(to: image.extent)
        let radius = 1.2 + (clampedAmount * 3.2)
        gaussianBlurFilter?.setValue(base, forKey: kCIInputImageKey)
        gaussianBlurFilter?.setValue(radius, forKey: kCIInputRadiusKey)
        guard let blurred = gaussianBlurFilter?.outputImage?.cropped(to: image.extent) else {
            return image
        }

        // Build a centered high-pass around 0.5 for a neutral soft-light overlay:
        // overlay = (base - blurred) + 0.5
        let negativeBlurShifted = blurred.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: -1, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: -1, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: -1, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0.5, y: 0.5, z: 0.5, w: 0)
        ])
        let centeredHighPass = base
            .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: negativeBlurShifted])
            .cropped(to: image.extent)

        let detailGain = 1.0 + (clampedAmount * 2.2)
        let detailBias = 0.5 * (1.0 - detailGain)
        let detailOverlay = centeredHighPass
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: detailGain, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: detailGain, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: detailGain, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: detailBias, y: detailBias, z: detailBias, w: 0)
            ])
            .cropped(to: image.extent)

        let softLightEnhanced = detailOverlay
            .applyingFilter("CISoftLightBlendMode", parameters: [
                kCIInputBackgroundImageKey: base
            ])
            .cropped(to: image.extent)

        // Midtone gate: mask = 4Y(1-Y), smoothly blurred to avoid hard transitions.
        let luma = base.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            "inputGVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            "inputBVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
        ])
        let bellMask = luma.applyingFilter("CIColorPolynomial", parameters: [
            "inputRedCoefficients": CIVector(x: 0, y: 4, z: -4, w: 0),
            "inputGreenCoefficients": CIVector(x: 0, y: 4, z: -4, w: 0),
            "inputBlueCoefficients": CIVector(x: 0, y: 4, z: -4, w: 0),
            "inputAlphaCoefficients": CIVector(x: 0, y: 0, z: 0, w: 1)
        ])
        let maskStrength = 0.18 + (clampedAmount * 0.82)
        let shapedMask = bellMask
            .applyingFilter("CIGammaAdjust", parameters: ["inputPower": 1.35])
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 6.0])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: maskStrength, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: maskStrength, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: maskStrength, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
            ])
            .cropped(to: image.extent)

        return softLightEnhanced
            .applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: base,
                kCIInputMaskImageKey: shapedMask
            ])
            .cropped(to: image.extent)
    }
}
