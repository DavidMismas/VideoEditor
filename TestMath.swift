import Foundation
import simd

@main
struct MathTester {
    static func main() {
        print("Running Math Tests...")
        
        // Test S-Log3 roundtrip
        let slog3Def = SignalDefinitionRegistry.shared.definition(for: .sonySLog3SGamut3Cine)!
        let invSlog = slog3Def.inverseTransfer!
        
        let testSLog3Color = SIMD3<Double>(0.5, 0.5, 0.5)
        let linear = invSlog(testSLog3Color)
        
        print("S-Log3 \(testSLog3Color) -> Linear \(linear)")
        
        let gamutConversion = GamutConversion.matrix(from: slog3Def, to: SignalDefinitionRegistry.shared.definition(for: .linearSRGB)!)
        
        let dLinear = simd_double3(linear.x, linear.y, linear.z)
        let srgbLinearlyMapped = gamutConversion * dLinear
        print("Linear S-Gamut3.Cine \(linear) -> Linear sRGB \(srgbLinearlyMapped)")
        
        // Output Transform test
        let acescgDef = SignalDefinitionRegistry.shared.definition(for: .acescg)!
        let slog3ToAcescg = GamutConversion.matrix(from: slog3Def, to: acescgDef)
        let acescgMapped = slog3ToAcescg * dLinear
        print("Linear S-Gamut3.Cine \(linear) -> ACEScg \(acescgMapped)")
        
        print("DONE")
    }
}
