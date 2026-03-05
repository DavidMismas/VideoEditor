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
}

nonisolated struct ColorAdjustments: Equatable {
    var exposure: Double = 0
    var contrast: Double = 1.0
    var highlights: Double = 0
    var shadows: Double = 0
    
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
    
    // Effects
    var vignette: Double = 0
    var softBlur: Double = 0
    var grain: Double = 0
}

nonisolated struct Transforms: Equatable {
    var cropRect: CGRect?
    var rotation: Double = 0
    var scale: Double = 1.0
}
