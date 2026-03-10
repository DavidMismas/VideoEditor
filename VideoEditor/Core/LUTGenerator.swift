import Foundation
import CoreImage

nonisolated class LUTGenerator {
    static let shared = LUTGenerator()

    private struct CacheKey: Equatable {
        let adjustments: ColorAdjustments
        let dimension: Int
    }

    private var cachedKey: CacheKey?
    private var cachedFilter: CIFilter?
    private let cacheQueue = DispatchQueue(label: "LUTGenerator.cacheQueue")

    func filter(for adjustments: ColorAdjustments, dimension requestedDimension: Int) -> CIFilter? {
        let dimension = supportedDimension(requestedDimension)

        return cacheQueue.sync {
            let key = CacheKey(adjustments: adjustments, dimension: dimension)
            if cachedKey == key, let cachedFilter {
                return cachedFilter
            }

            if !adjustments.hasGeneratedLUTAdjustments {
                cachedKey = key
                cachedFilter = nil
                return nil
            }

            let cubeData = generateCubeData(for: adjustments, dimension: dimension)
            let cubeFilter = CIFilter(name: "CIColorCube")
            cubeFilter?.setValue(dimension, forKey: "inputCubeDimension")
            cubeFilter?.setValue(cubeData, forKey: "inputCubeData")
            cubeFilter?.setValue(true, forKey: "inputExtrapolate")

            cachedKey = key
            cachedFilter = cubeFilter
            return cubeFilter
        }
    }

    private func supportedDimension(_ requestedDimension: Int) -> Int {
        if requestedDimension <= 17 { return 17 }
        if requestedDimension <= 33 { return 33 }
        return 65
    }

    private func generateCubeData(for adjustments: ColorAdjustments, dimension: Int) -> Data {
        let cubeSize = dimension * dimension * dimension * 4
        var cube = [Float](repeating: 0, count: cubeSize)

        let workingSpace: SignalSpace = .linearSRGB
        let lumaCoefficients = lumaCoefficients(for: workingSpace)

        for b in 0..<dimension {
            let blue = Double(b) / Double(dimension - 1)
            for g in 0..<dimension {
                let green = Double(g) / Double(dimension - 1)
                for r in 0..<dimension {
                    let red = Double(r) / Double(dimension - 1)

                    var working = RGB(red: red, green: green, blue: blue)

                    working = applyPrimaryToneControls(working, adjustments: adjustments, lumaCoefficients: lumaCoefficients)
                    working = applyPrimaryChromaControls(working, adjustments: adjustments, lumaCoefficients: lumaCoefficients)
                    working = applyHSLSecondaries(working, adjustments: adjustments, lumaCoefficients: lumaCoefficients)
                    working = applyLiftGammaGainOffset(working, adjustments: adjustments, lumaCoefficients: lumaCoefficients)
                    working = applyToneCurves(working, adjustments: adjustments, lumaCoefficients: lumaCoefficients)
                    working = applyFilmicRolloff(working, adjustments: adjustments, lumaCoefficients: lumaCoefficients)

                    let dataOffset = ((b * dimension * dimension) + (g * dimension) + r) * 4
                    cube[dataOffset + 0] = Float(working.red)
                    cube[dataOffset + 1] = Float(working.green)
                    cube[dataOffset + 2] = Float(working.blue)
                    cube[dataOffset + 3] = 1.0
                }
            }
        }

        return cube.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private func applyPrimaryToneControls(
        _ rgb: RGB,
        adjustments: ColorAdjustments,
        lumaCoefficients: RGB
    ) -> RGB {
        let exposureScale = pow(2.0, adjustments.exposure)
        let exposed = rgb * exposureScale
        let sourceY = max(luma(exposed, coefficients: lumaCoefficients), 0.0)
        let pivot = encodedPerceptualLuma(0.18)
        let contrastSlope = pow(max(0.01, adjustments.contrast), 1.2)
        var tone = encodedPerceptualLuma(sourceY)

        if abs(adjustments.contrast - 1.0) > 1e-6 {
            tone = pivot + ((tone - pivot) * contrastSlope)
        }

        let shadowAmount = clamp(adjustments.shadows / 2.0, min: -1.0, max: 1.0)
        let highlightAmount = clamp(adjustments.highlights / 2.0, min: -1.0, max: 1.0)
        let shadowMask = 1.0 - smoothstep(edge0: 0.16, edge1: 0.60, x: tone)
        let highlightMask = smoothstep(edge0: 0.40, edge1: 0.92, x: tone)

        if abs(shadowAmount) > 1e-6 {
            let strength = shadowAmount >= 0 ? 0.18 : 0.16
            tone += shadowAmount * strength * pow(shadowMask, 1.2)
        }

        if abs(highlightAmount) > 1e-6 {
            let strength = highlightAmount >= 0 ? 0.15 : 0.20
            tone += highlightAmount * strength * pow(highlightMask, 1.05)
        }

        var targetY = decodedPerceptualLuma(tone)
        if highlightAmount > 1e-6 {
            let extended = targetY * (1.0 + (0.35 * highlightAmount))
            let protected = compressHighlights(extended, start: 0.82, strength: 0.45 * highlightAmount)
            targetY = mix(targetY, protected, highlightMask)
        } else if highlightAmount < -1e-6 {
            let recovered = compressHighlights(targetY, start: 0.34, strength: abs(highlightAmount) * 2.8)
            targetY = mix(targetY, recovered, highlightMask)
        }

        return remapLuminancePreservingRatios(
            exposed,
            sourceLuma: sourceY,
            targetLuma: targetY
        )
    }

    private func applyPrimaryChromaControls(
        _ rgb: RGB,
        adjustments: ColorAdjustments,
        lumaCoefficients: RGB
    ) -> RGB {
        var y = luma(rgb, coefficients: lumaCoefficients)
        var cr = rgb.red - y
        var cb = rgb.blue - y

        let chromaMagnitude = sqrt((cr * cr) + (cb * cb))
        let vibranceBoost = 1.0 + (adjustments.vibrance * (1.0 - clamp(chromaMagnitude * 2.2, min: 0.0, max: 1.0)))
        let saturationScale = max(0.0, adjustments.saturation) * max(0.0, vibranceBoost)

        let angle = adjustments.hue * (Double.pi * 2.0)
        let cosA = cos(angle)
        let sinA = sin(angle)
        let rotatedCr = (cr * cosA) - (cb * sinA)
        let rotatedCb = (cr * sinA) + (cb * cosA)

        cr = rotatedCr * saturationScale
        cb = rotatedCb * saturationScale

        let red = y + cr
        let blue = y + cb
        let green = reconstructedGreen(luma: y, red: red, blue: blue, coefficients: lumaCoefficients)
        y = luma(RGB(red: red, green: green, blue: blue), coefficients: lumaCoefficients)

        return setLumaPreserveChroma(
            RGB(red: red, green: green, blue: blue),
            targetLuma: y,
            coefficients: lumaCoefficients
        )
    }

    private func applyHSLSecondaries(
        _ rgb: RGB,
        adjustments: ColorAdjustments,
        lumaCoefficients: RGB
    ) -> RGB {
        var output = rgb
        let analysis = clampRGB(output, min: 0.0, max: 1.0)
        let hsl = rgbToHSL(analysis)

        let channelCenters: [Double] = ColorControlMath.HSLChannel.allCases.map(\.centerHueUnit)
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
        let hueRadius: Double = 0.090 + (0.100 * looseness)
        let saturationRadius: Double = 0.085 + (0.090 * looseness)
        let luminanceRadius: Double = 0.040 + (0.055 * looseness)

        var hueWeightedSum = 0.0
        var hueWeightTotal = 0.0
        var satWeightedSum = 0.0
        var satWeightTotal = 0.0
        var lumWeightedSum = 0.0
        var lumWeightTotal = 0.0

        let saturationGate = smoothstep(edge0: 0.03, edge1: 0.30, x: hsl.s)

        for index in 0..<channelCenters.count {
            let center = channelCenters[index]
            let control = channelControls[index]
            let distance = circularDistance(hsl.h, center)

            if abs(control.hue) > 1e-6 {
                let weight = localWeight(distance: distance, radius: hueRadius, exponent: 2.8)
                if weight > 0 {
                    hueWeightedSum += weight * control.hue
                    hueWeightTotal += weight
                }
            }

            let satDelta = control.saturation - 1.0
            if abs(satDelta) > 1e-6 {
                let weight = localWeight(distance: distance, radius: saturationRadius, exponent: 2.6)
                if weight > 0 {
                    satWeightedSum += weight * satDelta
                    satWeightTotal += weight
                }
            }

            if abs(control.luminance) > 1e-6 {
                let weight = localWeight(distance: distance, radius: luminanceRadius, exponent: 3.2)
                if weight > 0 {
                    lumWeightedSum += weight * control.luminance
                    lumWeightTotal += weight
                }
            }
        }

        if hueWeightTotal > 1e-6 {
            let normalizedHueShift = hueWeightedSum / hueWeightTotal
            let influence = pow(clamp(hueWeightTotal, min: 0.0, max: 1.0), 0.75)
            let radians = normalizedHueShift * ColorControlMath.hslHueControlTurns * ColorControlMath.twoPi * saturationGate * influence
            output = rotateHuePreservingLuma(output, radians: radians, coefficients: lumaCoefficients)
        }

        if satWeightTotal > 1e-6 {
            let normalizedSatDelta = satWeightedSum / satWeightTotal
            let influence = pow(clamp(satWeightTotal, min: 0.0, max: 1.0), 0.80)
            let scale = 1.0 + (normalizedSatDelta * 1.10 * saturationGate * influence)
            output = scaleSaturationPreservingLuma(output, scale: max(0.0, scale), coefficients: lumaCoefficients)
        }

        if lumWeightTotal > 1e-6 {
            let normalizedLumDelta = clamp(lumWeightedSum / lumWeightTotal, min: -1.0, max: 1.0)
            let influence = pow(clamp(lumWeightTotal, min: 0.0, max: 1.0), 0.90)
            let deltaY = normalizedLumDelta * 0.25 * saturationGate * influence
            let currentY = luma(output, coefficients: lumaCoefficients)
            output = setLumaPreserveChroma(output, targetLuma: currentY + deltaY, coefficients: lumaCoefficients)
        }

        return output
    }

    private func applyLiftGammaGainOffset(
        _ rgb: RGB,
        adjustments: ColorAdjustments,
        lumaCoefficients: RGB
    ) -> RGB {
        let baseY = luma(rgb, coefficients: lumaCoefficients)

        let shadowMask = 1.0 - smoothstep(edge0: 0.02, edge1: 0.45, x: baseY)
        let highlightMask = smoothstep(edge0: 0.45, edge1: 0.98, x: baseY)
        let midMask = clamp(1.0 - shadowMask - highlightMask, min: 0.0, max: 1.0)

        var y = baseY
        y += adjustments.lift * 0.35 * shadowMask

        let gammaValue = clamp(adjustments.gamma, min: 0.20, max: 3.0)
        let gammaShaped = pow(max(y, 1e-6), 1.0 / gammaValue)
        y = mix(y, gammaShaped, midMask)

        y = mix(y, y * clamp(adjustments.gain, min: 0.0, max: 4.0), highlightMask)
        y += adjustments.offset * 0.25

        y += adjustments.liftWheel.luma * 0.20 * shadowMask
        y += adjustments.gammaWheel.luma * 0.18 * midMask
        y += adjustments.gainWheel.luma * 0.22 * highlightMask
        y += adjustments.offsetWheel.luma * 0.20

        var output = setLumaPreserveChroma(rgb, targetLuma: y, coefficients: lumaCoefficients)
        output = applyWheelTint(output, wheel: adjustments.liftWheel, mask: shadowMask, strength: 0.28)
        output = applyWheelTint(output, wheel: adjustments.gammaWheel, mask: midMask, strength: 0.24)
        output = applyWheelTint(output, wheel: adjustments.gainWheel, mask: highlightMask, strength: 0.30)
        output = applyWheelTint(output, wheel: adjustments.offsetWheel, mask: 1.0, strength: 0.20)
        return output
    }

    private func applyToneCurves(
        _ rgb: RGB,
        adjustments: ColorAdjustments,
        lumaCoefficients: RGB
    ) -> RGB {
        var output = rgb

        if adjustments.lumaCurveEnabled {
            let currentY = clamp(luma(output, coefficients: lumaCoefficients), min: 0.0, max: 1.0)
            let curvedY = sampleCurve(adjustments.lumaCurve.values, at: currentY)
            output = setLumaPreserveChroma(output, targetLuma: curvedY, coefficients: lumaCoefficients)
        }

        if adjustments.rgbCurvesEnabled {
            output.red = sampleCurve(adjustments.redCurve.values, at: clamp(output.red, min: 0.0, max: 1.0))
            output.green = sampleCurve(adjustments.greenCurve.values, at: clamp(output.green, min: 0.0, max: 1.0))
            output.blue = sampleCurve(adjustments.blueCurve.values, at: clamp(output.blue, min: 0.0, max: 1.0))
        }

        return output
    }

    private func applyFilmicRolloff(
        _ rgb: RGB,
        adjustments: ColorAdjustments,
        lumaCoefficients: RGB
    ) -> RGB {
        let filmicStrength = clamp(adjustments.filmicHighlightRolloff, min: 0.0, max: 2.5)
        guard filmicStrength > 1e-6 else {
            return rgb
        }

        let inputY = max(luma(rgb, coefficients: lumaCoefficients), 0.0)
        let rolled = compressHighlights(inputY, start: 0.64, strength: filmicStrength)
        return remapLuminancePreservingRatios(
            rgb,
            sourceLuma: inputY,
            targetLuma: rolled
        )
    }

    private func applyWheelTint(_ rgb: RGB, wheel: ColorWheelControl, mask: Double, strength: Double) -> RGB {
        guard mask > 1e-6 else { return rgb }
        let wheelValue = ColorControlMath.WheelValue(
            angleRadians: wheel.hue,
            intensity: wheel.intensity,
            luminance: wheel.luma
        )
        let tint = ColorControlMath.wheelValueToProcessingTint(wheelValue)
        let amount = strength * mask
        return rgb + RGB(
            red: tint.red * amount,
            green: tint.green * amount,
            blue: tint.blue * amount
        )
    }

    private func scaleSaturationPreservingLuma(_ rgb: RGB, scale: Double, coefficients: RGB) -> RGB {
        let y = luma(rgb, coefficients: coefficients)
        let red = y + ((rgb.red - y) * scale)
        let blue = y + ((rgb.blue - y) * scale)
        let green = reconstructedGreen(luma: y, red: red, blue: blue, coefficients: coefficients)
        return RGB(
            red: red,
            green: green.isFinite ? green : y,
            blue: blue
        )
    }

    private func rotateHuePreservingLuma(_ rgb: RGB, radians: Double, coefficients: RGB) -> RGB {
        guard abs(radians) > 1e-9 else { return rgb }
        let y = luma(rgb, coefficients: coefficients)
        let cr = rgb.red - y
        let cb = rgb.blue - y

        let cosA = cos(radians)
        let sinA = sin(radians)

        let rotatedCr = (cr * cosA) - (cb * sinA)
        let rotatedCb = (cr * sinA) + (cb * cosA)

        let red = y + rotatedCr
        let blue = y + rotatedCb
        let green = reconstructedGreen(luma: y, red: red, blue: blue, coefficients: coefficients)
        return RGB(red: red, green: green, blue: blue)
    }

    private func setLumaPreserveChroma(_ rgb: RGB, targetLuma: Double, coefficients: RGB) -> RGB {
        let y = luma(rgb, coefficients: coefficients)
        let cr = rgb.red - y
        let cb = rgb.blue - y

        let newY = max(targetLuma, 0.0)
        let red = newY + cr
        let blue = newY + cb
        let green = reconstructedGreen(luma: newY, red: red, blue: blue, coefficients: coefficients)

        return RGB(
            red: red.isFinite ? red : newY,
            green: green.isFinite ? green : newY,
            blue: blue.isFinite ? blue : newY
        )
    }

    private func remapLuminancePreservingRatios(
        _ rgb: RGB,
        sourceLuma: Double,
        targetLuma: Double
    ) -> RGB {
        let safeTarget = max(targetLuma, 0.0)
        let safeSource = max(sourceLuma, 1e-6)
        let scaled = rgb * (safeTarget / safeSource)

        if sourceLuma <= 1e-4 {
            let neutral = RGB(red: safeTarget, green: safeTarget, blue: safeTarget)
            let blend = smoothstep(edge0: 0.0, edge1: 1e-4, x: sourceLuma)
            return RGB(
                red: mix(neutral.red, scaled.red, blend),
                green: mix(neutral.green, scaled.green, blend),
                blue: mix(neutral.blue, scaled.blue, blend)
            )
        }

        return scaled
    }

    private func reconstructedGreen(luma: Double, red: Double, blue: Double, coefficients: RGB) -> Double {
        let greenCoefficient = max(coefficients.green, 1e-6)
        return (luma - (coefficients.red * red) - (coefficients.blue * blue)) / greenCoefficient
    }

    private func encodedPerceptualLuma(_ y: Double) -> Double {
        let scaled = max(y, 0.0) * 15.0
        return log2(1.0 + scaled) / 4.0
    }

    private func decodedPerceptualLuma(_ tone: Double) -> Double {
        (pow(16.0, tone) - 1.0) / 15.0
    }

    private func compressHighlights(_ y: Double, start: Double, strength: Double) -> Double {
        guard y > start else { return y }
        let x = y - start
        let k = 1.0 + (strength * 8.0)
        return start + (x / (1.0 + (k * x)))
    }

    private func sampleCurve(_ points: [Double], at x: Double) -> Double {
        let sanitized = sanitizeCurve(points)
        let clampedX = clamp(x, min: 0.0, max: 1.0)

        let scaled = clampedX * 4.0
        let index = clamp(Int(floor(scaled)), min: 0, max: 3)
        let t = scaled - Double(index)

        let p0 = sanitized[max(index - 1, 0)]
        let p1 = sanitized[index]
        let p2 = sanitized[index + 1]
        let p3 = sanitized[min(index + 2, 4)]

        let t2 = t * t
        let t3 = t2 * t
        let m1 = 0.5 * (p2 - p0)
        let m2 = 0.5 * (p3 - p1)

        let h00 = (2.0 * t3) - (3.0 * t2) + 1.0
        let h10 = t3 - (2.0 * t2) + t
        let h01 = (-2.0 * t3) + (3.0 * t2)
        let h11 = t3 - t2

        let interpolated = (h00 * p1) + (h10 * m1) + (h01 * p2) + (h11 * m2)
        return clamp(interpolated, min: 0.0, max: 1.0)
    }

    private func sanitizeCurve(_ points: [Double]) -> [Double] {
        guard points.count == 5 else {
            return [0.0, 0.25, 0.5, 0.75, 1.0]
        }
        return points.map { clamp($0, min: 0.0, max: 1.0) }
    }

    private func luma(_ rgb: RGB, coefficients: RGB) -> Double {
        (coefficients.red * rgb.red) + (coefficients.green * rgb.green) + (coefficients.blue * rgb.blue)
    }

    private func rgbToHSL(_ rgb: RGB) -> (h: Double, s: Double, l: Double) {
        let maxValue = max(rgb.red, max(rgb.green, rgb.blue))
        let minValue = min(rgb.red, min(rgb.green, rgb.blue))
        let delta = maxValue - minValue
        let lightness = (maxValue + minValue) * 0.5

        guard delta > 1e-8 else {
            return (0.0, 0.0, lightness)
        }

        let saturationDenominator = max(1.0 - abs((2.0 * lightness) - 1.0), 1e-6)
        let saturation = delta / saturationDenominator
        var hue: Double

        if maxValue == rgb.red {
            hue = ((rgb.green - rgb.blue) / delta).truncatingRemainder(dividingBy: 6.0)
        } else if maxValue == rgb.green {
            hue = ((rgb.blue - rgb.red) / delta) + 2.0
        } else {
            hue = ((rgb.red - rgb.green) / delta) + 4.0
        }

        hue /= 6.0
        return (
            wrapUnit(hue),
            clamp(saturation, min: 0.0, max: 1.0),
            clamp(lightness, min: 0.0, max: 1.0)
        )
    }

    private func circularDistance(_ a: Double, _ b: Double) -> Double {
        let distance = abs(a - b)
        return min(distance, 1.0 - distance)
    }

    private func localWeight(distance: Double, radius: Double, exponent: Double) -> Double {
        guard radius > 0, distance < radius else { return 0 }
        let normalized = 1.0 - (distance / radius)
        return pow(max(0.0, normalized), exponent)
    }

    private func smoothstep(edge0: Double, edge1: Double, x: Double) -> Double {
        let t = clamp((x - edge0) / (edge1 - edge0), min: 0.0, max: 1.0)
        return t * t * (3.0 - (2.0 * t))
    }

    private func mix(_ a: Double, _ b: Double, _ t: Double) -> Double {
        let clampedT = clamp(t, min: 0.0, max: 1.0)
        return a + ((b - a) * clampedT)
    }

    private func wrapUnit(_ value: Double) -> Double {
        var wrapped = value.truncatingRemainder(dividingBy: 1.0)
        if wrapped < 0 { wrapped += 1.0 }
        return wrapped
    }

    private func clamp(_ value: Double, min lower: Double, max upper: Double) -> Double {
        Swift.max(lower, Swift.min(upper, value))
    }

    private func clamp(_ value: Int, min lower: Int, max upper: Int) -> Int {
        Swift.max(lower, Swift.min(upper, value))
    }

    private func clampRGB(_ rgb: RGB, min lower: Double, max upper: Double) -> RGB {
        RGB(
            red: clamp(rgb.red, min: lower, max: upper),
            green: clamp(rgb.green, min: lower, max: upper),
            blue: clamp(rgb.blue, min: lower, max: upper)
        )
    }

    private func lumaCoefficients(for space: SignalSpace) -> RGB {
        switch space {
        case .displayP3:
            return RGB(red: 0.22897456, green: 0.69173852, blue: 0.07928691)
        case .bt2020:
            return RGB(red: 0.26270021, green: 0.67799807, blue: 0.05930172)
        case .acescg:
            return RGB(red: 0.27222872, green: 0.67408177, blue: 0.05368952)
        default:
            return RGB(red: 0.2126729, green: 0.7151522, blue: 0.0721750)
        }
    }
}

nonisolated private struct RGB {
    var red: Double
    var green: Double
    var blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    static func + (lhs: RGB, rhs: RGB) -> RGB {
        RGB(red: lhs.red + rhs.red, green: lhs.green + rhs.green, blue: lhs.blue + rhs.blue)
    }

    static func * (lhs: RGB, rhs: Double) -> RGB {
        RGB(red: lhs.red * rhs, green: lhs.green * rhs, blue: lhs.blue * rhs)
    }
}
