import Testing
import Foundation
@testable import Fexer

struct LibraryItemTests {
    @Test func roundTripsThroughJSONIncludingLocation() throws {
        let item = LibraryItem(id: UUID(), createdAt: Date(), kind: .photo, sourceExtension: "heic",
                               hasRAW: true, hasLiveMovie: false, recipe: EditRecipe(),
                               location: GeoTag(latitude: 51.5, longitude: -0.1, altitude: 12),
                               favorite: true, photosIdentifier: "abc", exportedRecipe: nil,
                               needsPhotosSave: false, revision: 3)
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(LibraryItem.self, from: data)
        #expect(decoded == item)
    }

    @Test func defaultsFavoriteToFalseAndNeedsPhotosSaveToTrue() {
        let item = LibraryItem(id: UUID(), createdAt: Date(), kind: .video, sourceExtension: "mov",
                               hasRAW: false, hasLiveMovie: false, recipe: EditRecipe(), location: nil)
        #expect(item.favorite == false)
        #expect(item.needsPhotosSave == true)
        #expect(item.revision == 0)
    }
}
