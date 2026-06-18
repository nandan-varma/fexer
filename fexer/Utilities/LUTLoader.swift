import Foundation

final class LUTLoader {
    static let shared = LUTLoader()

    private final class LUTEntry: NSObject {
        let data: NSData
        let dimension: Int
        init(_ data: NSData, _ dimension: Int) { self.data = data; self.dimension = dimension }
    }

    private let cache = NSCache<NSString, LUTEntry>()

    private init() {
        cache.countLimit = 10
    }

    /// Returns RGBA Float32 data suitable for CIColorCubeWithColorSpace, plus cube dimension.
    func load(filename: String) -> (data: NSData, dimension: Int)? {
        let key = filename as NSString
        if let entry = cache.object(forKey: key) {
            return (entry.data, entry.dimension)
        }

        guard let url = Bundle.main.url(forResource: (filename as NSString).deletingPathExtension,
                                         withExtension: "cube") ?? Bundle.main.url(forResource: filename, withExtension: nil),
              let content = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }

        guard let (data, dim) = parseCube(content: content) else { return nil }

        cache.setObject(LUTEntry(data as NSData, dim), forKey: key)
        return (data as NSData, dim)
    }

    private func parseCube(content: String) -> (Data, Int)? {
        var dimension = 33
        var floats: [Float32] = []
        floats.reserveCapacity(33 * 33 * 33 * 4)

        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") || trimmed.isEmpty { continue }

            if trimmed.uppercased().hasPrefix("LUT_3D_SIZE") {
                let parts = trimmed.components(separatedBy: .whitespaces)
                if let n = parts.last.flatMap(Int.init) { dimension = n }
                continue
            }

            if trimmed.uppercased().hasPrefix("DOMAIN_MIN") ||
               trimmed.uppercased().hasPrefix("DOMAIN_MAX") ||
               trimmed.uppercased().hasPrefix("TITLE") { continue }

            let parts = trimmed.components(separatedBy: .whitespaces).compactMap(Float32.init)
            guard parts.count >= 3 else { continue }
            floats.append(parts[0])
            floats.append(parts[1])
            floats.append(parts[2])
            floats.append(1.0) // A channel required by CIColorCubeWithColorSpace
        }

        let expected = dimension * dimension * dimension * 4
        guard floats.count == expected else { return nil }

        return (Data(bytes: floats, count: floats.count * MemoryLayout<Float32>.size), dimension)
    }
}
