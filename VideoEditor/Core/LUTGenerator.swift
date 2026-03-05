import Foundation
import CoreImage

nonisolated class LUTGenerator {
    static let shared = LUTGenerator()
    
    // Size of the 3D LUT (a standard size for video is 33x33x33, but 17 is faster for live preview)
    let dimension = 17
    
    // We cache the generated filter to avoid re-calculating the 3D math on every frame if adjustments haven't changed
    private var cachedAdjustments: ColorAdjustments?
    private var cachedFilter: CIFilter?
    private let cacheQueue = DispatchQueue(label: "LUTGenerator.cacheQueue")
    
    func filter(for adjustments: ColorAdjustments) -> CIFilter? {
        cacheQueue.sync {
            // If settings haven't changed since last gen, return cached
            if cachedAdjustments == adjustments, let cached = cachedFilter {
                return cached
            }
            
            if !hasHSLOrGradingEdits(in: adjustments) {
                cachedAdjustments = adjustments
                cachedFilter = nil
                return nil
            }
            
            let cubeData = generateCubeData(for: adjustments)
            let cubeFilter = CIFilter(name: "CIColorCube")
            cubeFilter?.setValue(dimension, forKey: "inputCubeDimension")
            cubeFilter?.setValue(cubeData, forKey: "inputCubeData")
            cubeFilter?.setValue(false, forKey: "inputExtrapolate")
            
            cachedAdjustments = adjustments
            cachedFilter = cubeFilter
            return cubeFilter
        }
    }

    private func hasHSLOrGradingEdits(in adjustments: ColorAdjustments) -> Bool {
        let hasTrueHSLEdits =
            adjustments.redHSL != HSLControl() ||
            adjustments.orangeHSL != HSLControl() ||
            adjustments.yellowHSL != HSLControl() ||
            adjustments.greenHSL != HSLControl() ||
            adjustments.aquaHSL != HSLControl() ||
            adjustments.blueHSL != HSLControl() ||
            adjustments.purpleHSL != HSLControl() ||
            adjustments.magentaHSL != HSLControl()
        let hasGradingEdits =
            adjustments.globalTint.intensity > 0.0001 ||
            adjustments.shadowTint.intensity > 0.0001 ||
            adjustments.highlightTint.intensity > 0.0001
        return hasTrueHSLEdits || hasGradingEdits
    }

    private func generateCubeData(for adjustments: ColorAdjustments) -> Data {
        let cubeSize = dimension * dimension * dimension * 4
        var cube = [Float](repeating: 0, count: cubeSize)

        let channelCenters: [Double] = [0.0, 1.0 / 12.0, 1.0 / 6.0, 1.0 / 3.0, 0.5, 2.0 / 3.0, 0.75, 5.0 / 6.0]
        let channelControls: [HSLControl] = [
            adjustments.redHSL,
            adjustments.orangeHSL,
            adjustments.yellowHSL,
            adjustments.greenHSL,
            adjustments.aquaHSL,
            adjustments.blueHSL,
            adjustments.purpleHSL,
            adjustments.magentaHSL
        ]
        let tightness = clamp(adjustments.hslTightness, min: 0.20, max: 1.0)
        let looseness = 1.0 - tightness
        let hueRadius: Double = 0.095 + (0.105 * looseness)
        let saturationRadius: Double = 0.090 + (0.095 * looseness)
        // Luminance remains the most selective control, but less restrictive than before.
        let luminanceRadius: Double = 0.042 + (0.060 * looseness)
        let hueExponent: Double = 2.4 + (tightness * 1.7)
        let saturationExponent: Double = 2.2 + (tightness * 1.6)
        let luminanceExponent: Double = 3.4 + (tightness * 2.4)
        // Global gain so all HSL sliders feel stronger without changing UI ranges.
        let hueStrength: Double = 1.28
        let saturationStrength: Double = 1.32
        let luminanceStrength: Double = 1.26

        for b in 0..<dimension {
            let blue = Double(b) / Double(dimension - 1)
            for g in 0..<dimension {
                let green = Double(g) / Double(dimension - 1)
                for r in 0..<dimension {
                    let red = Double(r) / Double(dimension - 1)

                    var working = RGB(red: red, green: green, blue: blue)
                    let hsl = rgbToHSL(working)
                    var hue = hsl.h
                    var sat = hsl.s
                    let lum = hsl.l
                    let maxChannel = max(working.red, max(working.green, working.blue))
                    let minChannel = min(working.red, min(working.green, working.blue))
                    let absoluteChroma = maxChannel - minChannel
                    let chromaGate = smoothstep(edge0: 0.015, edge1: 0.20, x: absoluteChroma)
                    let lumChromaGate = smoothstep(edge0: 0.04, edge1: 0.24, x: absoluteChroma)
                    let shadowGuard = smoothstep(edge0: 0.02, edge1: 0.10, x: lum)
                    let highlightGuard = 1.0 - smoothstep(edge0: 0.95, edge1: 0.995, x: lum)
                    let luminanceToneGate = clamp(shadowGuard * highlightGuard, min: 0.0, max: 1.0)

                    var hueWeightedSum = 0.0
                    var hueWeightTotal = 0.0
                    var satWeightedSum = 0.0
                    var satWeightTotal = 0.0
                    var lumWeightedAccum = 0.0
                    var lumWeightTotal = 0.0

                    for idx in 0..<channelCenters.count {
                        let center = channelCenters[idx]
                        let control = channelControls[idx]
                        let distance = circularDistance(hue, center)
                        
                        if abs(control.hue) > 0.0001 {
                            let weight = localWeight(distance: distance, radius: hueRadius, exponent: hueExponent)
                            if weight > 0 {
                                hueWeightedSum += weight * control.hue
                                hueWeightTotal += weight
                            }
                        }
                        
                        let satDelta = control.saturation - 1.0
                        if abs(satDelta) > 0.0001 {
                            let weight = localWeight(distance: distance, radius: saturationRadius, exponent: saturationExponent)
                            if weight > 0 {
                                satWeightedSum += weight * satDelta
                                satWeightTotal += weight
                            }
                        }
                        
                        if abs(control.luminance) > 0.0001 {
                            let weight = localWeight(distance: distance, radius: luminanceRadius, exponent: luminanceExponent)
                            if weight > 0 {
                                lumWeightedAccum += weight * control.luminance
                                lumWeightTotal += weight
                            }
                        }
                    }

                    if hueWeightTotal > 0.0001 {
                        let normalizedHueShift = hueWeightedSum / hueWeightTotal
                        let hueInfluence = pow(clamp(hueWeightTotal, min: 0.0, max: 1.0), 0.75)
                        // Slider -1...1 maps to ~+-60deg shift for the selected hue family.
                        hue = wrapUnit(hue + ((normalizedHueShift * 0.185 * hueStrength) * chromaGate * hueInfluence))
                    }
                    
                    if satWeightTotal > 0.0001 {
                        let normalizedSatDelta = satWeightedSum / satWeightTotal
                        let satInfluence = pow(clamp(satWeightTotal, min: 0.0, max: 1.0), 0.80)
                        sat = clamp(sat + (normalizedSatDelta * 1.15 * saturationStrength * chromaGate * satInfluence), min: 0.0, max: 1.0)
                    }

                    working = hslToRGB(h: hue, s: sat, l: lum)
                    if lumWeightTotal > 0.0001 {
                        // Apply HSL luminance as selective brightness gain in RGB space.
                        // This keeps hue stable and prevents adding selected hue into dark neutrals.
                        let normalizedLumDelta = clamp(lumWeightedAccum / lumWeightTotal, min: -1.0, max: 1.0)
                        let hueInfluenceForLum = pow(clamp(lumWeightTotal, min: 0.0, max: 1.0), 0.95)
                        let luminanceMask = pow(lumChromaGate * luminanceToneGate * hueInfluenceForLum, 0.85)
                        let gain = pow(2.0, normalizedLumDelta * 0.78 * luminanceStrength * luminanceMask)
                        working.red = clamp(working.red * gain, min: 0.0, max: 1.0)
                        working.green = clamp(working.green * gain, min: 0.0, max: 1.0)
                        working.blue = clamp(working.blue * gain, min: 0.0, max: 1.0)
                    }
                    working = applyColorGrading(working, adjustments: adjustments)

                    let dataOffset = ((b * dimension * dimension) + (g * dimension) + r) * 4
                    cube[dataOffset + 0] = Float(clamp(working.red, min: 0, max: 1))
                    cube[dataOffset + 1] = Float(clamp(working.green, min: 0, max: 1))
                    cube[dataOffset + 2] = Float(clamp(working.blue, min: 0, max: 1))
                    cube[dataOffset + 3] = 1.0
                }
            }
        }

        return cube.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private func applyColorGrading(_ rgb: RGB, adjustments: ColorAdjustments) -> RGB {
        var output = rgb

        if adjustments.globalTint.intensity > 0.0001 {
            let globalTintRGB = colorWheelToRGB(adjustments.globalTint)
            output = mix(output, globalTintRGB, factor: adjustments.globalTint.intensity * 0.20)
        }

        let luma = output.luma

        if adjustments.shadowTint.intensity > 0.0001 {
            // Keep shadow tint focused on darker tones with less midtone spill.
            let shadowEdge1 = clamp(adjustments.shadowRange, min: 0.20, max: 0.70)
            let shadowEdge0 = max(0.01, shadowEdge1 * 0.12)
            let shadowMaskBase = 1.0 - smoothstep(edge0: shadowEdge0, edge1: shadowEdge1, x: luma)
            let shadowMask = pow(shadowMaskBase, 1.35)
            let shadowTintRGB = colorWheelToRGB(adjustments.shadowTint)
            output = mix(output, shadowTintRGB, factor: adjustments.shadowTint.intensity * 0.32 * shadowMask)
        }

        if adjustments.highlightTint.intensity > 0.0001 {
            let highlightEdge1 = clamp(adjustments.highlightRange, min: 0.55, max: 0.98)
            let highlightEdge0 = min(highlightEdge1 - 0.08, max(0.20, highlightEdge1 * 0.42))
            let highlightMask = smoothstep(edge0: highlightEdge0, edge1: highlightEdge1, x: luma)
            let highlightTintRGB = colorWheelToRGB(adjustments.highlightTint)
            output = mix(output, highlightTintRGB, factor: adjustments.highlightTint.intensity * 0.35 * highlightMask)
        }

        return output
    }

    private func colorWheelToRGB(_ wheel: ColorWheelControl) -> RGB {
        let hueUnit = wrapUnit(wheel.hue / (Double.pi * 2.0))
        return hslToRGB(h: hueUnit, s: 1.0, l: 0.5)
    }

    private func rgbToHSL(_ rgb: RGB) -> (h: Double, s: Double, l: Double) {
        let r = rgb.red
        let g = rgb.green
        let b = rgb.blue

        let maxValue = max(r, max(g, b))
        let minValue = min(r, min(g, b))
        let delta = maxValue - minValue
        let lightness = (maxValue + minValue) * 0.5

        guard delta > 0.000001 else {
            return (0.0, 0.0, lightness)
        }

        let saturation = delta / (1.0 - abs((2.0 * lightness) - 1.0))
        var hue: Double
        if maxValue == r {
            hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6.0)
        } else if maxValue == g {
            hue = ((b - r) / delta) + 2.0
        } else {
            hue = ((r - g) / delta) + 4.0
        }
        hue /= 6.0

        return (wrapUnit(hue), clamp(saturation, min: 0.0, max: 1.0), clamp(lightness, min: 0.0, max: 1.0))
    }

    private func hslToRGB(h: Double, s: Double, l: Double) -> RGB {
        let hue = wrapUnit(h)
        let sat = clamp(s, min: 0.0, max: 1.0)
        let lightness = clamp(l, min: 0.0, max: 1.0)

        if sat <= 0.000001 {
            return RGB(red: lightness, green: lightness, blue: lightness)
        }

        let q = lightness < 0.5 ? (lightness * (1 + sat)) : (lightness + sat - (lightness * sat))
        let p = 2 * lightness - q

        let r = hueToRGB(p: p, q: q, t: hue + (1.0 / 3.0))
        let g = hueToRGB(p: p, q: q, t: hue)
        let b = hueToRGB(p: p, q: q, t: hue - (1.0 / 3.0))

        return RGB(red: r, green: g, blue: b)
    }

    private func hueToRGB(p: Double, q: Double, t: Double) -> Double {
        var value = t
        if value < 0 { value += 1 }
        if value > 1 { value -= 1 }

        if value < 1.0 / 6.0 { return p + ((q - p) * 6.0 * value) }
        if value < 1.0 / 2.0 { return q }
        if value < 2.0 / 3.0 { return p + ((q - p) * ((2.0 / 3.0) - value) * 6.0) }
        return p
    }

    private func circularDistance(_ a: Double, _ b: Double) -> Double {
        let distance = abs(a - b)
        return min(distance, 1.0 - distance)
    }

    private func smoothstep(edge0: Double, edge1: Double, x: Double) -> Double {
        let t = clamp((x - edge0) / (edge1 - edge0), min: 0.0, max: 1.0)
        return t * t * (3.0 - (2.0 * t))
    }
    
    private func localWeight(distance: Double, radius: Double, exponent: Double) -> Double {
        guard radius > 0, distance < radius else { return 0 }
        let normalized = 1.0 - (distance / radius)
        return pow(max(0, normalized), exponent)
    }

    private func mix(_ a: RGB, _ b: RGB, factor: Double) -> RGB {
        let t = clamp(factor, min: 0.0, max: 1.0)
        return RGB(
            red: a.red + ((b.red - a.red) * t),
            green: a.green + ((b.green - a.green) * t),
            blue: a.blue + ((b.blue - a.blue) * t)
        )
    }

    private func clamp(_ value: Double, min lower: Double, max upper: Double) -> Double {
        Swift.max(lower, Swift.min(upper, value))
    }

    private func wrapUnit(_ value: Double) -> Double {
        var wrapped = value.truncatingRemainder(dividingBy: 1.0)
        if wrapped < 0 { wrapped += 1.0 }
        return wrapped
    }
}

nonisolated private struct RGB {
    var red: Double
    var green: Double
    var blue: Double

    var luma: Double {
        (red * 0.2126) + (green * 0.7152) + (blue * 0.0722)
    }
}
