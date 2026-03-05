import Foundation
import CoreImage
import CoreMedia
import AVFoundation

nonisolated class CoreImageProcessor {
    static let shared = CoreImageProcessor()
    private let context = CIContext(options: [.cacheIntermediates: false])
    
    // Core filter instances for reuse
    private let exposureFilter = CIFilter(name: "CIExposureAdjust")
    private let colorControlsFilter = CIFilter(name: "CIColorControls")
    private let vibranceFilter = CIFilter(name: "CIVibrance")
    private let hueAdjustFilter = CIFilter(name: "CIHueAdjust")
    private let highlightShadowFilter = CIFilter(name: "CIHighlightShadowAdjust")
    private let unsharpMaskFilter = CIFilter(name: "CIUnsharpMask")
    private let noiseReductionFilter = CIFilter(name: "CINoiseReduction")
    private let sharpenFilter = CIFilter(name: "CISharpenLuminance")
    private let vignetteFilter = CIFilter(name: "CIVignette")
    // Simplified blur using a basic Gaussian
    private let blurFilter = CIFilter(name: "CIGaussianBlur")
    private let processingQueue = DispatchQueue(label: "CoreImageProcessor.processingQueue")
    
    func applyAdjustments(_ adjustments: ColorAdjustments, to image: CIImage) -> CIImage {
        processingQueue.sync {
            var currentImage = image
            
            // 1. Exposure
            if adjustments.exposure != 0 {
                exposureFilter?.setValue(currentImage, forKey: kCIInputImageKey)
                exposureFilter?.setValue(adjustments.exposure, forKey: kCIInputEVKey)
                if let out = exposureFilter?.outputImage { currentImage = out }
            }
            
            // 2. Highlights & Shadows
            if adjustments.highlights != 0 || adjustments.shadows != 0 {
                highlightShadowFilter?.setValue(currentImage, forKey: kCIInputImageKey)
                // CIHighlightShadowAdjust maps highlights strictly 0-1, shadows -1-1
                highlightShadowFilter?.setValue(1.0 + (adjustments.highlights * 0.5), forKey: "inputHighlightAmount")
                highlightShadowFilter?.setValue(adjustments.shadows, forKey: "inputShadowAmount")
                if let out = highlightShadowFilter?.outputImage { currentImage = out }
            }
            
            // 3. Color Controls (Contrast, Saturation)
            if adjustments.contrast != 1.0 || adjustments.saturation != 1.0 {
                colorControlsFilter?.setValue(currentImage, forKey: kCIInputImageKey)
                // Tune contrast sensitivity to avoid harsh response around the center.
                let contrastDelta = adjustments.contrast - 1.0
                let tunedContrast = 1.0 + (contrastDelta * 0.45)
                colorControlsFilter?.setValue(tunedContrast, forKey: kCIInputContrastKey)
                colorControlsFilter?.setValue(adjustments.saturation, forKey: kCIInputSaturationKey)
                if let out = colorControlsFilter?.outputImage { currentImage = out }
            }
            
            // 4. Vibrance
            if adjustments.vibrance != 0 {
                vibranceFilter?.setValue(currentImage, forKey: kCIInputImageKey)
                vibranceFilter?.setValue(adjustments.vibrance, forKey: kCIInputAmountKey)
                if let out = vibranceFilter?.outputImage { currentImage = out }
            }
            
            // 5. Basic Hue Shift
            if adjustments.hue != 0 {
                hueAdjustFilter?.setValue(currentImage, forKey: kCIInputImageKey)
                // Slider is normalized -1...1, mapped to full rotation in radians.
                hueAdjustFilter?.setValue(adjustments.hue * (Double.pi * 2.0), forKey: kCIInputAngleKey)
                if let out = hueAdjustFilter?.outputImage { currentImage = out }
            }
            
            // 6. True HSL + Color Grading (3D LUT)
            if let lutFilter = LUTGenerator.shared.filter(for: adjustments) {
                lutFilter.setValue(currentImage, forKey: kCIInputImageKey)
                if let out = lutFilter.outputImage { currentImage = out }
            }
            
            // 7. Clarity (local contrast/detail)
            if adjustments.clarity > 0.001 {
                unsharpMaskFilter?.setValue(currentImage, forKey: kCIInputImageKey)
                unsharpMaskFilter?.setValue(2.0 + (adjustments.clarity * 3.5), forKey: kCIInputRadiusKey)
                unsharpMaskFilter?.setValue(adjustments.clarity * 0.9, forKey: kCIInputIntensityKey)
                if let out = unsharpMaskFilter?.outputImage { currentImage = out }
            } else if adjustments.clarity < -0.001 {
                noiseReductionFilter?.setValue(currentImage, forKey: kCIInputImageKey)
                noiseReductionFilter?.setValue(abs(adjustments.clarity) * 0.08, forKey: "inputNoiseLevel")
                noiseReductionFilter?.setValue(0.0, forKey: "inputSharpness")
                if let out = noiseReductionFilter?.outputImage { currentImage = out }
            }
            
            // 8. Sharpness
            if adjustments.sharpness > 0 {
                sharpenFilter?.setValue(currentImage, forKey: kCIInputImageKey)
                sharpenFilter?.setValue(adjustments.sharpness, forKey: kCIInputSharpnessKey)
                if let out = sharpenFilter?.outputImage { currentImage = out }
            }
            
            // 9. Effects (Blur & Vignette)
            if adjustments.softBlur > 0 {
                blurFilter?.setValue(currentImage, forKey: kCIInputImageKey)
                blurFilter?.setValue(adjustments.softBlur * 5.0, forKey: kCIInputRadiusKey)
                if let out = blurFilter?.outputImage {
                    // Crop back to original extent to avoid blurred edges leaking
                    currentImage = out.cropped(to: image.extent)
                }
            }
            
            if adjustments.vignette > 0 {
                vignetteFilter?.setValue(currentImage, forKey: kCIInputImageKey)
                vignetteFilter?.setValue(adjustments.vignette, forKey: kCIInputIntensityKey)
                vignetteFilter?.setValue(image.extent.width / 2, forKey: kCIInputRadiusKey)
                if let out = vignetteFilter?.outputImage { currentImage = out }
            }
            
            return currentImage
        }
    }
}
