import Foundation
import CoreMedia
import CoreGraphics
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

    init(
        id: UUID = UUID(),
        name: String,
        url: URL?,
        type: MediaType,
        durationSeconds: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.type = type
        self.durationSeconds = durationSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case url
        case type
        case durationSeconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        url = try container.decodeIfPresent(URL.self, forKey: .url)
        type = try container.decode(MediaType.self, forKey: .type)
        durationSeconds = try container.decodeIfPresent(Double.self, forKey: .durationSeconds)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(url, forKey: .url)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(durationSeconds, forKey: .durationSeconds)
    }
}

struct LUTItem: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var name: String
    var url: URL
    var descriptor: ImportedLUTDescriptor = .creative

    init(
        id: UUID = UUID(),
        name: String,
        url: URL,
        descriptor: ImportedLUTDescriptor = .creative
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.descriptor = descriptor
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case url
        case descriptor
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        url = try container.decode(URL.self, forKey: .url)
        descriptor = try container.decodeIfPresent(ImportedLUTDescriptor.self, forKey: .descriptor) ?? .creative
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(url, forKey: .url)
        try container.encode(descriptor, forKey: .descriptor)
    }
}

nonisolated enum SignalSpace: String, CaseIterable, Equatable, Hashable, Codable {
    case rec709 = "Rec.709"
    case displayP3 = "Display P3"
    case bt2020 = "BT.2020"
    case linearSRGB = "Linear sRGB"
    case acescg = "ACEScg"
    case appleLog = "Apple Log"
    case appleLog2 = "Apple Log 2"
    case sonySLog2SGamut = "Sony S-Log2 / S-Gamut"
    case sonySLog3SGamut3 = "Sony S-Log3 / S-Gamut3"
    case sonySLog3SGamut3Cine = "Sony S-Log3 / S-Gamut3.Cine"
    case canonLog = "Canon Log"
    case canonLog2 = "Canon Log 2"
    case canonLog3 = "Canon Log 3"
    case canonCinemaGamut = "Canon Cinema Gamut"
    case panasonicVLogVGamut = "Panasonic V-Log / V-Gamut"
    case fujiFLogFGamut = "Fujifilm F-Log / F-Gamut"
    case fujiFLog2FGamut = "Fujifilm F-Log2 / F-Gamut"
    case bmdFilmGen5WideGamut = "BMD Film Gen 5 / Wide Gamut"
    case arriLogC3WideGamut3 = "ARRI LogC3 / Wide Gamut 3"
    case arriLogC4WideGamut4 = "ARRI LogC4 / Wide Gamut 4"
    case redLog3G10RWG = "RED Log3G10 / REDWideGamutRGB"
    case djiDLogDGamut = "DJI D-Log / D-Gamut"
    case djiDLogM = "DJI D-Log M"
    case goProGPLog = "GoPro GP-Log"
    case unknown = "Unknown"

    var displayName: String {
        rawValue
    }

    var managedColorSpace: ColorSpace? {
        switch self {
        case .rec709:
            return .rec709
        case .displayP3:
            return .displayP3
        case .bt2020:
            return .bt2020
        case .linearSRGB:
            return .linearSRGB
        case .acescg:
            return .acescg
        case .appleLog, .appleLog2,
             .sonySLog2SGamut, .sonySLog3SGamut3, .sonySLog3SGamut3Cine,
             .canonLog, .canonLog2, .canonLog3, .canonCinemaGamut,
             .panasonicVLogVGamut,
             .fujiFLogFGamut, .fujiFLog2FGamut,
             .bmdFilmGen5WideGamut,
             .arriLogC3WideGamut3, .arriLogC4WideGamut4,
             .redLog3G10RWG,
             .djiDLogDGamut, .djiDLogM, .goProGPLog,
             .unknown:
            return nil
        }
    }

    var cgColorSpace: CGColorSpace? {
        managedColorSpace?.cgColorSpace
    }

    var supportsBuiltInInputTransform: Bool {
        switch self {
        case .appleLog,
             .sonySLog2SGamut, .sonySLog3SGamut3, .sonySLog3SGamut3Cine,
             .canonLog, .canonLog2, .canonLog3, .canonCinemaGamut,
             .panasonicVLogVGamut,
             .fujiFLogFGamut, .fujiFLog2FGamut,
             .bmdFilmGen5WideGamut,
             .arriLogC3WideGamut3, .arriLogC4WideGamut4,
             .redLog3G10RWG,
             .djiDLogDGamut, .djiDLogM, .goProGPLog:
            return true
        case .rec709, .displayP3, .bt2020, .linearSRGB, .acescg, .appleLog2, .unknown:
            return false
        }
    }

    init(_ profile: ColorSpaceProfile) {
        switch profile {
        case .rec709:
            self = .rec709
        case .displayP3:
            self = .displayP3
        case .bt2020:
            self = .bt2020
        }
    }

    init(_ colorSpace: ColorSpace) {
        switch colorSpace {
        case .rec709:
            self = .rec709
        case .displayP3:
            self = .displayP3
        case .bt2020:
            self = .bt2020
        case .linearSRGB:
            self = .linearSRGB
        case .acescg:
            self = .acescg
        }
    }
}

nonisolated enum ImportedLUTRole: String, Equatable, Hashable, Codable {
    case creative
    case technicalTransform
}

nonisolated struct ImportedLUTDescriptor: Equatable, Hashable, Codable {
    var role: ImportedLUTRole = .creative
    var inputSignalSpace: SignalSpace? = nil
    var outputSignalSpace: SignalSpace? = nil

    static let creativeUnknown = ImportedLUTDescriptor()
    static let creative = creativeUnknown

    static func creative(lutSpace: SignalSpace) -> ImportedLUTDescriptor {
        ImportedLUTDescriptor(
            role: .creative,
            inputSignalSpace: lutSpace,
            outputSignalSpace: lutSpace
        )
    }

    static func technical(input: SignalSpace, output: SignalSpace) -> ImportedLUTDescriptor {
        ImportedLUTDescriptor(
            role: .technicalTransform,
            inputSignalSpace: input,
            outputSignalSpace: output
        )
    }

    var isTechnicalTransform: Bool {
        role == .technicalTransform
    }

    var creativeLUTSpace: SignalSpace? {
        guard role == .creative,
              inputSignalSpace == outputSignalSpace else {
            return nil
        }
        return inputSignalSpace
    }

    var hasExplicitColorSpaces: Bool {
        switch role {
        case .creative:
            return creativeLUTSpace != nil
        case .technicalTransform:
            return inputSignalSpace != nil && outputSignalSpace != nil
        }
    }
}

nonisolated struct HSLControl: Equatable, Codable {
    var hue: Double = 0.0 // -1 to 1 (adjustment)
    var saturation: Double = 1.0 // 0 to 2 (multiplier)
    var luminance: Double = 0.0 // -1 to 1 (adjustment)
}

nonisolated struct ColorWheelControl: Equatable, Codable {
    var hue: Double = 0.0 // 0 to 2pi (radians)
    var intensity: Double = 0.0 // 0 to 1
    var luma: Double = 0.0 // -1 to 1
}

nonisolated enum ColorSpaceProfile: String, CaseIterable, Equatable, Codable {
    case rec709 = "Rec.709"
    case displayP3 = "Display P3"
    case bt2020 = "BT.2020"
}

nonisolated enum WorkingColorSpaceProfile: String, CaseIterable, Equatable, Codable {
    case linearSRGB = "Linear sRGB"
    case acescg = "ACEScg"
}

nonisolated enum ColorSpace: String, CaseIterable, Equatable, Hashable, Codable {
    case rec709 = "Rec.709"
    case displayP3 = "Display P3"
    case bt2020 = "BT.2020"
    case linearSRGB = "Linear sRGB"
    case acescg = "ACEScg"

    init(_ profile: ColorSpaceProfile) {
        switch profile {
        case .rec709:
            self = .rec709
        case .displayP3:
            self = .displayP3
        case .bt2020:
            self = .bt2020
        }
    }

    init(_ profile: WorkingColorSpaceProfile) {
        switch profile {
        case .linearSRGB:
            self = .linearSRGB
        case .acescg:
            self = .acescg
        }
    }

    var cgColorSpace: CGColorSpace? {
        switch self {
        case .rec709:
            return CGColorSpace(name: CGColorSpace.itur_709)
        case .displayP3:
            return CGColorSpace(name: CGColorSpace.displayP3)
        case .bt2020:
            return CGColorSpace(name: CGColorSpace.itur_2020)
        case .linearSRGB:
            return CGColorSpace(name: CGColorSpace.linearSRGB)
        case .acescg:
            return CGColorSpace(name: CGColorSpace.acescgLinear)
        }
    }
}

nonisolated struct ToneCurvePoints: Equatable, Codable {
    var p0: Double = 0.0
    var p1: Double = 0.25
    var p2: Double = 0.5
    var p3: Double = 0.75
    var p4: Double = 1.0

    var values: [Double] {
        [p0, p1, p2, p3, p4]
    }
}

nonisolated struct ColorAdjustments: Equatable, Codable {
    // Color pipeline
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

nonisolated extension ColorAdjustments {
    private var hasHSLSecondaryAdjustments: Bool {
        let identity = HSLControl()
        return redHSL != identity ||
            orangeHSL != identity ||
            yellowHSL != identity ||
            greenHSL != identity ||
            aquaHSL != identity ||
            blueHSL != identity ||
            purpleHSL != identity ||
            magentaHSL != identity
    }

    private var hasLGGOAdjustments: Bool {
        let identityWheel = ColorWheelControl()
        return abs(lift) > 1e-6 ||
            abs(gamma - 1.0) > 1e-6 ||
            abs(gain - 1.0) > 1e-6 ||
            abs(offset) > 1e-6 ||
            liftWheel != identityWheel ||
            gammaWheel != identityWheel ||
            gainWheel != identityWheel ||
            offsetWheel != identityWheel
    }

    private var hasCurveAdjustments: Bool {
        let identityCurve = ToneCurvePoints()
        let hasLumaCurve = lumaCurveEnabled && lumaCurve != identityCurve
        let hasRGBCurves = rgbCurvesEnabled && (
            redCurve != identityCurve ||
                greenCurve != identityCurve ||
                blueCurve != identityCurve
        )
        return hasLumaCurve || hasRGBCurves
    }

    var hasDirectPrimaryToneAdjustments: Bool {
        abs(exposure) > 1e-6 ||
            abs(contrast - 1.0) > 1e-6 ||
            abs(highlights) > 1e-6 ||
            abs(shadows) > 1e-6 ||
            abs(filmicHighlightRolloff) > 1e-6
    }

    var hasGeneratedLUTAdjustments: Bool {
        abs(hue) > 1e-6 ||
            abs(saturation - 1.0) > 1e-6 ||
            abs(vibrance) > 1e-6 ||
            hasHSLSecondaryAdjustments ||
            hasLGGOAdjustments ||
            hasCurveAdjustments
    }

    var generatedLUTAdjustments: ColorAdjustments {
        var copy = ColorAdjustments()
        copy.workingColorSpace = workingColorSpace

        copy.hue = hue
        copy.saturation = saturation
        copy.vibrance = vibrance

        copy.redHSL = redHSL
        copy.orangeHSL = orangeHSL
        copy.yellowHSL = yellowHSL
        copy.greenHSL = greenHSL
        copy.aquaHSL = aquaHSL
        copy.blueHSL = blueHSL
        copy.purpleHSL = purpleHSL
        copy.magentaHSL = magentaHSL
        copy.hslTightness = hslTightness

        copy.lift = lift
        copy.gamma = gamma
        copy.gain = gain
        copy.offset = offset
        copy.liftWheel = liftWheel
        copy.gammaWheel = gammaWheel
        copy.gainWheel = gainWheel
        copy.offsetWheel = offsetWheel

        copy.lumaCurveEnabled = lumaCurveEnabled
        copy.lumaCurve = lumaCurve
        copy.rgbCurvesEnabled = rgbCurvesEnabled
        copy.redCurve = redCurve
        copy.greenCurve = greenCurve
        copy.blueCurve = blueCurve

        return copy
    }
}

nonisolated struct Transforms: Equatable, Codable {
    var cropRect: CGRect?
    var rotation: Double = 0
    var scale: Double = 1.0
}
