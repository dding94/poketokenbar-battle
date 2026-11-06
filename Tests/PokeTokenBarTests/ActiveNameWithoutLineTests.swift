import XCTest
@testable import PokeTokenBar

private let activeNameEngineURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("engine/dist/battle-engine.js")

/// PokéAPI as a Mac without a network sees it, until `reconnect()`. `PokeAPIClient.line` keeps its result in memory
/// only, so after a relaunch every line needs the network.
private actor UnreachableLineProvider: PokeProviding, PokemonDetailProviding {
    private var online = false
    private(set) var attempts = 0
    private let names: [Int: [String: String]]
    init(names: [Int: [String: String]] = [25: ["en": "Pikachu", "ko": "피카츄"]]) { self.names = names }
    func reconnect() { online = true }
    func line(baseSpeciesID: Int) async throws -> EvoLine {
        attempts += 1
        guard online else { throw URLError(.notConnectedToInternet) }
        return EvoLine(baseID: baseSpeciesID, tree: EvoNode(speciesID: baseSpeciesID, children: []),
                       rarity: .common, names: names)
    }
    func baseSpeciesIndex() async throws -> [BaseSpecies] { throw URLError(.notConnectedToInternet) }
    func baseSpecies(id: Int) async throws -> BaseSpecies? { throw URLError(.notConnectedToInternet) }
    func pokemonDetails(speciesID: Int) async throws -> PokemonDetails { throw URLError(.notConnectedToInternet) }
}

/// A relaunch with no network: the save holds a hatched Pokémon, its evolution line is not persisted and cannot be
/// fetched. Battles need neither the line nor the network, so that Pokémon is on the roster with no line to name it.
@MainActor
final class ActiveNameWithoutLineTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("active-name-\(UUID().uuidString)",
                                                                                 isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try FileManager.default.removeItem(at: folder) }

    private func saved(speciesID: Int = 25, form: PokemonForm? = nil, active: Bool = true) -> CompanionState {
        var state = CompanionState()
        state.installBaselineSet = true; state.lastDate = "2026-11-06"; state.language = .en
        guard active else { return state }
        var profile = PokemonProfile.generate(seed: 42, instanceID: "mon")
        profile.level = 50; profile.gender = .male; profile.abilityName = "static"
        profile.moves = [PokemonKnownMove(name: "thunderbolt", learnedAtLevel: 1)]
        state.active = MonState(baseID: speciesID, pathIDs: [speciesID], stageIndex: 0, usedAtStage: 0, rarity: .common,
                                totalForms: 1, nature: .hardy, profile: profile, form: form)
        return state
    }

    private func relaunch(_ state: CompanionState, provider: UnreachableLineProvider) throws -> CompanionStore {
        let url = folder.appendingPathComponent("companion-state.json")
        try JSONEncoder().encode(state).write(to: url)
        return CompanionStore(provider: provider, clock: { Date(timeIntervalSince1970: 1_793_400_000) }, fileURL: url,
                              dittoDisguiseRollingEnabled: false)
    }

    /// One refresh tick, which is what asks for a missing line.
    private func tick(_ store: CompanionStore) {
        store.update(todayTokensByProvider: ["test": 0], todayDate: "2026-11-06", monthTotal: 0,
                     burnTier: .idle, limitWarning: false, hasUsageData: true)
    }

    /// Ticks until the store has asked `provider` for a line `attempts` times and that request has finished.
    private func waitForLineAttempt(_ store: CompanionStore, _ provider: UnreachableLineProvider,
                                    attempts: Int = 1) async throws {
        tick(store)
        var spins = 0
        while await provider.attempts < attempts, spins < 500 { await Task.yield(); spins += 1 }
        for _ in 0..<20 { await Task.yield() }
        let made = await provider.attempts
        XCTAssertEqual(made, attempts, "precondition: the tick reached the failing provider")
    }

    /// A hatched Pokémon is not an egg, whether or not its line has loaded. The header, the bag, the shop and the menu
    /// bar's tooltip all read this name.
    func testAHatchedPokemonWhoseLineCannotLoadIsNotCalledAnEgg() async throws {
        let provider = UnreachableLineProvider()
        let store = try relaunch(saved(), provider: provider)
        try await waitForLineAttempt(store, provider)
        XCTAssertNil(store.currentLine, "precondition: the fetch failed")
        XCTAssertFalse(store.isEgg, "precondition: a hatched Pokémon")
        XCTAssertEqual(store.displayName, "#25")
    }

    /// The trigger of the report: the roster row of that Pokémon can fight, and it is named as the bag names it.
    func testTheRosterRowOfThatPokemonCanFightAndMatchesTheBag() async throws {
        let provider = UnreachableLineProvider()
        let store = try relaunch(saved(), provider: provider)
        try await waitForLineAttempt(store, provider)
        XCTAssertNil(store.currentLine, "precondition: the fetch failed")

        let session = PracticeSession(
            engineURL: activeNameEngineURL, clock: { 0 }, drivesAutomatically: false,
            wildSource: PracticeWildSource(provider: provider, details: provider), wildSeed: { 11 },
            recordStore: PracticeRecordStore(fileURL: nil), effects: store)
        // What the popover passes when the practice screen appears.
        session.prepare(state: store.state, activeName: store.displayName)
        let row = try XCTUnwrap(session.roster?.eligible.first { $0.id == "mon" },
                                "the battle needs neither the line nor the network")
        XCTAssertEqual(row.name, "#25")
        XCTAssertEqual(row.name, store.ownedIndividuals.first { $0.id == "mon" }?.name)

        // What the sessions read when they rebuild the roster after a battle.
        let online = try XCTUnwrap(store.companionState())
        let rebuilt = PracticeRoster(state: online.state, activeName: online.activeName,
                                     engine: try BattleEngine(url: activeNameEngineURL))
        XCTAssertEqual(rebuilt.candidates.first?.name, "#25")
    }

    /// The form tag the name carries with a line does not depend on the line.
    func testTheNumberKeepsTheFormTag() async throws {
        let provider = UnreachableLineProvider()
        let form = PokemonForm("b")
        let store = try relaunch(saved(speciesID: PokemonForm.unownSpeciesID, form: form), provider: provider)
        try await waitForLineAttempt(store, provider)
        XCTAssertNil(store.currentLine, "precondition: the fetch failed")
        XCTAssertEqual(store.displayName, "#201 [\(form.symbol)]")
        XCTAssertEqual(store.ownedIndividuals.first?.name, store.displayName)
    }

    /// The other branch of the same guard: with no Pokémon at all, the name is still the egg's.
    func testAnEggIsStillCalledAnEgg() throws {
        let store = try relaunch(saved(active: false), provider: UnreachableLineProvider())
        XCTAssertTrue(store.isEgg, "precondition: no Pokémon")
        XCTAssertEqual(store.displayName, "Token Egg")
    }

    /// The number is only for while the line is missing: the next tick that reaches the network brings the name back.
    func testTheNameComesBackWithTheNetwork() async throws {
        let provider = UnreachableLineProvider()
        let store = try relaunch(saved(), provider: provider)
        try await waitForLineAttempt(store, provider)
        XCTAssertEqual(store.displayName, "#25")

        await provider.reconnect()
        try await waitForLineAttempt(store, provider, attempts: 2)
        XCTAssertNotNil(store.currentLine, "precondition: the retry succeeded")
        XCTAssertEqual(store.displayName, "Pikachu")
        XCTAssertEqual(store.ownedIndividuals.first?.name, "Pikachu")
    }

    /// A loaded line with no stored name for this species was already covered by `EvoLine.localizedName`.
    func testALoadedLineWithoutTheNameUsesTheNumberToo() async throws {
        let provider = UnreachableLineProvider(names: [:])
        await provider.reconnect()
        let store = try relaunch(saved(), provider: provider)
        try await waitForLineAttempt(store, provider)
        XCTAssertNotNil(store.currentLine, "precondition: the line loaded")
        XCTAssertEqual(store.displayName, "#25")
    }
}
