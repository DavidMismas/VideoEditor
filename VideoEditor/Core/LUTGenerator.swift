import Foundation
import CoreImage
import CoreGraphics

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

            if adjustments == ColorAdjustments() {
                cachedKey = key
                cachedFilter = nil
                return nil
            }

            let cubeData = generateCubeData(for: adjustments, dimension: dimension)
            let cubeFilter = CIFilter(name: "CIColorCubeWithColorSpace") ?? CIFilter(name: "CIColorCube")
            cubeFilter?.setValue(dimension, forKey: "inputCubeDimension")
            cubeFilter?.setValue(cubeData, forKey: "inputCubeData")
            cubeFilter?.setValue(false, forKey: "inputExtrapolate")

            if let outputColorSpace = cgColorSpace(for: adjustments.outputColorSpace),
               cubeFilter?.inputKeys.contains("inputColorSpace") == true {
                cubeFilter?.setValue(outputColorSpace, forKey: "inputColorSpace")
            }

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

        let inputPrimaries = primaries(for: adjustments.inputColorSpace)
        let workingPrimaries = primaries(for: adjustments.workingColorSpace)
        let outputPrimaries = primaries(for: adjustments.outputColorSpace)

        for b in 0..<dimension {
            let blue = Double(b) / Double(dimension - 1)
            for g in 0..<dimension {
                let green = Double(g) / Double(dimension - 1)
                for r in 0..<dimension {
                    let red = Double(r) / Double(dimension - 1)

                    var working = RGB(red: red, green: green, blue: blue)

                    working = decodeTransfer(working, profile: adjustments.inputColorSpace)
                    working = convertPrimaries(working, from: inputPrimaries, to: workingPrimaries)

                    working = applyExposureAndContrast(working, adjustments: adjustments)
                    working = applyPrimaryChromaControls(working, adjustments: adjustments)
                    working = applyHSLSecondaries(working, adjustments: adjustments)
                    working = applyLiftGammaGainOffset(working, adjustments: adjustments)
                    working = applyToneCurves(working, adjustments: adjustments)
                    working = applyFilmicRolloff(working, adjustments: adjustments)

                    var output = convertPrimaries(working, from: workingPrimaries, to: outputPrimaries)
                    output = encodeTransfer(output, profile: adjustments.outputColorSpace)
                    output = clampRGB(output, min: 0.0, max: 1.0)

                    let dataOffset = ((b * dimension * dimension) + (g * dimension) + r) * 4
                    cube[dataOffset + 0] = Float(output.red)
                    cube[dataOffset + 1] = Float(output.green)
                    cube[dataOffset + 2] = Float(output.blue)
                    cube[dataOffset + 3] = 1.0
                }
            }
        }

        return cube.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private func applyExposureAndContrast(_ rgb: RGB, adjustments: ColorAdjustments) -> RGB {
        var output = rgb

        if abs(adjustments.exposure) > 1e-6 {
            let exposureScale = pow(2.0, adjustments.exposure)
            output = output * exposureScale
        }

        if abs(adjustments.contrast - 1.0) > 1e-6 {
            let pivot = 0.18
            let y = luma709(output)
            let contrastedY = pivot + ((y - pivot) * adjustments.contrast)
            output = setLumaPreserveChroma(output, targetLuma: contrastedY)
        }

        return output
    }

    private func applyPrimaryChromaControls(_ rgb: RGB, adjustments: ColorAdjustments) -> RGB {
        var y = luma709(rgb)
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
        let green = (y - (0.2126 * red) - (0.0722 * blue)) / 0.7152
        y = luma709(RGB(red: red, green: green, blue: blue))

        // Keep chroma operations centered around perceived luma.
        return setLumaPreserveChroma(RGB(red: red, green: green, blue: blue), targetLuma: y)
    }

    private func applyHSLSecondaries(_ rgb: RGB, adjustments: ColorAdjustments) -> RGB {
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
            output = rotateHuePreservingLuma(output, radians: radians)
        }

        if satWeightTotal > 1e-6 {
            let normalizedSatDelta = satWeightedSum / satWeightTotal
            let influence = pow(clamp(satWeightTotal, min: 0.0, max: 1.0), 0.80)
            let scale = 1.0 + (normalizedSatDelta * 1.10 * saturationGate * influence)
            output = scaleSaturationPreservingLuma(output, scale: max(0.0, scale))
        }

        if lumWeightTotal > 1e-6 {
            // Perceptual luminance control uses Rec.709 Y, not HSL lightness.
            let normalizedLumDelta = clamp(lumWeightedSum / lumWeightTotal, min: -1.0, max: 1.0)
            let influence = pow(clamp(lumWeightTotal, min: 0.0, max: 1.0), 0.90)
            let deltaY = normalizedLumDelta * 0.25 * saturationGate * influence
            let currentY = luma709(output)
            output = setLumaPreserveChroma(output, targetLuma: currentY + deltaY)
        }

        return output
    }

    private func applyLiftGammaGainOffset(_ rgb: RGB, adjustments: ColorAdjustments) -> RGB {
        let baseY = luma709(rgb)

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

        var output = setLumaPreserveChroma(rgb, targetLuma: y)
        output = applyWheelTint(output, wheel: adjustments.liftWheel, mask: shadowMask, strength: 0.28)
        output = applyWheelTint(output, wheel: adjustments.gammaWheel, mask: midMask, strength: 0.24)
        output = applyWheelTint(output, wheel: adjustments.gainWheel, mask: highlightMask, strength: 0.30)
        output = applyWheelTint(output, wheel: adjustments.offsetWheel, mask: 1.0, strength: 0.20)
        return output
    }

    private func applyToneCurves(_ rgb: RGB, adjustments: ColorAdjustments) -> RGB {
        var output = rgb

        if adjustments.lumaCurveEnabled {
            let currentY = clamp(luma709(output), min: 0.0, max: 1.0)
            let curvedY = sampleCurve(adjustments.lumaCurve.values, at: currentY)
            output = setLumaPreserveChroma(output, targetLuma: curvedY)
        }

        if adjustments.rgbCurvesEnabled {
            output.red = sampleCurve(adjustments.redCurve.values, at: clamp(output.red, min: 0.0, max: 1.0))
            output.green = sampleCurve(adjustments.greenCurve.values, at: clamp(output.green, min: 0.0, max: 1.0))
            output.blue = sampleCurve(adjustments.blueCurve.values, at: clamp(output.blue, min: 0.0, max: 1.0))
        }

        return output
    }

    private func applyFilmicRolloff(_ rgb: RGB, adjustments: ColorAdjustments) -> RGB {
        let inputY = max(luma709(rgb), 0.0)
        var y = inputY

        // Basic Highlights/Shadows sliders should be range-isolated and predictable.
        let shadowAmount = clamp(adjustments.shadows / 2.0, min: -1.0, max: 1.0)
        let highlightAmount = clamp(adjustments.highlights / 2.0, min: -1.0, max: 1.0)
        let shadowMask = 1.0 - smoothstep(edge0: 0.04, edge1: 0.52, x: inputY)
        let highlightMask = smoothstep(edge0: 0.42, edge1: 0.98, x: inputY)

        if abs(shadowAmount) > 1e-6 {
            let lifted = pow(inputY, 1.0 / (1.0 + (1.35 * max(shadowAmount, 0.0))))
            let deepened = pow(inputY, 1.0 + (1.55 * max(-shadowAmount, 0.0)))
            let shadowTarget = shadowAmount >= 0 ? lifted : deepened
            y += (shadowTarget - inputY) * shadowMask
        }

        if abs(highlightAmount) > 1e-6 {
            if highlightAmount >= 0 {
                let boosted = y * (1.0 + (0.65 * highlightAmount))
                let protected = compressHighlights(boosted, start: 0.78, strength: 0.65 * highlightAmount)
                y += (protected - y) * highlightMask
            } else {
                let recovered = compressHighlights(y, start: 0.52, strength: abs(highlightAmount) * 2.2)
                y += (recovered - y) * highlightMask
            }
        }

        let filmicStrength = clamp(adjustments.filmicHighlightRolloff, min: 0.0, max: 2.5)
        if filmicStrength > 1e-6 {
            y = compressHighlights(y, start: 0.64, strength: filmicStrength)
        }

        return setLumaPreserveChroma(rgb, targetLuma: y)
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

    private func scaleSaturationPreservingLuma(_ rgb: RGB, scale: Double) -> RGB {
        let y = luma709(rgb)
        let red = y + ((rgb.red - y) * scale)
        let blue = y + ((rgb.blue - y) * scale)
        let green = (y - (0.2126 * red) - (0.0722 * blue)) / 0.7152
        return RGB(
            red: red,
            green: green.isFinite ? green : y,
            blue: blue
        )
    }

    private func rotateHuePreservingLuma(_ rgb: RGB, radians: Double) -> RGB {
        guard abs(radians) > 1e-9 else { return rgb }
        let y = luma709(rgb)
        let cr = rgb.red - y
        let cb = rgb.blue - y

        let cosA = cos(radians)
        let sinA = sin(radians)

        let rotatedCr = (cr * cosA) - (cb * sinA)
        let rotatedCb = (cr * sinA) + (cb * cosA)

        let red = y + rotatedCr
        let blue = y + rotatedCb
        let green = (y - (0.2126 * red) - (0.0722 * blue)) / 0.7152
        return RGB(red: red, green: green, blue: blue)
    }

    private func setLumaPreserveChroma(_ rgb: RGB, targetLuma: Double) -> RGB {
        let y = luma709(rgb)
        let cr = rgb.red - y
        let cb = rgb.blue - y

        let newY = max(targetLuma, 0.0)
        let red = newY + cr
        let blue = newY + cb
        let green = (newY - (0.2126 * red) - (0.0722 * blue)) / 0.7152

        return RGB(
            red: red.isFinite ? red : newY,
            green: green.isFinite ? green : newY,
            blue: blue.isFinite ? blue : newY
        )
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

    private func luma709(_ rgb: RGB) -> Double {
        (0.2126 * rgb.red) + (0.7152 * rgb.green) + (0.0722 * rgb.blue)
    }

    private func rgbToHSL(_ rgb: RGB) -> (h: Double, s: Double, l: Double) {
        let maxValue = max(rgb.red, max(rgb.green, rgb.blue))
        let minValue = min(rgb.red, min(rgb.green, rgb.blue))
        let delta = maxValue - minValue
        let lightness = (maxValue + minValue) * 0.5

        guard delta > 1e-8 else {
            return (0.0, 0.0, lightness)
        }

        let saturation = delta / (1.0 - abs((2.0 * lightness) - 1.0))
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

    private func decodeTransfer(_ rgb: RGB, profile: ColorSpaceProfile) -> RGB {
        RGB(
            red: decodeTransfer(rgb.red, profile: profile),
            green: decodeTransfer(rgb.green, profile: profile),
            blue: decodeTransfer(rgb.blue, profile: profile)
        )
    }

    private func encodeTransfer(_ rgb: RGB, profile: ColorSpaceProfile) -> RGB {
        RGB(
            red: encodeTransfer(rgb.red, profile: profile),
            green: encodeTransfer(rgb.green, profile: profile),
            blue: encodeTransfer(rgb.blue, profile: profile)
        )
    }

    private func decodeTransfer(_ value: Double, profile: ColorSpaceProfile) -> Double {
        let v = clamp(value, min: 0.0, max: 1.0)
        switch profile {
        case .displayP3:
            if v <= 0.04045 { return v / 12.92 }
            return pow((v + 0.055) / 1.055, 2.4)
        case .rec709, .bt2020:
            if v < 0.081 { return v / 4.5 }
            return pow((v + 0.099) / 1.099, 1.0 / 0.45)
        }
    }

    private func encodeTransfer(_ value: Double, profile: ColorSpaceProfile) -> Double {
        let v = max(value, 0.0)
        switch profile {
        case .displayP3:
            if v <= 0.0031308 { return v * 12.92 }
            return (1.055 * pow(v, 1.0 / 2.4)) - 0.055
        case .rec709, .bt2020:
            if v < 0.018 { return v * 4.5 }
            return (1.099 * pow(v, 0.45)) - 0.099
        }
    }

    private enum RGBPrimaries {
        case rec709
        case displayP3
        case bt2020
        case acescg
    }

    private func primaries(for profile: ColorSpaceProfile) -> RGBPrimaries {
        switch profile {
        case .rec709: return .rec709
        case .displayP3: return .displayP3
        case .bt2020: return .bt2020
        }
    }

    private func primaries(for profile: WorkingColorSpaceProfile) -> RGBPrimaries {
        switch profile {
        case .linearSRGB: return .rec709
        case .acescg: return .acescg
        }
    }

    private func convertPrimaries(_ rgb: RGB, from source: RGBPrimaries, to destination: RGBPrimaries) -> RGB {
        if source == destination { return rgb }
        let xyz = multiply(matrixToXYZ(for: source), rgb)
        return multiply(matrixFromXYZ(for: destination), xyz)
    }

    private func matrixToXYZ(for primaries: RGBPrimaries) -> Matrix3x3 {
        switch primaries {
        case .rec709:
            return Matrix3x3(
                0.4124564, 0.3575761, 0.1804375,
                0.2126729, 0.7151522, 0.0721750,
                0.0193339, 0.1191920, 0.9503041
            )
        case .displayP3:
            return Matrix3x3(
                0.48657095, 0.26566769, 0.19821729,
                0.22897456, 0.69173852, 0.07928691,
                0.00000000, 0.04511338, 1.04394437
            )
        case .bt2020:
            return Matrix3x3(
                0.63695805, 0.14461690, 0.16888098,
                0.26270021, 0.67799807, 0.05930172,
                0.00000000, 0.02807269, 1.06098506
            )
        case .acescg:
            return Matrix3x3(
                0.66245418, 0.13400421, 0.15618769,
                0.27222872, 0.67408177, 0.05368952,
                -0.00557465, 0.00406073, 1.01033910
            )
        }
    }

    private func matrixFromXYZ(for primaries: RGBPrimaries) -> Matrix3x3 {
        switch primaries {
        case .rec709:
            return Matrix3x3(
                3.2404542, -1.5371385, -0.4985314,
                -0.9692660, 1.8760108, 0.0415560,
                0.0556434, -0.2040259, 1.0572252
            )
        case .displayP3:
            return Matrix3x3(
                2.49349691, -0.93138362, -0.40271078,
                -0.82948897, 1.76266406, 0.02362469,
                0.03584583, -0.07617239, 0.95688452
            )
        case .bt2020:
            return Matrix3x3(
                1.71665119, -0.35567078, -0.25336628,
                -0.66668435, 1.61648124, 0.01576855,
                0.01763986, -0.04277061, 0.94210312
            )
        case .acescg:
            return Matrix3x3(
                1.64102338, -0.32480329, -0.23642470,
                -0.66366286, 1.61533159, 0.01675635,
                0.01172189, -0.00828444, 0.98839486
            )
        }
    }

    private func multiply(_ matrix: Matrix3x3, _ rgb: RGB) -> RGB {
        RGB(
            red: (matrix.m00 * rgb.red) + (matrix.m01 * rgb.green) + (matrix.m02 * rgb.blue),
            green: (matrix.m10 * rgb.red) + (matrix.m11 * rgb.green) + (matrix.m12 * rgb.blue),
            blue: (matrix.m20 * rgb.red) + (matrix.m21 * rgb.green) + (matrix.m22 * rgb.blue)
        )
    }

    private func cgColorSpace(for profile: ColorSpaceProfile) -> CGColorSpace? {
        switch profile {
        case .rec709:
            return CGColorSpace(name: CGColorSpace.itur_709)
        case .displayP3:
            return CGColorSpace(name: CGColorSpace.displayP3)
        case .bt2020:
            return CGColorSpace(name: CGColorSpace.itur_2020)
        }
    }
}

nonisolated private struct Matrix3x3 {
    let m00: Double
    let m01: Double
    let m02: Double
    let m10: Double
    let m11: Double
    let m12: Double
    let m20: Double
    let m21: Double
    let m22: Double

    init(
        _ m00: Double, _ m01: Double, _ m02: Double,
        _ m10: Double, _ m11: Double, _ m12: Double,
        _ m20: Double, _ m21: Double, _ m22: Double
    ) {
        self.m00 = m00
        self.m01 = m01
        self.m02 = m02
        self.m10 = m10
        self.m11 = m11
        self.m12 = m12
        self.m20 = m20
        self.m21 = m21
        self.m22 = m22
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

    init(gray: Double) {
        self.red = gray
        self.green = gray
        self.blue = gray
    }

    static func + (lhs: RGB, rhs: RGB) -> RGB {
        RGB(red: lhs.red + rhs.red, green: lhs.green + rhs.green, blue: lhs.blue + rhs.blue)
    }

    static func - (lhs: RGB, rhs: RGB) -> RGB {
        RGB(red: lhs.red - rhs.red, green: lhs.green - rhs.green, blue: lhs.blue - rhs.blue)
    }

    static func * (lhs: RGB, rhs: Double) -> RGB {
        RGB(red: lhs.red * rhs, green: lhs.green * rhs, blue: lhs.blue * rhs)
    }
}
