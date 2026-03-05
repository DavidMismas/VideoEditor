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
        let influenceRadius: Double = 0.20

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
                    var lum = hsl.l

                    var weightedHueShift = 0.0
                    var weightedSatDelta = 0.0
                    var weightedLumDelta = 0.0
                    var totalWeight = 0.0

                    for idx in 0..<channelCenters.count {
                        let center = channelCenters[idx]
                        let control = channelControls[idx]
                        let distance = circularDistance(hue, center)
                        guard distance < influenceRadius else { continue }

                        let normalized = 1.0 - (distance / influenceRadius)
                        let weight = normalized * normalized * (3.0 - (2.0 * normalized))
                        totalWeight += weight
                        weightedHueShift += weight * control.hue
                        weightedSatDelta += weight * (control.saturation - 1.0)
                        weightedLumDelta += weight * control.luminance
                    }

                    if totalWeight > 0.0001 {
                        let normalizedHueShift = weightedHueShift / totalWeight
                        let normalizedSatDelta = weightedSatDelta / totalWeight
                        let normalizedLumDelta = weightedLumDelta / totalWeight

                        // Slider -1...1 maps to ~+-60deg shift for the selected hue family.
                        hue = wrapUnit(hue + (normalizedHueShift * 0.1666))
                        sat = clamp(sat + normalizedSatDelta, min: 0.0, max: 1.0)
                        lum = clamp(lum + (normalizedLumDelta * 0.50), min: 0.0, max: 1.0)
                    }

                    working = hslToRGB(h: hue, s: sat, l: lum)
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
            let shadowMask = 1.0 - smoothstep(edge0: 0.10, edge1: 0.65, x: luma)
            let shadowTintRGB = colorWheelToRGB(adjustments.shadowTint)
            output = mix(output, shadowTintRGB, factor: adjustments.shadowTint.intensity * 0.35 * shadowMask)
        }

        if adjustments.highlightTint.intensity > 0.0001 {
            let highlightMask = smoothstep(edge0: 0.35, edge1: 0.90, x: luma)
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
