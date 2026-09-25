import Foundation

protocol CaptureStoring: Sendable {
    func list() async throws -> [LibraryItem]
    func save(_ payload: PhotoPayload, recipe: EditRecipe, location: GeoTag?, needsPhotosSave: Bool) async throws -> LibraryItem
    func source(for item: LibraryItem) async throws -> Data
    func update(_ item: LibraryItem) async throws
}

/// One directory per capture. The original is committed before publishing a record.
/// An interrupted write leaves an unpublished directory, never a partially readable record.
actor CaptureStore: CaptureStoring {
    let root: URL
    private let files = FileManager.default

    init(root: URL) { self.root = root }

    static func applicationRoot() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Captures", isDirectory: true)
    }

    func list() throws -> [LibraryItem] {
        try Diagnostics.time("store.list") { try listUnmeasured() }
    }
    private func listUnmeasured() throws -> [LibraryItem] {
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        let directories = try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        var items: [LibraryItem] = []
        for directory in directories where UUID(uuidString: directory.lastPathComponent) != nil {
            let record = directory.appendingPathComponent("record.json")
            guard files.fileExists(atPath: record.path) else { continue }
            do {
                let item = try JSONDecoder().decode(LibraryItem.self, from: Data(contentsOf: record))
                guard item.id.uuidString == directory.lastPathComponent,
                      ["jpg", "heic", "png", "mov", "mp4"].contains(item.sourceExtension) else {
                    throw AppIssue("Invalid capture record", "A capture record needs recovery.")
                }
                items.append(item)
            } catch {
                // Report the failure; never overwrite or delete a corrupt original.
                Diagnostics.report(error, operation: "Read capture record")
                throw AppIssue("Library needs attention", "A capture record couldn’t be read. Your files are still stored on this device. Export a diagnostic report from Settings.")
            }
        }
        return items.sorted { $0.createdAt > $1.createdAt }
    }

    func save(_ payload: PhotoPayload, recipe: EditRecipe, location: GeoTag?, needsPhotosSave: Bool) throws -> LibraryItem {
        var item = LibraryItem(id: UUID(), createdAt: Date(), kind: .photo,
                               sourceExtension: Self.imageExtension(payload.processed), hasRAW: payload.raw != nil,
                               hasLiveMovie: payload.liveMovieURL != nil, recipe: recipe.validated, location: location)
        item.needsPhotosSave = needsPhotosSave
        try Diagnostics.time("store.save (\(payload.processed.count / 1024)KB)") {
            let directory = folder(item)
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            try Diagnostics.time("store.writeOriginal") { try payload.processed.write(to: sourceURL(item), options: [.atomic, .completeFileProtectionUnlessOpen]) }
            if let raw = payload.raw {
                try Diagnostics.time("store.writeRAW (\(raw.count / 1024)KB)") { try raw.write(to: directory.appendingPathComponent("original.dng"), options: [.atomic, .completeFileProtectionUnlessOpen]) }
            }
            if let movie = payload.liveMovieURL {
                try Diagnostics.time("store.copyLiveMovie") { try files.copyItem(at: movie, to: directory.appendingPathComponent("live.mov")) }
            }
            try update(item)
        }
        return item
    }

    func saveVideo(from url: URL, location: GeoTag?, needsPhotosSave: Bool) throws -> LibraryItem {
        var item = LibraryItem(id: UUID(), createdAt: Date(), kind: .video, sourceExtension: "mov", hasRAW: false,
                               hasLiveMovie: false, recipe: EditRecipe(), location: location)
        item.needsPhotosSave = needsPhotosSave
        try files.createDirectory(at: folder(item), withIntermediateDirectories: true)
        try files.copyItem(at: url, to: sourceURL(item))
        try update(item)
        return item
    }

    func source(for item: LibraryItem) throws -> Data {
        try Diagnostics.time("store.readSource") { try Data(contentsOf: sourceURL(item), options: .mappedIfSafe) }
    }
    func sourceURL(_ item: LibraryItem) -> URL { folder(item).appendingPathComponent("original.\(item.sourceExtension)") }
    func rawURL(_ item: LibraryItem) -> URL? { item.hasRAW ? folder(item).appendingPathComponent("original.dng") : nil }
    func liveURL(_ item: LibraryItem) -> URL? { item.hasLiveMovie ? folder(item).appendingPathComponent("live.mov") : nil }
    func thumbnail(_ item: LibraryItem) throws -> Data? {
        let url = folder(item).appendingPathComponent("thumbnail-\(item.revision).jpg")
        return files.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
    }
    func saveThumbnail(_ data: Data, for item: LibraryItem) throws {
        try data.write(to: folder(item).appendingPathComponent("thumbnail-\(item.revision).jpg"), options: .atomic)
    }
    func update(_ item: LibraryItem) throws {
        try Diagnostics.time("store.writeRecord") {
            try JSONEncoder().encode(item).write(to: folder(item).appendingPathComponent("record.json"), options: [.atomic, .completeFileProtectionUnlessOpen])
        }
    }
    func delete(_ item: LibraryItem) throws {
        try Diagnostics.time("store.delete") { try files.removeItem(at: folder(item)) }
    }
    private func folder(_ item: LibraryItem) -> URL { root.appendingPathComponent(item.id.uuidString, isDirectory: true) }

    static func imageExtension(_ data: Data) -> String {
        if data.starts(with: [0x89, 0x50, 0x4e, 0x47]) { return "png" }
        if data.starts(with: [0xff, 0xd8]) { return "jpg" }
        return "heic"
    }
}
