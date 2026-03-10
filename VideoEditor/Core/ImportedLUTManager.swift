import Foundation
import CoreImage

nonisolated final class ImportedLUTManager {
    static let shared = ImportedLUTManager()
    
    private struct CubeDefinition {
        let dimension: Int
        let data: Data
        let domainMin: (r: Double, g: Double, b: Double)
        let domainMax: (r: Double, g: Double, b: Double)
        let descriptor: ImportedLUTDescriptor
    }

    private struct SignalSpaceAlias {
        let space: SignalSpace
        let alias: String
    }

    private struct SignalSpaceMatch {
        let space: SignalSpace
        let location: Int
        let length: Int
    }
    
    private let cacheQueue = DispatchQueue(label: "ImportedLUTManager.cacheQueue")
    private var cache: [URL: CubeDefinition] = [:]
    
    private init() {}
    
    func hasValidCube(at url: URL) -> Bool {
        cubeDefinition(for: url) != nil
    }
    
    func descriptor(for url: URL) -> ImportedLUTDescriptor {
        _ = url
        return .creative(lutSpace: .rec709)
    }

    func makeFilter(for url: URL) -> CIFilter? {
        guard let cube = cubeDefinition(for: url) else { return nil }
        
        let filter = CIFilter(name: "CIColorCube")
        filter?.setValue(cube.dimension, forKey: "inputCubeDimension")
        filter?.setValue(cube.data, forKey: "inputCubeData")
        filter?.setValue(true, forKey: "inputExtrapolate")
        return filter
    }
    
    func applyCube(
        at url: URL,
        to image: CIImage
    ) -> CIImage? {
        guard let cube = cubeDefinition(for: url),
              let filter = makeFilter(for: url) else {
            return nil
        }
        
        var lutInput = image
        lutInput = applyDomainRemapIfNeeded(cube, to: lutInput)

        filter.setValue(lutInput, forKey: kCIInputImageKey)
        return filter.outputImage
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
        var title: String?
        
        let lines = text.components(separatedBy: .newlines)
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            
            let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard !parts.isEmpty else { continue }
            
            switch parts[0].uppercased() {
            case "TITLE":
                title = raw
                    .dropFirst(parts[0].count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
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
            // .cube data is serialized with R varying fastest, then G, then B,
            // which matches CIColorCube's required memory layout.
            cube[offset + 0] = Float(entry.0)
            cube[offset + 1] = Float(entry.1)
            cube[offset + 2] = Float(entry.2)
            cube[offset + 3] = 1.0
        }
        
        return CubeDefinition(
            dimension: size,
            data: cube.withUnsafeBufferPointer { Data(buffer: $0) },
            domainMin: domainMin,
            domainMax: domainMax,
            descriptor: inferDescriptor(for: url, title: title)
        )
    }

    private func inferDescriptor(for url: URL, title: String?) -> ImportedLUTDescriptor {
        _ = url
        _ = title
        return .creative(lutSpace: .rec709)
    }

    private func technicalDescriptor(from normalized: String) -> ImportedLUTDescriptor? {
        let padded = " \(normalized) "
        let separators = [" to ", " into ", " -> ", " 2 "]

        for separator in separators {
            let components = padded.components(separatedBy: separator)
            guard components.count >= 2 else { continue }

            let inputCandidate = components[0]
            let outputCandidate = components[1...].joined(separator: separator)

            guard let inputSpace = signalSpace(in: inputCandidate),
                  let outputSpace = signalSpace(in: outputCandidate),
                  inputSpace != outputSpace else {
                continue
            }

            return .technical(input: inputSpace, output: outputSpace)
        }

        return nil
    }

    private func creativeDescriptor(from normalized: String) -> ImportedLUTDescriptor? {
        let orderedSpaces = orderedSignalSpaces(in: normalized)
        let distinctSpaces = orderedSpaces.reduce(into: [SignalSpace]()) { result, space in
            guard result.last != space else { return }
            result.append(space)
        }

        guard distinctSpaces.count == 1, let lutSpace = distinctSpaces.first else {
            return nil
        }

        return .creative(lutSpace: lutSpace)
    }

    private func normalizeDescriptorText(_ text: String) -> String {
        let lowered = text.lowercased()
        let replaced = lowered.map { character -> Character in
            switch character {
            case "_", "-", ".", "/", "\\", "(", ")", "[", "]", ">", ":":
                return " "
            default:
                return character
            }
        }

        return String(replaced)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private func orderedSignalSpaces(in text: String) -> [SignalSpace] {
        let aliases = signalSpaceAliases.sorted { lhs, rhs in
            if lhs.alias.count == rhs.alias.count {
                return lhs.alias < rhs.alias
            }
            return lhs.alias.count > rhs.alias.count
        }

        var matches: [SignalSpaceMatch] = []
        for alias in aliases {
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let range = text.range(of: alias.alias, range: searchStart..<text.endIndex) {
                let location = text.distance(from: text.startIndex, to: range.lowerBound)
                let length = text.distance(from: range.lowerBound, to: range.upperBound)
                matches.append(
                    SignalSpaceMatch(
                        space: alias.space,
                        location: location,
                        length: length
                    )
                )
                searchStart = range.upperBound
            }
        }

        matches.sort {
            if $0.location == $1.location {
                return $0.length > $1.length
            }
            return $0.location < $1.location
        }

        var filtered: [SignalSpaceMatch] = []
        var consumedUpperBound = -1
        for match in matches {
            guard match.location >= consumedUpperBound else { continue }
            filtered.append(match)
            consumedUpperBound = match.location + match.length
        }

        return filtered.map(\.space)
    }

    private func signalSpace(in text: String) -> SignalSpace? {
        let normalized = text.lowercased()

        for alias in signalSpaceAliases {
            if normalized.contains(alias.alias) {
                return alias.space
            }
        }

        return nil
    }

    private var signalSpaceAliases: [SignalSpaceAlias] {
        [
            SignalSpaceAlias(space: .appleLog2, alias: "apple log 2"),
            SignalSpaceAlias(space: .appleLog2, alias: "apple log2"),
            SignalSpaceAlias(space: .appleLog2, alias: "applelog2"),
            SignalSpaceAlias(space: .appleLog, alias: "apple log"),
            SignalSpaceAlias(space: .appleLog, alias: "applelog"),
            SignalSpaceAlias(space: .sonySLog3SGamut3Cine, alias: "sony s log3 sgamut3 cine"),
            SignalSpaceAlias(space: .sonySLog3SGamut3Cine, alias: "sony slog3 sgamut3 cine"),
            SignalSpaceAlias(space: .sonySLog3SGamut3Cine, alias: "s log3 sgamut3 cine"),
            SignalSpaceAlias(space: .sonySLog3SGamut3Cine, alias: "slog3 sgamut3 cine"),
            SignalSpaceAlias(space: .sonySLog3SGamut3Cine, alias: "s log3 sgamut3.cine"),
            SignalSpaceAlias(space: .sonySLog3SGamut3Cine, alias: "slog3 sgamut3.cine"),
            SignalSpaceAlias(space: .sonySLog3SGamut3Cine, alias: "sgamut3 cine"),
            SignalSpaceAlias(space: .sonySLog3SGamut3Cine, alias: "sgamut3cine"),
            SignalSpaceAlias(space: .linearSRGB, alias: "linear srgb"),
            SignalSpaceAlias(space: .linearSRGB, alias: "linearsrgb"),
            SignalSpaceAlias(space: .displayP3, alias: "display p3"),
            SignalSpaceAlias(space: .displayP3, alias: "displayp3"),
            SignalSpaceAlias(space: .displayP3, alias: "p3 d65"),
            SignalSpaceAlias(space: .displayP3, alias: "p3d65"),
            SignalSpaceAlias(space: .bt2020, alias: "bt 2020"),
            SignalSpaceAlias(space: .bt2020, alias: "bt2020"),
            SignalSpaceAlias(space: .bt2020, alias: "rec 2020"),
            SignalSpaceAlias(space: .bt2020, alias: "rec2020"),
            SignalSpaceAlias(space: .acescg, alias: "aces cg"),
            SignalSpaceAlias(space: .acescg, alias: "acescg"),
            SignalSpaceAlias(space: .rec709, alias: "rec 709"),
            SignalSpaceAlias(space: .rec709, alias: "rec709"),
            SignalSpaceAlias(space: .rec709, alias: "709")
        ]
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
