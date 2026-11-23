nonisolated enum FilmExpiration: String, CaseIterable {
    case off, random

    static let preferenceKey = "filmExpiration"

    func ageForLoadedStock() -> Int {
        switch self {
        case .off: 0
        case .random: Self.age(forRoll: Int.random(in: 0..<100))
        }
    }

    static func age(forRoll roll: Int) -> Int {
        precondition((0..<100).contains(roll))
        switch roll {
        case ..<25: return 0
        case ..<48: return 5
        case ..<67: return 10
        case ..<82: return 15
        case ..<93: return 20
        default: return 30
        }
    }
}
