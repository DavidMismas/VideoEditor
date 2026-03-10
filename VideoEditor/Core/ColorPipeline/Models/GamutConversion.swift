import Foundation
import simd

/// Utility for generating 3x3 matrices to convert between RGB color spaces
/// using their primaries and white points.
nonisolated enum GamutConversion {
    
    /// Generates a 3x3 conversion matrix from a source signal define to a destination signal define.
    /// Both definitions must have valid primaries and white points.
    static func matrix(from source: SignalDefinition, to destination: SignalDefinition) -> simd_double3x3 {
        // Source to XYZ
        let srcToXYZ = rgbToXYZMatrix(primaries: source.primaries, whitePoint: source.whitePoint)
        
        // XYZ to Destination
        let destToXYZ = rgbToXYZMatrix(primaries: destination.primaries, whitePoint: destination.whitePoint)
        let xyzToDest = destToXYZ.inverse
        
        // Source to Destination (chromatic adaptation is needed if white points differ,
        // but for standard video spaces they are often all D65)
        // If they differ, Bradford adaptation would be needed here. 
        // For simplicity, assuming D65 for most (or applying simple XYZ-to-XYZ if D60/ACEScg).
        var m = xyzToDest * srcToXYZ
        
        if source.whitePoint.chromaticity != destination.whitePoint.chromaticity {
            // Bradford chromatic adaptation
            let adaptation = bradfordAdaptationMatrix(from: source.whitePoint.chromaticity, to: destination.whitePoint.chromaticity)
            m = xyzToDest * adaptation * srcToXYZ
        }
        
        return m
    }
    
    static func rgbToXYZMatrix(primaries: PrimariesDefinition, whitePoint: WhitePointDefinition) -> simd_double3x3 {
        let xr = primaries.red.x, yr = primaries.red.y
        let xg = primaries.green.x, yg = primaries.green.y
        let xb = primaries.blue.x, yb = primaries.blue.y
        let xw = whitePoint.chromaticity.x, yw = whitePoint.chromaticity.y
        
        let Xr = xr / yr, Yr = 1.0, Zr = (1.0 - xr - yr) / yr
        let Xg = xg / yg, Yg = 1.0, Zg = (1.0 - xg - yg) / yg
        let Xb = xb / yb, Yb = 1.0, Zb = (1.0 - xb - yb) / yb
        
        let Xw = xw / yw, Yw = 1.0, Zw = (1.0 - xw - yw) / yw
        
        let m = simd_double3x3([
            simd_double3(Xr, Yr, Zr),
            simd_double3(Xg, Yg, Zg),
            simd_double3(Xb, Yb, Zb)
        ])
        
        let w = simd_double3(Xw, Yw, Zw)
        let s = m.inverse * w
        
        let C = simd_double3x3([
            simd_double3(s.x * Xr, s.x * Yr, s.x * Zr),
            simd_double3(s.y * Xg, s.y * Yg, s.y * Zg),
            simd_double3(s.z * Xb, s.z * Yb, s.z * Zb)
        ])
        
        return C
    }
    
    // Bradford Chromatic Adaptation Matrix
    static func bradfordAdaptationMatrix(from srcWxy: SIMD2<Double>, to dstWxy: SIMD2<Double>) -> simd_double3x3 {
        let srcW = simd_double3(srcWxy.x / srcWxy.y, 1.0, (1.0 - srcWxy.x - srcWxy.y) / srcWxy.y)
        let dstW = simd_double3(dstWxy.x / dstWxy.y, 1.0, (1.0 - dstWxy.x - dstWxy.y) / dstWxy.y)
        
        let Mb = simd_double3x3([
            simd_double3(0.8951000, -0.7502000,  0.0389000),
            simd_double3(0.2664000,  1.7135000, -0.0685000),
            simd_double3(-0.1614000,  0.0367000,  1.0296000)
        ])
        
        let MbInv = Mb.inverse
        
        let srcRGB = Mb * srcW
        let dstRGB = Mb * dstW
        
        let d = simd_double3x3([
            simd_double3(dstRGB.x / srcRGB.x, 0, 0),
            simd_double3(0, dstRGB.y / srcRGB.y, 0),
            simd_double3(0, 0, dstRGB.z / srcRGB.z)
        ])
        
        return MbInv * d * Mb
    }
}
