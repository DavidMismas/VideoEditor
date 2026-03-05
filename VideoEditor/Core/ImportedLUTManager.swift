import Foundation
import CoreImage

nonisolated final class ImportedLUTManager {
    static let shared = ImportedLUTManager()
    
    private struct CubeDefinition {
        let dimension: Int
        let data: Data
        let domainMin: (r: Double, g: Double, b: Double)
        let domainMax: (r: Double, g: Double, b: Double)
    }
    
    private let cacheQueue = DispatchQueue(label: "ImportedLUTManager.cacheQueue")
    private var cache: [URL: CubeDefinition] = [:]
    
    private init() {}
    
    func hasValidCube(at url: URL) -> Bool {
        cubeDefinition(for: url) != nil
    }
    
    func makeFilter(for url: URL) -> CIFilter? {
        guard let cube = cubeDefinition(for: url) else { return nil }
        
        let filter = CIFilter(name: "CIColorCube")
        filter?.setValue(cube.dimension, forKey: "inputCubeDimension")
        filter?.setValue(cube.data, forKey: "inputCubeData")
        filter?.setValue(true, forKey: "inputExtrapolate")
        return filter
    }
    
    func applyCube(at url: URL, to image: CIImage) -> CIImage? {
        guard let cube = cubeDefinition(for: url),
              let filter = makeFilter(for: url) else {
            return nil
        }
        
        var lutInput = image
        lutInput = applyDomainRemapIfNeeded(cube, to: lutInput)
        
        // Most camera LUTs are authored in display/gamma domain, while video compositor
        // commonly runs in a linear working space. Convert around LUT for expected response.
        lutInput = lutInput.applyingFilter("CILinearToSRGBToneCurve")
        
        filter.setValue(lutInput, forKey: kCIInputImageKey)
        guard let lutOut = filter.outputImage else { return nil }
        
        return lutOut.applyingFilter("CISRGBToneCurveToLinear")
    }
    
    private func cubeDefinition(for url: URL) -> CubeDefinition? {
        let normalizedURL = url.standardizedFileURL
        
        if let cached = cacheQueue.sync(execute: { cache[normalizedURL] }) {
            return cached
        }
        
        guard let parsed = parseCubeFile(at: normalizedURL) else {
            return nil
        }
        
        cacheQueue.sync {
            cache[normalizedURL] = parsed
        }
        return parsed
    }
    
    private func parseCubeFile(at url: URL) -> CubeDefinition? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        
        var dimension: Int?
        var domainMin = (r: 0.0, g: 0.0, b: 0.0)
        var domainMax = (r: 1.0, g: 1.0, b: 1.0)
        var entries: [(Double, Double, Double)] = []
        
        let lines = text.components(separatedBy: .newlines)
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            
            let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard !parts.isEmpty else { continue }
            
            switch parts[0].uppercased() {
            case "TITLE":
                continue
            case "LUT_3D_SIZE":
                guard parts.count >= 2, let size = Int(parts[1]), size > 1 else { return nil }
                dimension = size
            case "DOMAIN_MIN":
                guard parts.count >= 4,
                      let r = Double(parts[1]),
                      let g = Double(parts[2]),
                      let b = Double(parts[3]) else { return nil }
                domainMin = (r, g, b)
            case "DOMAIN_MAX":
                guard parts.count >= 4,
                      let r = Double(parts[1]),
                      let g = Double(parts[2]),
                      let b = Double(parts[3]) else { return nil }
                domainMax = (r, g, b)
            case "LUT_1D_SIZE":
                // Not supported for clip transform in this app.
                continue
            default:
                guard parts.count >= 3,
                      let r = Double(parts[0]),
                      let g = Double(parts[1]),
                      let b = Double(parts[2]) else { continue }
                entries.append((r, g, b))
            }
        }
        
        guard let size = dimension else { return nil }
        let expectedCount = size * size * size
        guard entries.count >= expectedCount else { return nil }
        
        var cube = [Float](repeating: 0, count: expectedCount * 4)
        for idx in 0..<expectedCount {
            let entry = entries[idx]
            let offset = idx * 4
            cube[offset + 0] = Float(entry.0)
            cube[offset + 1] = Float(entry.1)
            cube[offset + 2] = Float(entry.2)
            cube[offset + 3] = 1.0
        }
        
        return CubeDefinition(
            dimension: size,
            data: cube.withUnsafeBufferPointer { Data(buffer: $0) },
            domainMin: domainMin,
            domainMax: domainMax
        )
    }
    
    private func applyDomainRemapIfNeeded(_ cube: CubeDefinition, to image: CIImage) -> CIImage {
        let minDomain = cube.domainMin
        let maxDomain = cube.domainMax
        
        let defaultDomain = abs(minDomain.r) < 0.000001 &&
            abs(minDomain.g) < 0.000001 &&
            abs(minDomain.b) < 0.000001 &&
            abs(maxDomain.r - 1.0) < 0.000001 &&
            abs(maxDomain.g - 1.0) < 0.000001 &&
            abs(maxDomain.b - 1.0) < 0.000001
        guard !defaultDomain else { return image }
        
        let rangeR = max(maxDomain.r - minDomain.r, 0.000001)
        let rangeG = max(maxDomain.g - minDomain.g, 0.000001)
        let rangeB = max(maxDomain.b - minDomain.b, 0.000001)
        
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1.0 / rangeR, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 1.0 / rangeG, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 1.0 / rangeB, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(
                x: -minDomain.r / rangeR,
                y: -minDomain.g / rangeG,
                z: -minDomain.b / rangeB,
                w: 0
            )
        ])
    }
}
