import Foundation

/// Where a practice candidate comes from. Wild opponents exist only in memory and never touch the save.
enum PracticeOrigin: Equatable, Sendable {
    case owned
    case wild(rarity: Rarity, shiny: Bool)
}

/// Level and evolution stage of a wild practice opponent, mirroring how the app grows its own Pokémon.
enum PracticeWildRules {
    /// The player's level ±3 (uniform from `roll`), kept within the app's 5...100.
    static func level(around playerLevel: Int, roll: UInt64) -> Int {
        min(100, max(5, playerLevel + Int(roll % 7) - 3))
    }
    /// The 0-based stage a line of `totalForms` stages has reached at `level`. It inverts the app's own
    /// growth (`PokemonProfile.advanceGrowth` for level, `PokemonBalance.phaseThreshold` for stages), so a
    /// wild Lv.50 sits at the stage the app's own Pokémon would have at Lv.50.
    ///
    /// Rule: the stage the app's Pokémon is in at the *lowest* growth that reaches `level` (a level spans many
    /// growth values, and the floor in `advanceGrowth` makes the lowest one the unambiguous choice). With
    /// graduation total T, level L is first reached at growth T * (L - 5) / 95, and stage `s` of a k-form line
    /// starts once the stages before it are paid: T * s(s+1) / (k(k+1)) (stage i costs T * i / (k(k+1)/2)).
    /// So the stage is the largest `s < k` with `95 * s * (s+1) <= (L - 5) * k * (k+1)`. The total T cancels,
    /// so the rule does not depend on rarity. A level reached exactly on a boundary counts as the later stage
    /// (the app evolves when the paid growth is met), and Lv.100 is the last stage (the app graduates from it).
    static func stageIndex(level: Int, totalForms: Int) -> Int {
        let forms = min(64, max(1, totalForms))
        let earned = min(100, max(5, level)) - 5
        var stage = 0
        for s in 1..<forms where 95 * s * (s + 1) <= earned * forms * (forms + 1) { stage = s }
        return stage
    }
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
    /// Time source for the search budget; tests inject a fake one (`PracticeSession` passes its own clock).
    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Seconds from the start of `make` after which no new attempt begins. Each request has its own timeout and
    /// failures are skipped, so without a bound a slow network could spin for minutes.
    var budget: TimeInterval = PracticeWildGenerator.defaultBudget
    static let defaultBudget: TimeInterval = 20

    /// Up to `count` candidates within ±3 levels of `playerLevel`, the same for the same `seed`. Species whose
    /// line or details cannot be loaded are skipped (offline, PokéAPI's disk cache still serves details).
    /// Throws when not a single candidate could be made.
    ///
    /// One splitmix64 stream per call. Draws per attempt, in order: base (`HatchRule`, nothing collected), level,
    /// one branch choice per evolving node along the planned path (the app's `makeEvolutionPlan`), the line's
    /// form (only lines with forms), shiny, nature, profile seed. An attempt that is skipped has still drawn.
    /// At most `count * 4` attempts; a species already made is skipped. Once `budget` seconds have passed no new
    /// attempt starts: what was made is returned, or `.noCandidates` is thrown if nothing was. A cancellation inside
    /// a request is rethrown, never skipped.
    func make(count: Int, around playerLevel: Int, seed: UInt64) async throws -> [PracticeCandidate] {
        guard count > 0 else { return [] }
        let started = clock()
        let index = try await source.provider.baseSpeciesIndex()
        var rng = WildRNG(seed: seed)
        var made: [PracticeCandidate] = []
        var species = Set<Int>()
        for _ in 0..<(count * 4) {
            guard made.count < count else { break }
            try Task.checkCancellation()
            guard clock() - started < budget else { break }
            let id = "wild-\(seed)-\(made.count)"
            if let candidate = try await attempt(index: index, playerLevel: playerLevel, id: id, rng: &rng, taken: species),
               let speciesNum = candidate.snapshot?.set.speciesNum {
                species.insert(speciesNum)
                made.append(candidate)
            }
        }
        try Task.checkCancellation()
        guard !made.isEmpty else { throw PracticeWildError.noCandidates }
        return made
    }

    private func attempt(index: [BaseSpecies], playerLevel: Int, id: String, rng: inout WildRNG,
                         taken: Set<Int>) async throws -> PracticeCandidate? {
        guard let baseID = HatchRule.pickBase(from: index, isCollected: { _ in false }, roll: rng.next()) else { return nil }
        let level = PracticeWildRules.level(around: playerLevel, roll: rng.next())
        // Offline the evolution line is gone (memory-only cache): the base species still works, so fall back to it.
        let line = try await loaded { try await source.provider.line(baseSpeciesID: baseID) }
        var path = [baseID]
        if let line {
            var node = line.tree
            while !node.children.isEmpty {
                node = node.children[Int(rng.next() % UInt64(node.children.count))]
                path.append(node.speciesID)
            }
        }
        let rarity = line?.rarity ?? Rarity.from(captureRate: index.first { $0.id == baseID }?.captureRate ?? 255,
                                                 isLegendary: false, isMythical: false)
        let speciesID = path[min(path.count - 1, PracticeWildRules.stageIndex(level: level, totalForms: path.count))]
        let lineForms = PokemonForm.lineForms(baseID: baseID)
        let form = lineForms.isEmpty ? nil : PokemonForm.roll(rng.next(), among: lineForms, collected: [])
        let shiny = CompanionStore.rollsShiny(roll: rng.next(), charmOwned: false)
        let nature = PokemonNature.allCases[Int(rng.next() % UInt64(PokemonNature.allCases.count))]
        let profileSeed = rng.next()
        guard !taken.contains(speciesID) else { return nil }
        guard let details = try await loaded({ try await source.details.pokemonDetails(speciesID: speciesID) }) else { return nil }
        var profile = PokemonProfile.generate(seed: profileSeed, instanceID: id)
        profile.level = level
        profile.enrich(with: details)
        guard let snapshot = try? BattleSnapshot.make(
            speciesID: speciesID, form: PokemonForm.resolved(speciesID: speciesID, form: form),
            shiny: shiny, nature: nature, profile: profile, using: engine) else { return nil }
        let name = line?.names[speciesID]?["ko"] ?? snapshot.publicInfo.species
        return PracticeCandidate(id: id, name: name, snapshot: snapshot, blockedReason: nil,
                                 origin: .wild(rarity: rarity, shiny: shiny))
    }
}

extension PracticeWildGenerator {
    /// A request's result, or nil when it failed (offline, timeout): the attempt then falls back or is skipped.
    /// A cancellation is not a failure — it stops the whole search.
    fileprivate func loaded<T>(_ request: () async throws -> T) async throws -> T? {
        do { return try await request() }
        catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()   // URLSession reports a cancelled task as URLError.cancelled
            return nil
        }
    }
}

enum PracticeWildError: Error, Equatable {
    /// Not a single wild opponent could be made (no species index, or no species whose data loaded).
    case noCandidates
}

/// The same splitmix64 the app's profile rolls use; its own copy so wild draws never share a stream with them.
struct WildRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// The wild-opponent search shown on the selection screen.
enum PracticeWildState: Equatable, Sendable {
    case idle, searching, ready
    /// Nothing could be made (e.g. offline with nothing cached); the view words it (`L.practiceWildUnavailable`).
    case unavailable
}
