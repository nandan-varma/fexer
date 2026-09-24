import Foundation

struct CubeLUT: Codable, Hashable, Sendable {
    let dimension: Int
    let rgba: Data

    enum ParseError: Error, Equatable { case tooLarge, missingSize, invalidSize, unsupportedDomain, malformedLine(Int), wrongCount }

    /// Strict parsing bounds allocation and rejects NaN, infinity, malformed entries and unsupported domains.
    static func parse(_ text: String) throws -> CubeLUT {
        guard text.utf8.count <= 16_000_000 else { throw ParseError.tooLarge }
        var dimension: Int?
        var values: [Float] = []
        for (lineNumber, raw) in text.split(whereSeparator: \.isNewline).enumerated() {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard let first = parts.first else { continue }
            switch first.uppercased() {
            case "TITLE": continue
            case "LUT_3D_SIZE":
                guard dimension == nil, parts.count == 2, let size = Int(parts[1]), (2...64).contains(size) else {
                    throw ParseError.invalidSize
                }
                dimension = size
                values.reserveCapacity(size * size * size * 4)
            case "DOMAIN_MIN", "DOMAIN_MAX":
                let expected: Float = first.uppercased() == "DOMAIN_MIN" ? 0 : 1
                guard parts.count == 4, parts.dropFirst().allSatisfy({ Float($0) == expected }) else {
                    throw ParseError.unsupportedDomain
                }
            default:
                guard let size = dimension else { throw ParseError.missingSize }
                guard values.count < size * size * size * 4 else { throw ParseError.wrongCount }
                let row = parts.compactMap { Float($0) }
                guard row.count == 3, parts.count == 3, row.allSatisfy(\.isFinite) else {
                    throw ParseError.malformedLine(lineNumber + 1)
                }
                values.append(contentsOf: row)
                values.append(1)
            }
        }
        guard let dimension else { throw ParseError.missingSize }
        guard values.count == dimension * dimension * dimension * 4 else { throw ParseError.wrongCount }
        return CubeLUT(dimension: dimension, rgba: values.withUnsafeBytes { Data($0) })
    }

    var isValid: Bool {
        (2...64).contains(dimension) && rgba.count == dimension * dimension * dimension * 4 * MemoryLayout<Float>.size
    }
}
