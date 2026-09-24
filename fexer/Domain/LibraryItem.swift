import Foundation

struct GeoTag: Codable, Hashable, Sendable {
    let latitude: Double
    let longitude: Double
    let altitude: Double?
}

struct LibraryItem: Codable, Hashable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable { case photo, video }
    var id: UUID
    var createdAt: Date
    var kind: Kind
    var sourceExtension: String
    var hasRAW: Bool
    var hasLiveMovie: Bool
    var recipe: EditRecipe
    var location: GeoTag?
    var favorite: Bool = false
    var photosIdentifier: String?
    var exportedRecipe: EditRecipe?
    var needsPhotosSave: Bool = true
    var revision: Int = 0
}
