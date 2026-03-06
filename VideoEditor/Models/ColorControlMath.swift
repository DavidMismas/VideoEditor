import Foundation
import CoreGraphics

nonisolated enum ColorControlMath {
    static let twoPi = Double.pi * 2.0
    static let hslHueControlTurns = 0.55

    nonisolated struct RGB: Equatable {
        var red: Double
        var green: Double
        var blue: Double

        func clamped() -> RGB {
            RGB(
                red: ColorControlMath.clamp(red, min: 0.0, max: 1.0),
                green: ColorControlMath.clamp(green, min: 0.0, max: 1.0),
                blue: ColorControlMath.clamp(blue, min: 0.0, max: 1.0)
            )
        }
    }

    nonisolated struct WheelValue: Equatable {
        var angleRadians: Double
        var intensity: Double
        var luminance: Double

        init(angleRadians: Double, intensity: Double, luminance: Double) {
            self.angleRadians = ColorControlMath.normalizeAngle(angleRadians)
            self.intensity = ColorControlMath.clamp(intensity, min: 0.0, max: 1.0)
            self.luminance = ColorControlMath.clamp(luminance, min: -1.0, max: 1.0)
        }

        var hueUnit: Double {
            ColorControlMath.angleToHue(angleRadians)
        }

        var angleDegrees: Double {
            angleRadians * 180.0 / Double.pi
        }
    }

    nonisolated enum HSLChannel: String, CaseIterable, Identifiable {
        case red
        case orange
        case yellow
        case green
        case aqua
        case blue
        case purple
        case magenta

        var id: String { rawValue }

        var displayName: String {
            rawValue.capitalized
        }

        var centerHueUnit: Double {
            switch self {
            case .red: return 0.0
            case .orange: return 1.0 / 12.0
            case .yellow: return 1.0 / 6.0
            case .green: return 1.0 / 3.0
            case .aqua: return 0.5
            case .blue: return 2.0 / 3.0
            case .purple: return 0.75
            case .magenta: return 5.0 / 6.0
            }
        }

        var displayColorRGB: RGB {
            ColorControlMath.hueUnitToDisplayRGB(centerHueUnit)
        }
    }

    static func clamp(_ value: Double, min lower: Double, max upper: Double) -> Double {
        Swift.max(lower, Swift.min(upper, value))
    }

    static func normalizeHueUnit(_ value: Double) -> Double {
        var wrapped = value.truncatingRemainder(dividingBy: 1.0)
        if wrapped < 0 { wrapped += 1.0 }
        return wrapped
    }

    static func normalizeAngle(_ angle: Double) -> Double {
        var wrapped = angle.truncatingRemainder(dividingBy: twoPi)
        if wrapped < 0 { wrapped += twoPi }
        return wrapped
    }

    static func angleToHue(_ angleRadians: Double) -> Double {
        normalizeAngle(angleRadians) / twoPi
    }

    static func hueToAngle(_ hueUnit: Double) -> Double {
        normalizeHueUnit(hueUnit) * twoPi
    }

    static func pointToWheelValue(
        point: CGPoint,
        center: CGPoint,
        maxRadius: Double,
        luminance: Double,
        displayRotationRadians: Double = 0.0
    ) -> WheelValue {
        let dx = Double(point.x - center.x)
        let dy = Double(point.y - center.y)
        let distance = sqrt((dx * dx) + (dy * dy))
        let safeRadius = max(maxRadius, 1e-6)
        let clampedDistance = min(distance, safeRadius)
        let intensity = clamp(clampedDistance / safeRadius, min: 0.0, max: 1.0)
        // Convert from displayed wheel orientation into canonical processing hue angle.
        let angle = normalizeAngle(atan2(-dy, dx) - displayRotationRadians)
        return WheelValue(angleRadians: angle, intensity: intensity, luminance: luminance)
    }

    static func wheelValueToPoint(
        _ value: WheelValue,
        center: CGPoint,
        maxRadius: Double,
        displayRotationRadians: Double = 0.0
    ) -> CGPoint {
        let radius = max(maxRadius, 1e-6) * clamp(value.intensity, min: 0.0, max: 1.0)
        // Convert canonical processing hue angle into displayed wheel orientation.
        let displayAngle = value.angleRadians + displayRotationRadians
        let x = Double(center.x) + (cos(displayAngle) * radius)
        let y = Double(center.y) - (sin(displayAngle) * radius)
        return CGPoint(x: x, y: y)
    }

    static func radians(fromDegrees degrees: Double) -> Double {
        degrees * Double.pi / 180.0
    }

    static func wheelValueToProcessingTint(_ value: WheelValue) -> RGB {
        let hueRGB = hueUnitToDisplayRGB(value.hueUnit)
        let scale = clamp(value.intensity, min: 0.0, max: 1.0)
        return RGB(
            red: (hueRGB.red - 0.5) * scale,
            green: (hueRGB.green - 0.5) * scale,
            blue: (hueRGB.blue - 0.5) * scale
        )
    }

    static func wheelValueToRGBPreview(_ value: WheelValue) -> RGB {
        let tint = wheelValueToProcessingTint(value)
        return RGB(
            red: 0.5 + tint.red,
            green: 0.5 + tint.green,
            blue: 0.5 + tint.blue
        ).clamped()
    }

    static func hueUnitToDisplayRGB(_ hueUnit: Double) -> RGB {
        hslToRGB(h: normalizeHueUnit(hueUnit), s: 1.0, l: 0.5)
    }

    static func previewHueUnit(for channel: HSLChannel, hueShift: Double) -> Double {
        // Perceptual hue rotation in grading space is directionally opposite to a naive HSL wheel offset.
        // Keep UI preview aligned with actual processing direction.
        normalizeHueUnit(channel.centerHueUnit - (hueShift * hslHueControlTurns))
    }

    static func hslHueChannelWeight(
        sampleHueUnit: Double,
        channel: HSLChannel,
        tightness: Double
    ) -> Double {
        let clampedTightness = clamp(tightness, min: 0.20, max: 1.0)
        let looseness = 1.0 - clampedTightness
        let hueRadius = 0.090 + (0.100 * looseness)
        let distance = circularDistance(sampleHueUnit, channel.centerHueUnit)
        return localWeight(distance: distance, radius: hueRadius, exponent: 2.8)
    }

    private static func circularDistance(_ a: Double, _ b: Double) -> Double {
        let distance = abs(normalizeHueUnit(a) - normalizeHueUnit(b))
        return min(distance, 1.0 - distance)
    }

    private static func localWeight(distance: Double, radius: Double, exponent: Double) -> Double {
        guard radius > 0, distance < radius else { return 0 }
        let normalized = 1.0 - (distance / radius)
        return pow(max(0.0, normalized), exponent)
    }

    private static func hslToRGB(h: Double, s: Double, l: Double) -> RGB {
        let hue = normalizeHueUnit(h)
        let sat = clamp(s, min: 0.0, max: 1.0)
        let lum = clamp(l, min: 0.0, max: 1.0)

        if sat <= 1e-8 {
            return RGB(red: lum, green: lum, blue: lum)
        }

        let q = lum < 0.5 ? (lum * (1.0 + sat)) : (lum + sat - (lum * sat))
        let p = (2.0 * lum) - q

        let red = hueToRGB(p: p, q: q, t: hue + (1.0 / 3.0))
        let green = hueToRGB(p: p, q: q, t: hue)
        let blue = hueToRGB(p: p, q: q, t: hue - (1.0 / 3.0))
        return RGB(red: red, green: green, blue: blue)
    }

    private static func hueToRGB(p: Double, q: Double, t: Double) -> Double {
        var value = t
        if value < 0 { value += 1 }
        if value > 1 { value -= 1 }
        if value < 1.0 / 6.0 { return p + ((q - p) * 6.0 * value) }
        if value < 1.0 / 2.0 { return q }
        if value < 2.0 / 3.0 { return p + ((q - p) * ((2.0 / 3.0) - value) * 6.0) }
        return p
    }
}

extension ColorWheelControl {
    var wheelValue: ColorControlMath.WheelValue {
        ColorControlMath.WheelValue(
            angleRadians: hue,
            intensity: intensity,
            luminance: luma
        )
    }

    init(wheelValue: ColorControlMath.WheelValue) {
        self.init(
            hue: wheelValue.angleRadians,
            intensity: wheelValue.intensity,
            luma: wheelValue.luminance
        )
    }
}

extension ColorAdjustments {
    func hslControl(for channel: ColorControlMath.HSLChannel) -> HSLControl {
        switch channel {
        case .red: return redHSL
        case .orange: return orangeHSL
        case .yellow: return yellowHSL
        case .green: return greenHSL
        case .aqua: return aquaHSL
        case .blue: return blueHSL
        case .purple: return purpleHSL
        case .magenta: return magentaHSL
        }
    }

    mutating func setHSLControl(_ control: HSLControl, for channel: ColorControlMath.HSLChannel) {
        switch channel {
        case .red: redHSL = control
        case .orange: orangeHSL = control
        case .yellow: yellowHSL = control
        case .green: greenHSL = control
        case .aqua: aquaHSL = control
        case .blue: blueHSL = control
        case .purple: purpleHSL = control
        case .magenta: magentaHSL = control
        }
    }
}
