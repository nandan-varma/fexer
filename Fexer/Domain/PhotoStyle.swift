import Foundation

struct PhotoStyle: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let category: Category
    let detail: String
    let file: String?

    enum Category: String, CaseIterable, Identifiable, Sendable {
        case essentials = "Essentials", film = "Film", atmosphere = "Atmosphere"
        var id: Self { self }
    }

    static let original = PhotoStyle(id: "original", name: "Original", category: .essentials, detail: "Just the way you saw it.", file: nil)
    static let all: [PhotoStyle] = [
        original,
        .init(id: "portra", name: "Portra 400", category: .film, detail: "Soft contrast. Warm, natural skin tones.", file: "kodak_portra_400"),
        .init(id: "gold", name: "Gold 200", category: .film, detail: "Golden light with a little nostalgia.", file: "kodak_gold_200"),
        .init(id: "trix", name: "Tri-X", category: .film, detail: "Bold, timeless black and white.", file: "kodak_trix_400"),
        .init(id: "velvia", name: "Velvia 50", category: .film, detail: "Rich color and deep shadows.", file: "fuji_velvia_50"),
        .init(id: "provia", name: "Provia 100", category: .film, detail: "Balanced daylight and honest color.", file: "fuji_provia_100"),
        .init(id: "hp5", name: "HP5", category: .film, detail: "Gentle monochrome with open shadows.", file: "ilford_hp5_bw"),
        .init(id: "vista", name: "Vista", category: .film, detail: "Lively greens and lifted blacks.", file: "agfa_vista_200"),
        .init(id: "street", name: "Street", category: .essentials, detail: "Crisp contrast for everyday stories.", file: "street_punch"),
        .init(id: "portrait", name: "Portrait", category: .essentials, detail: "Flattering warmth and soft highlights.", file: "portrait_warm"),
        .init(id: "landscape", name: "Landscape", category: .essentials, detail: "Deep blues and vibrant greens.", file: "landscape_vivid"),
        .init(id: "astro", name: "After dark", category: .essentials, detail: "Cool shadows, luminous highlights.", file: "astro_dark"),
        .init(id: "golden", name: "Golden hour", category: .essentials, detail: "The warmth of the last light.", file: "golden_hour"),
        .init(id: "macro", name: "Macro", category: .essentials, detail: "Quiet color for the little things.", file: "macro_soft"),
        .init(id: "architecture", name: "Architecture", category: .essentials, detail: "Clean lines and cooler tones.", file: "architecture_cool"),
        .init(id: "cinema", name: "Cinema", category: .atmosphere, detail: "Cool shadows meet warm highlights.", file: "cinematic_teal_orange"),
        .init(id: "matte", name: "Matte", category: .atmosphere, detail: "Muted color with lifted blacks.", file: "faded_matte"),
        .init(id: "punch", name: "Punch", category: .atmosphere, detail: "Bright color with extra presence.", file: "punchy_contrast"),
        .init(id: "dream", name: "Dream", category: .atmosphere, detail: "Airy pastels and gentle contrast.", file: "dreamy_soft"),
        .init(id: "noir", name: "Noir", category: .atmosphere, detail: "Graphic monochrome, deep blacks.", file: "noir_bw"),
        .init(id: "warm", name: "Warm fade", category: .atmosphere, detail: "Soft amber and faded shadows.", file: "warm_fade"),
        .init(id: "mist", name: "Cool mist", category: .atmosphere, detail: "A quiet, cool palette.", file: "cool_mist")
    ]
    static func find(_ id: String) -> PhotoStyle { all.first { $0.id == id } ?? original }
}
