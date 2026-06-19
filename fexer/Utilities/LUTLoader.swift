import Foundation
import OSLog

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
                                          withExtension: "cube") ?? Bundle.main.url(forResource: filename, withExtension: nil)
        else {
            Logger.camera.error("LUT file not found: \(filename)")
            return nil
        }

        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            Logger.camera.error("Failed to read LUT file: \(url.path)")
            return nil
        }

        guard let (data, dim) = parseCube(content: content) else {
            Logger.camera.error("Failed to parse LUT file: \(filename)")
            return nil
        }

        cache.setObject(LUTEntry(data as NSData, dim), forKey: key)
        return (data as NSData, dim)
    }

    /// Generates LUT data from a mathematical (r,g,b)→(r,g,b) transform.
    /// Cached by name+dimension so generation only happens once per style.
    func generateProcedural(name: String,
                             dimension: Int = 17,
                             transform: (Float32, Float32, Float32) -> (Float32, Float32, Float32)) -> (NSData, Int) {
        let cacheKey = "__proc_\(name)_\(dimension)" as NSString
        if let entry = cache.object(forKey: cacheKey) { return (entry.data, entry.dimension) }

        let d = dimension
        var floats = [Float32](repeating: 0, count: d * d * d * 4)
        var idx = 0
        // .cube order: B outer, G middle, R inner
        for bi in 0..<d {
            for gi in 0..<d {
                for ri in 0..<d {
                    let (ro, go, bo) = transform(Float32(ri) / Float32(d - 1),
                                                 Float32(gi) / Float32(d - 1),
                                                 Float32(bi) / Float32(d - 1))
                    floats[idx]     = max(0, min(1, ro))
                    floats[idx + 1] = max(0, min(1, go))
                    floats[idx + 2] = max(0, min(1, bo))
                    floats[idx + 3] = 1.0
                    idx += 4
                }
            }
        }
        let data = floats.withUnsafeBytes { ptr -> NSData in
            guard let base = ptr.baseAddress else {
                Logger.camera.error("Failed to create procedural LUT data for \(name)")
                return NSData()
            }
            return NSData(bytes: base, length: ptr.count)
        }
        cache.setObject(LUTEntry(data, d), forKey: cacheKey)
        return (data, d)
    }

    /// Loads a .cube file if available; otherwise generates LUT data procedurally.
    /// This is the single entry point both the live pipeline and thumbnail renderer should use.
    func effectiveLUT(for style: PhotoStyle) -> (NSData, Int)? {
        if let fileName = style.lutFileName, let loaded = load(filename: fileName) {
            return loaded
        }
        // No .cube file — generate from parametric color science definition
        let p = StyleTransforms.params(for: style)
        return generateProcedural(name: style.name) { r, g, b in
            StyleTransforms.apply(p, r: r, g: g, b: b)
        }
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
