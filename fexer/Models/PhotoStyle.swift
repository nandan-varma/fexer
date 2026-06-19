import Foundation

enum StyleCategory: String, CaseIterable, Identifiable {
    case film = "Film"
    case genre = "Genre"
    case mood = "Mood"
    case custom = "Custom"
    var id: String { rawValue }
}

struct PhotoStyle: Identifiable, Hashable {
    let id: UUID
    let name: String
    let category: StyleCategory
    let lutFileName: String?
    let baseIntensity: Float
    let description: String

    static func == (lhs: PhotoStyle, rhs: PhotoStyle) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    static let none = PhotoStyle(
        id: UUID(uuidString: Self.noneUUID) ?? UUID(),
        name: "None",
        category: .custom,
        lutFileName: nil,
        baseIntensity: 1.0,
        description: "No style applied"
    )

    private static let noneUUID = "00000000-0000-0000-0000-000000000000"

    static let catalog: [PhotoStyle] = [
        // Film
        PhotoStyle(id: UUID(), name: "Portra 400", category: .film, lutFileName: "kodak_portra_400.cube", baseIntensity: 0.85, description: "Warm skin tones, subtle grain"),
        PhotoStyle(id: UUID(), name: "Tri-X BW", category: .film, lutFileName: "kodak_trix_400.cube", baseIntensity: 1.0, description: "Classic high-contrast black & white"),
        PhotoStyle(id: UUID(), name: "Velvia 50", category: .film, lutFileName: "fuji_velvia_50.cube", baseIntensity: 0.9, description: "Vivid saturated colors, deep shadows"),
        PhotoStyle(id: UUID(), name: "Provia 100", category: .film, lutFileName: "fuji_provia_100.cube", baseIntensity: 0.85, description: "Natural balanced daylight film"),
        PhotoStyle(id: UUID(), name: "HP5 BW", category: .film, lutFileName: "ilford_hp5_bw.cube", baseIntensity: 1.0, description: "Smooth gradients, versatile BW"),
        PhotoStyle(id: UUID(), name: "Gold 200", category: .film, lutFileName: "kodak_gold_200.cube", baseIntensity: 0.8, description: "Warm golden hues, consumer film look"),
        PhotoStyle(id: UUID(), name: "Agfa Vista", category: .film, lutFileName: "agfa_vista_200.cube", baseIntensity: 0.85, description: "Punchy greens, elevated shadows"),
        // Genre
        PhotoStyle(id: UUID(), name: "Street", category: .genre, lutFileName: "street_punch.cube", baseIntensity: 0.9, description: "Contrasty, gritty urban look"),
        PhotoStyle(id: UUID(), name: "Portrait Warm", category: .genre, lutFileName: "portrait_warm.cube", baseIntensity: 0.75, description: "Flattering warm skin, soft highlights"),
        PhotoStyle(id: UUID(), name: "Landscape", category: .genre, lutFileName: "landscape_vivid.cube", baseIntensity: 0.85, description: "Rich greens, deep blues"),
        PhotoStyle(id: UUID(), name: "Astro", category: .genre, lutFileName: "astro_dark.cube", baseIntensity: 1.0, description: "Dark shadows, preserved highlights for night sky"),
        PhotoStyle(id: UUID(), name: "Golden Hour", category: .genre, lutFileName: "golden_hour.cube", baseIntensity: 0.9, description: "Warm amber tones of magic hour"),
        PhotoStyle(id: UUID(), name: "Macro", category: .genre, lutFileName: "macro_soft.cube", baseIntensity: 0.8, description: "Soft, delicate tones for close-ups"),
        PhotoStyle(id: UUID(), name: "Architecture", category: .genre, lutFileName: "architecture_cool.cube", baseIntensity: 0.85, description: "Cool shadows, clean lines"),
        // Mood
        PhotoStyle(id: UUID(), name: "Cinematic", category: .mood, lutFileName: "cinematic_teal_orange.cube", baseIntensity: 0.85, description: "Hollywood teal-orange grade"),
        PhotoStyle(id: UUID(), name: "Faded Matte", category: .mood, lutFileName: "faded_matte.cube", baseIntensity: 0.9, description: "Lifted blacks, desaturated matte"),
        PhotoStyle(id: UUID(), name: "Punchy", category: .mood, lutFileName: "punchy_contrast.cube", baseIntensity: 0.85, description: "High contrast, vivid pop"),
        PhotoStyle(id: UUID(), name: "Dreamy", category: .mood, lutFileName: "dreamy_soft.cube", baseIntensity: 0.8, description: "Soft, hazy, pastel tones"),
        PhotoStyle(id: UUID(), name: "Noir BW", category: .mood, lutFileName: "noir_bw.cube", baseIntensity: 1.0, description: "Deep shadows, graphic high contrast"),
        PhotoStyle(id: UUID(), name: "Warm Fade", category: .mood, lutFileName: "warm_fade.cube", baseIntensity: 0.85, description: "Warm lifted shadows, vintage feel"),
        PhotoStyle(id: UUID(), name: "Cool Mist", category: .mood, lutFileName: "cool_mist.cube", baseIntensity: 0.8, description: "Desaturated cool tones, misty atmosphere"),
    ]
}
