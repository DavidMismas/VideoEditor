import Foundation
import CoreGraphics
import CoreImage
import simd

nonisolated private struct TransformCubeDefinition {
    let dimension: Int
    let data: Data
}

nonisolated private struct TransformCubeKey: Hashable {
    let source: SignalSpace
    let destination: SignalSpace
}

nonisolated private final class TransformCubeCache {
    static let shared = TransformCubeCache()

    private let cacheQueue = DispatchQueue(label: "TransformCubeCache.queue")
    private var cache: [TransformCubeKey: TransformCubeDefinition] = [:]
    private let dimension = 65

    private init() {}

    func cube(from source: SignalDefinition, to destination: SignalDefinition) -> TransformCubeDefinition? {
        let key = TransformCubeKey(source: source.signalSpace, destination: destination.signalSpace)
        if let cached = cacheQueue.sync(execute: { cache[key] }) {
            return cached
        }

        guard let inverseTransfer = source.inverseTransfer else {
            return nil
        }

        let conversionMatrix = GamutConversion.matrix(from: source, to: destination)
        let built = buildCube { red, green, blue in
            let linearSignal = inverseTransfer(SIMD3<Double>(red, green, blue))
            let mapped = conversionMatrix * simd_double3(linearSignal.x, linearSignal.y, linearSignal.z)

            guard let forwardTransfer = destination.forwardTransfer else {
                return SIMD3(mapped.x, mapped.y, mapped.z)
            }

            let encoded = forwardTransfer(SIMD3<Double>(mapped.x, mapped.y, mapped.z))
            return SIMD3(encoded.x, encoded.y, encoded.z)
        }

        cacheQueue.sync {
            cache[key] = built
        }
        return built
    }

    private func buildCube(
        mapping: (Double, Double, Double) -> SIMD3<Double>
    ) -> TransformCubeDefinition {
        var cubeData = [Float](repeating: 0, count: dimension * dimension * dimension * 4)

        for b in 0..<dimension {
            let blue = Double(b) / Double(dimension - 1)
            for g in 0..<dimension {
                let green = Double(g) / Double(dimension - 1)
                for r in 0..<dimension {
                    let red = Double(r) / Double(dimension - 1)
                    let mapped = mapping(red, green, blue)
                    let offset = ((b * dimension * dimension) + (g * dimension) + r) * 4
                    cubeData[offset + 0] = Float(mapped.x)
                    cubeData[offset + 1] = Float(mapped.y)
                    cubeData[offset + 2] = Float(mapped.z)
                    cubeData[offset + 3] = 1.0
                }
            }
        }

        return TransformCubeDefinition(
            dimension: dimension,
            data: cubeData.withUnsafeBufferPointer { Data(buffer: $0) }
        )
    }
}

@inline(__always)
nonisolated private func applyTransformCube(
    _ cube: TransformCubeDefinition,
    to image: CIImage
) -> CIImage? {
    guard let filter = CIFilter(name: "CIColorCube") else {
        return nil
    }

    filter.setValue(image, forKey: kCIInputImageKey)
    filter.setValue(cube.dimension, forKey: "inputCubeDimension")
    filter.setValue(cube.data, forKey: "inputCubeData")
    filter.setValue(true, forKey: "inputExtrapolate")
    return filter.outputImage
}

nonisolated struct InputTransform {
    let source: SignalSpace
    let destinationWorkingSpace: SignalSpace
    
    // Converts an image from `source` into `destinationWorkingSpace`
    func process(_ image: CIImage) -> CIImage? {
        if source == destinationWorkingSpace {
            return image
        }

        if let sourceDef = source.definition,
           let destDef = destinationWorkingSpace.definition,
           let cube = TransformCubeCache.shared.cube(from: sourceDef, to: destDef) {
            return applyTransformCube(cube, to: image)
        }

        if (source == .linearSRGB || source == .acescg),
           let cgDest = destinationWorkingSpace.cgColorSpace {
            return image.matchedFromWorkingSpace(to: cgDest)
        }

        return nil
    }
}

nonisolated struct OutputTransform {
    let sourceWorkingSpace: SignalSpace
    let destination: SignalSpace
    
    // Converts from working space to output display space
    func process(_ image: CIImage) -> CIImage? {
        if sourceWorkingSpace == destination {
            return image
        }

        if let sourceDef = sourceWorkingSpace.definition,
           let destDef = destination.definition,
           let cube = TransformCubeCache.shared.cube(from: sourceDef, to: destDef) {
            return applyTransformCube(cube, to: image)
        }

        guard let destCG = destination.cgColorSpace else {
            return image
        }

        return image.matchedFromWorkingSpace(to: destCG)
    }
}
