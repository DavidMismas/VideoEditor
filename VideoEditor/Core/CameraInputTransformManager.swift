import Foundation
import CoreImage
import CoreGraphics

nonisolated final class CameraInputTransformManager {
    static let shared = CameraInputTransformManager()

    private struct CubeDefinition {
        let dimension: Int
        let data: Data
        let outputColorSpace: CGColorSpace
    }

    private let cacheQueue = DispatchQueue(label: "CameraInputTransformManager.cacheQueue")
    private var cache: [SignalSpace: CubeDefinition] = [:]

    private init() {}

    func supportsTransform(for signalSpace: SignalSpace) -> Bool {
        cubeDefinition(for: signalSpace) != nil
    }

    func applyTransformToLinearSRGB(
        for signalSpace: SignalSpace,
        to image: CIImage
    ) -> CIImage? {
        guard let cube = cubeDefinition(for: signalSpace),
              let filter = CIFilter(name: "CIColorCube") else {
            return nil
        }

        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(cube.dimension, forKey: "inputCubeDimension")
        filter.setValue(cube.data, forKey: "inputCubeData")
        filter.setValue(true, forKey: "inputExtrapolate")
        return filter.outputImage
    }

    func outputColorSpace(for signalSpace: SignalSpace) -> CGColorSpace? {
        cubeDefinition(for: signalSpace)?.outputColorSpace
    }

    private func cubeDefinition(for signalSpace: SignalSpace) -> CubeDefinition? {
        if let cached = cacheQueue.sync(execute: { cache[signalSpace] }) {
            return cached
        }

        guard let built = makeCubeDefinition(for: signalSpace) else {
            return nil
        }

        cacheQueue.sync {
            cache[signalSpace] = built
        }
        return built
    }

    private func makeCubeDefinition(for signalSpace: SignalSpace) -> CubeDefinition? {
        let linearSRGB = CGColorSpace(name: CGColorSpace.linearSRGB)

        switch signalSpace {
        case .sonySLog3SGamut3Cine:
            guard let linearSRGB else { return nil }
            return CubeDefinition(
                dimension: 65,
                data: generateCubeData(
                    dimension: 65,
                    transfer: sonySLog3ToLinear,
                    gamutMatrix: [
                        [1.626947409729081, -0.540138538869635, -0.086808870859445],
                        [-0.178515527114877, 1.417940927464079, -0.239425400349203],
                        [-0.044436115009298, -0.195919966172015, 1.240356081181313]
                    ]
                ),
                outputColorSpace: linearSRGB
            )

        case .appleLog:
            guard let linearSRGB else { return nil }
            return CubeDefinition(
                dimension: 65,
                data: generateCubeData(
                    dimension: 65,
                    transfer: appleLogToLinear,
                    gamutMatrix: [
                        [1.660491002108435, -0.587641138788550, -0.072849863319885],
                        [-0.124550474521591, 1.132899897125960, -0.008349422604369],
                        [-0.018150763354905, -0.100578898008007, 1.118729661362913]
                    ]
                ),
                outputColorSpace: linearSRGB
            )

        case .sonySLog2SGamut,
             .sonySLog3SGamut3,
             .canonLog, .canonLog2, .canonLog3, .canonCinemaGamut,
             .panasonicVLogVGamut,
             .fujiFLogFGamut, .fujiFLog2FGamut,
             .bmdFilmGen5WideGamut,
             .arriLogC3WideGamut3, .arriLogC4WideGamut4,
             .redLog3G10RWG,
             .djiDLogDGamut, .djiDLogM, .goProGPLog,
             .rec709, .displayP3, .bt2020, .linearSRGB, .acescg, .appleLog2, .unknown:
            return nil
        }
    }

    private func generateCubeData(
        dimension: Int,
        transfer: (Double) -> Double,
        gamutMatrix: [[Double]]
    ) -> Data {
        var cube = [Float](repeating: 0, count: dimension * dimension * dimension * 4)

        for b in 0..<dimension {
            let blue = Double(b) / Double(dimension - 1)
            let decodedBlue = transfer(blue)

            for g in 0..<dimension {
                let green = Double(g) / Double(dimension - 1)
                let decodedGreen = transfer(green)

                for r in 0..<dimension {
                    let red = Double(r) / Double(dimension - 1)
                    let decodedRed = transfer(red)

                    let transformedRed = (gamutMatrix[0][0] * decodedRed) + (gamutMatrix[0][1] * decodedGreen) + (gamutMatrix[0][2] * decodedBlue)
                    let transformedGreen = (gamutMatrix[1][0] * decodedRed) + (gamutMatrix[1][1] * decodedGreen) + (gamutMatrix[1][2] * decodedBlue)
                    let transformedBlue = (gamutMatrix[2][0] * decodedRed) + (gamutMatrix[2][1] * decodedGreen) + (gamutMatrix[2][2] * decodedBlue)

                    let offset = ((b * dimension * dimension) + (g * dimension) + r) * 4
                    cube[offset + 0] = Float(transformedRed)
                    cube[offset + 1] = Float(transformedGreen)
                    cube[offset + 2] = Float(transformedBlue)
                    cube[offset + 3] = 1.0
                }
            }
        }

        return cube.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private func sonySLog3ToLinear(_ x: Double) -> Double {
        let threshold = 171.2102946929 / 1023.0
        if x >= threshold {
            return pow(10.0, ((x * 1023.0) - 420.0) / 261.5) * (0.18 + 0.01) - 0.01
        }

        return ((x * 1023.0) - 95.0) * 0.01125 / (171.2102946929 - 95.0)
    }

    private func appleLogToLinear(_ x: Double) -> Double {
        let r0 = -0.05641088
        let rt = 0.01
        let c = 47.28711236
        let b = 0.00964052
        let y = 0.08550479
        let d = 0.69336945
        let threshold = c * pow(rt - r0, 2.0)

        if x >= threshold {
            return exp2((x - d) / y) - b
        }
        if x > 0.0 {
            return sqrt(x / c) + r0
        }
        return r0
    }
}
