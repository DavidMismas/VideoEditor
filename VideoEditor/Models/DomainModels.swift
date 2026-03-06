import Foundation
import CoreMedia
import UniformTypeIdentifiers

import SwiftUI // Needed for Transferable

struct MediaItem: Identifiable, Hashable, Codable, Transferable {
    var id: UUID = UUID()
    var name: String
    var url: URL?
    var type: MediaType
    var durationSeconds: Double? = nil
    
    enum MediaType: String, Codable {
        case video
        case audio
        case image
    }
    
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}

struct LUTItem: Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var url: URL
}

nonisolated struct HSLControl: Equatable {
    var hue: Double = 0.0 // -1 to 1 (adjustment)
    var saturation: Double = 1.0 // 0 to 2 (multiplier)
    var luminance: Double = 0.0 // -1 to 1 (adjustment)
}

nonisolated struct ColorWheelControl: Equatable {
    var hue: Double = 0.0 // 0 to 2pi (radians)
    var intensity: Double = 0.0 // 0 to 1
    var luma: Double = 0.0 // -1 to 1
}

nonisolated enum ColorSpaceProfile: String, CaseIterable, Equatable {
    case rec709 = "Rec.709"
    case displayP3 = "Display P3"
    case bt2020 = "BT.2020"
}

nonisolated enum WorkingColorSpaceProfile: String, CaseIterable, Equatable {
    case linearSRGB = "Linear sRGB"
    case acescg = "ACEScg"
}

nonisolated struct ToneCurvePoints: Equatable {
    var p0: Double = 0.0
    var p1: Double = 0.25
    var p2: Double = 0.5
    var p3: Double = 0.75
    var p4: Double = 1.0

    var values: [Double] {
        [p0, p1, p2, p3, p4]
    }
}

nonisolated struct ColorAdjustments: Equatable {
    // Color pipeline
    var inputColorSpace: ColorSpaceProfile = .rec709
    var workingColorSpace: WorkingColorSpaceProfile = .linearSRGB
    var outputColorSpace: ColorSpaceProfile = .rec709

    var exposure: Double = 0
    var contrast: Double = 1.0
    var highlights: Double = 0
    var shadows: Double = 0
    var filmicHighlightRolloff: Double = 0.0
    
    var clarity: Double = 0
    var sharpness: Double = 0
    
    // Basic Color
    var hue: Double = 0
    var saturation: Double = 1.0
    var vibrance: Double = 0
    
    // True HSL
    var redHSL = HSLControl()
    var orangeHSL = HSLControl()
    var yellowHSL = HSLControl()
    var greenHSL = HSLControl()
    var aquaHSL = HSLControl()
    var blueHSL = HSLControl()
    var purpleHSL = HSLControl()
    var magentaHSL = HSLControl()
    var hslTightness: Double = 0.50
    
    // Color Grading
    var globalTint = ColorWheelControl()
    var shadowTint = ColorWheelControl()
    var highlightTint = ColorWheelControl()
    var shadowRange: Double = 0.45
    var highlightRange: Double = 0.90

    // Professional LGGO controls
    var lift: Double = 0.0
    var gamma: Double = 1.0
    var gain: Double = 1.0
    var offset: Double = 0.0
    var liftWheel = ColorWheelControl()
    var gammaWheel = ColorWheelControl()
    var gainWheel = ColorWheelControl()
    var offsetWheel = ColorWheelControl()

    // Tone curves
    var lumaCurveEnabled: Bool = true
    var lumaCurve = ToneCurvePoints()
    var rgbCurvesEnabled: Bool = false
    var redCurve = ToneCurvePoints()
    var greenCurve = ToneCurvePoints()
    var blueCurve = ToneCurvePoints()
    
    // Effects
    var vignette: Double = 0
    var softBlur: Double = 0
}

nonisolated struct Transforms: Equatable {
    var cropRect: CGRect?
    var rotation: Double = 0
    var scale: Double = 1.0
}
