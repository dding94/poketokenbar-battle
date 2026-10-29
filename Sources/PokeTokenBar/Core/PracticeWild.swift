import Foundation

/// Where a practice candidate comes from. Wild opponents exist only in memory and never touch the save.
enum PracticeOrigin: Equatable, Sendable {
    case owned
    case wild(rarity: Rarity, shiny: Bool)
}

/// Level and evolution stage of a wild practice opponent, mirroring how the app grows its own Pokémon.
enum PracticeWildRules {
    /// The player's level ±3 (uniform from `roll`), kept within the app's 5...100.
    static func level(around playerLevel: Int, roll: UInt64) -> Int { playerLevel }
    /// The 0-based stage a line of `totalForms` stages has reached at `level`. It inverts the app's own
    /// growth (`PokemonProfile.advanceGrowth` for level, `PokemonBalance.phaseThreshold` for stages), so a
    /// wild Lv.50 sits at the stage the app's own Pokémon would have at Lv.50.
    static func stageIndex(level: Int, totalForms: Int) -> Int { 0 }
}

/// PokéAPI access for wild opponents. Tests inject stubs so nothing reaches the network.
struct PracticeWildSource: Sendable {
    let provider: any PokeProviding
    let details: any PokemonDetailProviding
    static var live: PracticeWildSource { PracticeWildSource(provider: PokeAPIClient.shared, details: PokeAPIClient.shared) }
}

/// Builds wild practice opponents with the app's hatch rule: species by `HatchRule` (nothing counts as
/// collected), stage by `PracticeWildRules`, form, shiny, nature and profile by the same functions the app
/// uses for its own eggs (`PokemonProfile.generate` then `enrich` at the chosen level). In memory only.
@MainActor
struct PracticeWildGenerator {
    let source: PracticeWildSource
    let engine: BattleEngine

    /// Up to `count` candidates within ±3 levels of `playerLevel`, the same for the same `seed`. Species whose
    /// line or details cannot be loaded are skipped (offline, PokéAPI's disk cache still serves details).
    /// Throws when not a single candidate could be made.
    func make(count: Int, around playerLevel: Int, seed: UInt64) async throws -> [PracticeCandidate] { [] }
}

/// The wild-opponent search shown on the selection screen.
enum PracticeWildState: Equatable, Sendable {
    case idle, searching, ready
    /// Localized reason (e.g. offline with nothing cached).
    case unavailable(String)
}
