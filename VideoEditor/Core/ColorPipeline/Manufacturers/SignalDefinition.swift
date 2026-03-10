import simd

/// Defines the color primaries for a gamut.
nonisolated struct PrimariesDefinition {
    let red: SIMD2<Double>
    let green: SIMD2<Double>
    let blue: SIMD2<Double>
    
    // Standard Illuminants
    static let d65 = SIMD2<Double>(0.3127, 0.3290)
    
    // Standard Primaries
    static let rec709 = PrimariesDefinition(
        red: SIMD2<Double>(0.640, 0.330),
        green: SIMD2<Double>(0.300, 0.600),
        blue: SIMD2<Double>(0.150, 0.060)
    )
    
    static let displayP3 = PrimariesDefinition(
        red: SIMD2<Double>(0.680, 0.320),
        green: SIMD2<Double>(0.265, 0.690),
        blue: SIMD2<Double>(0.150, 0.060)
    )
    
    static let bt2020 = PrimariesDefinition(
        red: SIMD2<Double>(0.708, 0.292),
        green: SIMD2<Double>(0.170, 0.797),
        blue: SIMD2<Double>(0.131, 0.046)
    )
    
    static let acescg = PrimariesDefinition(
        red: SIMD2<Double>(0.713, 0.293),
        green: SIMD2<Double>(0.165, 0.830),
        blue: SIMD2<Double>(0.128, 0.044)
    )
}

nonisolated struct WhitePointDefinition {
    let chromaticity: SIMD2<Double>
}

nonisolated struct SignalDefinition {
    let signalSpace: SignalSpace
    let isLogEncoded: Bool
    let isSceneReferred: Bool
    let primaries: PrimariesDefinition
    let whitePoint: WhitePointDefinition
    let inverseTransfer: ((SIMD3<Double>) -> SIMD3<Double>)?
    let forwardTransfer: ((SIMD3<Double>) -> SIMD3<Double>)? // For display transforms (optional)
}
