import Foundation
import CoreImage
import AVFoundation
import CoreGraphics

nonisolated enum ColorPipelineRenderQuality {
    case preview
    case export
}

nonisolated class CoreImageProcessor {
    static let shared = CoreImageProcessor()

    private struct ContextKey: Hashable {
        let working: WorkingColorSpaceProfile
        let output: ColorSpaceProfile
    }

    private var contextCache: [ContextKey: CIContext] = [:]
    private let contextCacheQueue = DispatchQueue(label: "CoreImageProcessor.contextCacheQueue")

    private let noiseReductionFilter = CIFilter(name: "CINoiseReduction")
    private let sharpenFilter = CIFilter(name: "CISharpenLuminance")
    private let bloomFilter = CIFilter(name: "CIBloom")
    private let vignetteGradientFilter = CIFilter(name: "CIRadialGradient")
    private let vignetteDarkenFilter = CIFilter(name: "CIColorMatrix")
    private let vignetteBlendFilter = CIFilter(name: "CIBlendWithMask")
    private let gaussianBlurFilter = CIFilter(name: "CIGaussianBlur")
    private let processingQueue = DispatchQueue(label: "CoreImageProcessor.processingQueue")

    func applyAdjustments(
        _ adjustments: ColorAdjustments,
        lutURL: URL? = nil,
        timeSeconds: Double? = nil,
        renderQuality: ColorPipelineRenderQuality = .preview,
        to image: CIImage
    ) -> CIImage {
        processingQueue.sync {
            _ = timeSeconds
            _ = managedContext(
                working: adjustments.workingColorSpace,
                output: adjustments.outputColorSpace
            )

            var currentImage = image

            if let lutURL,
               let imported = ImportedLUTManager.shared.applyCube(at: lutURL, to: currentImage) {
                currentImage = imported
            }

            let cubeDimension = lutDimension(for: renderQuality, extent: image.extent)
            if let lutFilter = LUTGenerator.shared.filter(for: adjustments, dimension: cubeDimension) {
                lutFilter.setValue(currentImage, forKey: kCIInputImageKey)
                if let out = lutFilter.outputImage {
                    currentImage = out
                }
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

            return currentImage
        }
    }

    private func managedContext(
        working: WorkingColorSpaceProfile,
        output: ColorSpaceProfile
    ) -> CIContext {
        let key = ContextKey(working: working, output: output)
        if let cached = contextCacheQueue.sync(execute: { contextCache[key] }) {
            return cached
        }

        let workingColorSpace = cgWorkingColorSpace(for: working) ?? CGColorSpace(name: CGColorSpace.linearSRGB)
        let outputColorSpace = cgOutputColorSpace(for: output) ?? CGColorSpace(name: CGColorSpace.itur_709)

        let context = CIContext(options: [
            .cacheIntermediates: false,
            .workingColorSpace: workingColorSpace as Any,
            .outputColorSpace: outputColorSpace as Any
        ])

        contextCacheQueue.sync {
            contextCache[key] = context
        }
        return context
    }

    private func cgWorkingColorSpace(for profile: WorkingColorSpaceProfile) -> CGColorSpace? {
        switch profile {
        case .linearSRGB:
            return CGColorSpace(name: CGColorSpace.linearSRGB)
        case .acescg:
            return CGColorSpace(name: CGColorSpace.acescgLinear)
        }
    }

    private func cgOutputColorSpace(for profile: ColorSpaceProfile) -> CGColorSpace? {
        switch profile {
        case .rec709:
            return CGColorSpace(name: CGColorSpace.itur_709)
        case .displayP3:
            return CGColorSpace(name: CGColorSpace.displayP3)
        case .bt2020:
            return CGColorSpace(name: CGColorSpace.itur_2020)
        }
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
