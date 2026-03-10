import Foundation
import simd

extension SignalSpace {
    /// Returns the complete signal definition for the format, if supported.
    nonisolated var definition: SignalDefinition? {
        SignalDefinitionRegistry.shared.definition(for: self)
    }
}

nonisolated final class SignalDefinitionRegistry {
    static let shared = SignalDefinitionRegistry()
    
    private var definitions: [SignalSpace: SignalDefinition] = [:]
    
    private init() {
        registerStandardSpaces()
        registerAppleLog()
        registerSony()
        registerCanon()
        registerPanasonic()
        registerFujifilm()
        registerBlackmagic()
        registerARRI()
        registerRED()
        registerDJI()
    }
    
    nonisolated func definition(for space: SignalSpace) -> SignalDefinition? {
        definitions[space]
    }
    
    private func registerStandardSpaces() {
        definitions[.rec709] = SignalDefinition(
            signalSpace: .rec709,
            isLogEncoded: false,
            isSceneReferred: false,
            primaries: .rec709,
            whitePoint: WhitePointDefinition(chromaticity: PrimariesDefinition.d65),
            inverseTransfer: { color in
                SIMD3(
                    TransferFunctions.rec709ToLinear(color.x),
                    TransferFunctions.rec709ToLinear(color.y),
                    TransferFunctions.rec709ToLinear(color.z)
                )
            },
            forwardTransfer: { color in
                SIMD3(
                    TransferFunctions.linearToRec709(color.x),
                    TransferFunctions.linearToRec709(color.y),
                    TransferFunctions.linearToRec709(color.z)
                )
            }
        )

        definitions[.displayP3] = SignalDefinition(
            signalSpace: .displayP3,
            isLogEncoded: false,
            isSceneReferred: false,
            primaries: .displayP3,
            whitePoint: WhitePointDefinition(chromaticity: PrimariesDefinition.d65),
            inverseTransfer: { color in
                SIMD3(
                    TransferFunctions.sRGBToLinear(color.x),
                    TransferFunctions.sRGBToLinear(color.y),
                    TransferFunctions.sRGBToLinear(color.z)
                )
            },
            forwardTransfer: { color in
                SIMD3(
                    TransferFunctions.linearToSRGB(color.x),
                    TransferFunctions.linearToSRGB(color.y),
                    TransferFunctions.linearToSRGB(color.z)
                )
            }
        )

        definitions[.bt2020] = SignalDefinition(
            signalSpace: .bt2020,
            isLogEncoded: false,
            isSceneReferred: false,
            primaries: .bt2020,
            whitePoint: WhitePointDefinition(chromaticity: PrimariesDefinition.d65),
            inverseTransfer: { color in
                SIMD3(
                    TransferFunctions.rec709ToLinear(color.x),
                    TransferFunctions.rec709ToLinear(color.y),
                    TransferFunctions.rec709ToLinear(color.z)
                )
            },
            forwardTransfer: { color in
                SIMD3(
                    TransferFunctions.linearToRec709(color.x),
                    TransferFunctions.linearToRec709(color.y),
                    TransferFunctions.linearToRec709(color.z)
                )
            }
        )
        
        definitions[.linearSRGB] = SignalDefinition(
            signalSpace: .linearSRGB,
            isLogEncoded: false,
            isSceneReferred: true,
            primaries: .rec709,
            whitePoint: WhitePointDefinition(chromaticity: PrimariesDefinition.d65),
            inverseTransfer: { $0 },
            forwardTransfer: { $0 }
        )
        
        definitions[.acescg] = SignalDefinition(
            signalSpace: .acescg,
            isLogEncoded: false,
            isSceneReferred: true,
            primaries: .acescg,
            whitePoint: WhitePointDefinition(chromaticity: SIMD2<Double>(0.32168, 0.33767)), // ACES ~D60
            inverseTransfer: { $0 },
            forwardTransfer: { $0 }
        )
    }
    
    private func registerAppleLog() {
        definitions[.appleLog] = SignalDefinition(
            signalSpace: .appleLog,
            isLogEncoded: true,
            isSceneReferred: true,
            primaries: .bt2020,
            whitePoint: WhitePointDefinition(chromaticity: PrimariesDefinition.d65),
            inverseTransfer: { color in
                SIMD3(
                    TransferFunctions.appleLogToLinear(color.x),
                    TransferFunctions.appleLogToLinear(color.y),
                    TransferFunctions.appleLogToLinear(color.z)
                )
            },
            forwardTransfer: { color in
                SIMD3(
                    TransferFunctions.linearToAppleLog(color.x),
                    TransferFunctions.linearToAppleLog(color.y),
                    TransferFunctions.linearToAppleLog(color.z)
                )
            }
        )
    }
    
    private func registerSony() {
        definitions[.sonySLog3SGamut3Cine] = SignalDefinition(
            signalSpace: .sonySLog3SGamut3Cine,
            isLogEncoded: true,
            isSceneReferred: true,
            primaries: PrimariesDefinition(
                red: SIMD2<Double>(0.766, 0.275),
                green: SIMD2<Double>(0.225, 0.800),
                blue: SIMD2<Double>(0.089, -0.087)
            ),
            whitePoint: WhitePointDefinition(chromaticity: PrimariesDefinition.d65),
            inverseTransfer: { color in
                SIMD3(
                    TransferFunctions.sonySLog3ToLinear(color.x),
                    TransferFunctions.sonySLog3ToLinear(color.y),
                    TransferFunctions.sonySLog3ToLinear(color.z)
                )
            },
            forwardTransfer: nil
        )
    }

    private func registerCanon() {
        definitions[.canonLog] = SignalDefinition(
            signalSpace: .canonLog,
            isLogEncoded: true,
            isSceneReferred: true,
            primaries: PrimariesDefinition(
                red: SIMD2<Double>(0.7400, 0.2700),
                green: SIMD2<Double>(0.1700, 0.8250),
                blue: SIMD2<Double>(0.0800, -0.0300)
            ), // Canon Cinema Gamut
            whitePoint: WhitePointDefinition(chromaticity: PrimariesDefinition.d65),
            inverseTransfer: { color in
                SIMD3(
                    TransferFunctions.canonLogToLinear(color.x),
                    TransferFunctions.canonLogToLinear(color.y),
                    TransferFunctions.canonLogToLinear(color.z)
                )
            },
            forwardTransfer: nil
        )

        definitions[.canonLog2] = SignalDefinition(
            signalSpace: .canonLog2,
            isLogEncoded: true,
            isSceneReferred: true,
            primaries: PrimariesDefinition(
                red: SIMD2<Double>(0.7400, 0.2700),
                green: SIMD2<Double>(0.1700, 0.8250),
                blue: SIMD2<Double>(0.0800, -0.0300)
            ), // Canon Cinema Gamut
            whitePoint: WhitePointDefinition(chromaticity: PrimariesDefinition.d65),
            inverseTransfer: { color in
                SIMD3(
                    TransferFunctions.canonLog2ToLinear(color.x),
                    TransferFunctions.canonLog2ToLinear(color.y),
                    TransferFunctions.canonLog2ToLinear(color.z)
                )
            },
            forwardTransfer: nil
        )

        definitions[.canonLog3] = SignalDefinition(
            signalSpace: .canonLog3,
            isLogEncoded: true,
            isSceneReferred: true,
            primaries: PrimariesDefinition(
                red: SIMD2<Double>(0.7400, 0.2700),
                green: SIMD2<Double>(0.1700, 0.8250),
                blue: SIMD2<Double>(0.0800, -0.0300)
            ), // Canon Cinema Gamut
            whitePoint: WhitePointDefinition(chromaticity: PrimariesDefinition.d65),
            inverseTransfer: { color in
                SIMD3(
                    TransferFunctions.canonLog3ToLinear(color.x),
                    TransferFunctions.canonLog3ToLinear(color.y),
                    TransferFunctions.canonLog3ToLinear(color.z)
                )
            },
            forwardTransfer: nil
        )
    }
    
    private func registerPanasonic() {
        definitions[.panasonicVLogVGamut] = SignalDefinition(
            signalSpace: .panasonicVLogVGamut,
            isLogEncoded: true,
            isSceneReferred: true,
            primaries: PrimariesDefinition(
                red: SIMD2<Double>(0.730, 0.280),
                green: SIMD2<Double>(0.165, 0.840),
                blue: SIMD2<Double>(0.100, -0.030)
            ), // V-Gamut
            whitePoint: WhitePointDefinition(chromaticity: PrimariesDefinition.d65),
            inverseTransfer: { color in
                SIMD3(
                    TransferFunctions.panasonicVLogToLinear(color.x),
                    TransferFunctions.panasonicVLogToLinear(color.y),
                    TransferFunctions.panasonicVLogToLinear(color.z)
                )
            },
            forwardTransfer: nil
        )
    }

    private func registerFujifilm() {
        definitions[.fujiFLogFGamut] = SignalDefinition(
            signalSpace: .fujiFLogFGamut,
            isLogEncoded: true,
            isSceneReferred: true,
            primaries: PrimariesDefinition(
                red: SIMD2<Double>(0.708, 0.292),
                green: SIMD2<Double>(0.170, 0.797),
                blue: SIMD2<Double>(0.131, 0.046)
            ), // BT.2020 Primaries
            whitePoint: WhitePointDefinition(chromaticity: PrimariesDefinition.d65),
            inverseTransfer: { color in
                SIMD3(
                    TransferFunctions.fujiFLogToLinear(color.x),
                    TransferFunctions.fujiFLogToLinear(color.y),
                    TransferFunctions.fujiFLogToLinear(color.z)
                )
            },
            forwardTransfer: nil
        )

        definitions[.fujiFLog2FGamut] = SignalDefinition(
            signalSpace: .fujiFLog2FGamut,
            isLogEncoded: true,
            isSceneReferred: true,
            primaries: PrimariesDefinition(
                red: SIMD2<Double>(0.708, 0.292),
                green: SIMD2<Double>(0.170, 0.797),
                blue: SIMD2<Double>(0.131, 0.046)
            ), // BT.2020 Primaries
            whitePoint: WhitePointDefinition(chromaticity: PrimariesDefinition.d65),
            inverseTransfer: { color in
                SIMD3(
                    TransferFunctions.fujiFLog2ToLinear(color.x),
                    TransferFunctions.fujiFLog2ToLinear(color.y),
                    TransferFunctions.fujiFLog2ToLinear(color.z)
                )
            },
            forwardTransfer: nil
        )
    }
    
    private func registerBlackmagic() {
        // BMD Film Gen 5
        definitions[.bmdFilmGen5WideGamut] = SignalDefinition(
            signalSpace: .bmdFilmGen5WideGamut,
            isLogEncoded: true,
            isSceneReferred: true,
            primaries: PrimariesDefinition(
                red: SIMD2<Double>(0.7347, 0.2653),
                green: SIMD2<Double>(0.1142, 0.8265),
                blue: SIMD2<Double>(0.1009, -0.0810) // Approx BMD Wide Gamut
            ),
            whitePoint: WhitePointDefinition(chromaticity: PrimariesDefinition.d65),
            inverseTransfer: nil, // Add formula
            forwardTransfer: nil
        )
    }

    private func registerARRI() {
        definitions[.arriLogC3WideGamut3] = SignalDefinition(
            signalSpace: .arriLogC3WideGamut3,
            isLogEncoded: true,
            isSceneReferred: true,
            primaries: PrimariesDefinition(
                red: SIMD2<Double>(0.684, 0.313),
                green: SIMD2<Double>(0.121, 0.848),
                blue: SIMD2<Double>(0.116, 0.042)
            ),
            whitePoint: WhitePointDefinition(chromaticity: PrimariesDefinition.d65),
            inverseTransfer: { color in
                SIMD3(
                    TransferFunctions.arriLogC3ToLinear(color.x),
                    TransferFunctions.arriLogC3ToLinear(color.y),
                    TransferFunctions.arriLogC3ToLinear(color.z)
                )
            },
            forwardTransfer: nil
        )
        
        definitions[.arriLogC4WideGamut4] = SignalDefinition(
            signalSpace: .arriLogC4WideGamut4,
            isLogEncoded: true,
            isSceneReferred: true,
            primaries: PrimariesDefinition(
                red: SIMD2<Double>(0.7347, 0.2653),
                green: SIMD2<Double>(0.1142, 0.8265),
                blue: SIMD2<Double>(0.0913, -0.0430) // AWG4 approx
            ),
            whitePoint: WhitePointDefinition(chromaticity: PrimariesDefinition.d65),
            inverseTransfer: { color in
                SIMD3(
                    TransferFunctions.arriLogC4ToLinear(color.x),
                    TransferFunctions.arriLogC4ToLinear(color.y),
                    TransferFunctions.arriLogC4ToLinear(color.z)
                )
            },
            forwardTransfer: nil
        )
    }
    
    private func registerRED() {
        definitions[.redLog3G10RWG] = SignalDefinition(
            signalSpace: .redLog3G10RWG,
            isLogEncoded: true,
            isSceneReferred: true,
            primaries: PrimariesDefinition(
                red: SIMD2<Double>(0.780308, 0.304253),
                green: SIMD2<Double>(0.121595, 1.493994),
                blue: SIMD2<Double>(0.095612, -0.027034)
            ),
            whitePoint: WhitePointDefinition(chromaticity: PrimariesDefinition.d65),
            inverseTransfer: nil,
            forwardTransfer: nil
        )
    }
    
    private func registerDJI() {
        definitions[.djiDLogDGamut] = SignalDefinition(
            signalSpace: .djiDLogDGamut,
            isLogEncoded: true,
            isSceneReferred: true,
            primaries: PrimariesDefinition(
                red: SIMD2<Double>(0.710, 0.310),
                green: SIMD2<Double>(0.210, 0.810),
                blue: SIMD2<Double>(0.090, -0.080) // Approx
            ),
            whitePoint: WhitePointDefinition(chromaticity: PrimariesDefinition.d65),
            inverseTransfer: { color in
                SIMD3(
                    TransferFunctions.djiDLogToLinear(color.x),
                    TransferFunctions.djiDLogToLinear(color.y),
                    TransferFunctions.djiDLogToLinear(color.z)
                )
            },
            forwardTransfer: nil
        )
    }
}
