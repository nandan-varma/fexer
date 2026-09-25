import Testing
import Foundation
@testable import Fexer

struct CaptureStoreTests {
    private func makeStore() -> CaptureStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fexer-tests-\(UUID().uuidString)")
        return CaptureStore(root: root)
    }

    @Test func savingAPhotoMakesItListable() async throws {
        let store = makeStore()
        let payload = PhotoPayload(processed: Data([0xFF, 0xD8, 0xFF]))
        let saved = try await store.save(payload, recipe: EditRecipe(), location: nil, needsPhotosSave: true)
        let listed = try await store.list()
        #expect(listed.map(\.id) == [saved.id])
        #expect(listed[0].sourceExtension == "jpg")
    }

    @Test func sourceDataRoundTrips() async throws {
        let store = makeStore()
        let bytes = Data([0xFF, 0xD8, 0xFF, 0x01, 0x02])
        let saved = try await store.save(PhotoPayload(processed: bytes), recipe: EditRecipe(), location: nil, needsPhotosSave: true)
        let read = try await store.source(for: saved)
        #expect(read == bytes)
    }

    @Test func updatePersistsChangesAcrossLoads() async throws {
        let store = makeStore()
        var item = try await store.save(PhotoPayload(processed: Data([0x89, 0x50, 0x4e, 0x47])), recipe: EditRecipe(), location: nil, needsPhotosSave: true)
        item.favorite = true
        item.revision = 1
        try await store.update(item)
        let listed = try await store.list()
        #expect(listed.first?.favorite == true)
        #expect(listed.first?.revision == 1)
    }

    @Test func deleteRemovesTheCapture() async throws {
        let store = makeStore()
        let saved = try await store.save(PhotoPayload(processed: Data([0xFF, 0xD8])), recipe: EditRecipe(), location: nil, needsPhotosSave: true)
        try await store.delete(saved)
        let listed = try await store.list()
        #expect(listed.isEmpty)
    }

    @Test func newestCapturesListFirst() async throws {
        let store = makeStore()
        let first = try await store.save(PhotoPayload(processed: Data([0xFF, 0xD8])), recipe: EditRecipe(), location: nil, needsPhotosSave: true)
        try await Task.sleep(for: .milliseconds(10))
        let second = try await store.save(PhotoPayload(processed: Data([0xFF, 0xD8])), recipe: EditRecipe(), location: nil, needsPhotosSave: true)
        let listed = try await store.list()
        #expect(listed.map(\.id) == [second.id, first.id])
    }

    @Test func imageExtensionDetectsCommonFormats() {
        #expect(CaptureStore.imageExtension(Data([0xFF, 0xD8, 0xFF])) == "jpg")
        #expect(CaptureStore.imageExtension(Data([0x89, 0x50, 0x4e, 0x47])) == "png")
        #expect(CaptureStore.imageExtension(Data([0x00, 0x01, 0x02])) == "heic")
    }
}
