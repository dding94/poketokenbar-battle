import XCTest
@testable import PokeTokenBar

// MARK: Fixtures

private let stakesEngineURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("engine/dist/battle-engine.js")
private let stakesNow = Date(timeIntervalSince1970: 1_793_400_000)   // 2026-10-30 22:40 UTC

/// splitmix64 of this file's own, so the store's draws are fixed.
private struct StakesRNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// The store's PokéAPI: the three-stage line 1 → 2 → 3 and no index (the bag and HP need no network).
private struct StakesLineProvider: PokeProviding {
    func line(baseSpeciesID: Int) async throws -> EvoLine {
        EvoLine(baseID: 1, tree: EvoNode(speciesID: 1, children: [EvoNode(speciesID: 2, children: [EvoNode(speciesID: 3, children: [])])]),
                rarity: .common, names: [:])
    }
    func baseSpeciesIndex() async throws -> [BaseSpecies] { [] }
    func baseSpecies(id: Int) async throws -> BaseSpecies? { nil }
}

/// One wild species that knows only `moves`, so a battle against it ends the same way on every seed: a Magikarp's
/// Quick Attack (priority) always hits Pikachu before Thunderbolt knocks it out; a wild Pikachu's Thunderbolt knocks
/// out a Magikarp that can only Splash; two Blissey with status moves only reach the 200-turn cap.
private struct StakesWildStub: PokeProviding, PokemonDetailProviding {
    let speciesID: Int
    let moves: [String]
    func line(baseSpeciesID: Int) async throws -> EvoLine {
        EvoLine(baseID: speciesID, tree: EvoNode(speciesID: speciesID, children: []), rarity: .common, names: [:])
    }
    func baseSpeciesIndex() async throws -> [BaseSpecies] { [BaseSpecies(id: speciesID, captureRate: 255)] }
    func baseSpecies(id: Int) async throws -> BaseSpecies? { try await baseSpeciesIndex().first { $0.id == id } }
    func pokemonDetails(speciesID: Int) async throws -> PokemonDetails {
        PokemonDetails(
            speciesID: speciesID, name: "species-\(speciesID)", height: 10, weight: 100, baseExperience: 64, genderRate: 4,
            types: ["normal"],
            baseStats: ["hp": 45, "attack": 49, "defense": 49, "special-attack": 65, "special-defense": 65, "speed": 45],
            abilities: [PokemonAbilityOption(name: "natural-cure", slot: 1, isHidden: false)],
            moves: moves.map { PokemonMoveOption(name: $0, learnMethods: [PokemonMoveLearnMethod(method: "level-up", level: 1)]) })
    }
}

/// (instance id, species, moves, ability), all Lv.50. Natural Cure, not Pressure, keeps a staller's PP for 200 turns.
private typealias StakesSpec = (String, Int, [String], String)
private let stakesPikachu: StakesSpec = ("p", 25, ["thunderbolt"], "static")
private let stakesMagikarp: StakesSpec = ("m", 129, ["splash"], "swift-swim")
private let stakesTackler: StakesSpec = ("b", 242, ["tackle"], "natural-cure")
private let stakesStaller: StakesSpec = ("s", 242, ["splash", "growl", "tail-whip", "defense-curl"], "natural-cure")
private let stakesStatusMoves = ["splash", "growl", "tail-whip", "defense-curl"]

private func stakesProfile(_ id: String, moves: [String], ability: String) -> PokemonProfile {
    var profile = PokemonProfile.generate(seed: 42, instanceID: id)
    profile.level = 50; profile.gender = .male; profile.abilityName = ability
    profile.moves = moves.map { PokemonKnownMove(name: $0, learnedAtLevel: 1) }
    return profile
}

private func stakesState(_ specs: [StakesSpec]) -> CompanionState {
    var state = CompanionState()
    state.dex = specs.map { id, species, moves, ability in
        DexEntry(baseID: species, finalID: species, chainOrder: [species], rarity: .common, caughtAt: nil,
                 nature: .hardy, profile: stakesProfile(id, moves: moves, ability: ability))
    }
    return state
}

/// What a session asks of the save: HP shares by instance id (1 when unknown) and XP grants for a current Pokémon.
@MainActor
private final class StakesEffects: PracticeBattleEffects {
    var shares: [String: Double] = [:]
    var hasCurrent = true
    private(set) var writes = 0
    private(set) var grants: [Int] = []
    func healthShare(of instanceID: String) -> Double { shares[instanceID] ?? 1 }
    func setHealthShare(_ share: Double, of instanceID: String) { shares[instanceID] = share; writes += 1 }
    func grantBattleXP(_ xp: Int) -> Bool {
        guard hasCurrent else { return false }
        grants.append(xp)
        return true
    }
}

/// The wall clock the session reads for the day; tests move it.
private final class StakesToday { var date = stakesNow }

private var stakesUTC: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
    return calendar
}

@MainActor
private func stakesSession(_ specs: [StakesSpec], wild: StakesWildStub, effects: (any PracticeBattleEffects)?,
                           today: StakesToday = StakesToday(),
                           recordStore: PracticeRecordStore = PracticeRecordStore(fileURL: nil)) -> PracticeSession {
    let session = PracticeSession(engineURL: stakesEngineURL, clock: { 0 }, drivesAutomatically: false,
                                  wildSource: PracticeWildSource(provider: wild, details: wild), wildSeed: { 11 },
                                  recordStore: recordStore, now: { today.date }, calendar: stakesUTC, effects: effects)
    session.prepare(state: stakesState(specs), activeName: nil)
    return session
}

/// Searches the wild opponents for the current player and waits for them and today's opponent.
@MainActor
private func stakesSearch(_ session: PracticeSession) async {
    session.findWildOpponents()
    let tasks = [session.wildTask, session.dailyTask]
    for task in tasks { await task?.value }
}

/// Plays an automatic battle against `opponent` straight to its result.
@MainActor
private func stakesFight(_ session: PracticeSession, against opponent: String) {
    session.opponentID = opponent
    session.mode = .automatic
    session.start()
    session.skipToResult()
}

private func stakesFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("practice-stakes-\(UUID().uuidString)",
                                                                                  isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

// MARK: Save and records

/// The battle HP in the save and the XP count in the records file decode from files written before they existed.
@MainActor
final class PracticeStakesSaveTests: XCTestCase {
    func testAnOldSaveDecodesAtFullHP() throws {
        let json = #"{"installBaselineSet":true,"usedSinceInstall":900,"lastDate":"d","dex":[],"inventory":{"mint":2}}"#
        let state = try JSONDecoder().decode(CompanionState.self, from: Data(json.utf8))
        XCTAssertEqual(state.battleHealth, [:])
        XCTAssertEqual(state.inventory, ["mint": 2])
    }

    func testBattleHPRoundTripsAndADamagedValueLosesOnlyItself() throws {
        var state = CompanionState()
        state.battleHealth = ["a": 0.5, "b": 0]
        let decoded = try JSONDecoder().decode(CompanionState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded.battleHealth, ["a": 0.5, "b": 0])
        let damaged = #"{"usedSinceInstall":900,"battleHealth":"oops","inventory":{"potion":2}}"#
        let lenient = try JSONDecoder().decode(CompanionState.self, from: Data(damaged.utf8))
        XCTAssertEqual(lenient.battleHealth, [:], "a damaged value falls back to full HP")
        XCTAssertEqual(lenient.inventory, ["potion": 2], "the rest of the save survives")
        XCTAssertEqual(lenient.usedSinceInstall, 900)
    }

    /// An upstream save has no battle HP: the first-launch copy loads every individual at full HP.
    func testAnUpstreamImportLoadsAtFullHP() throws {
        let upstream = try stakesFolder(), fork = try stakesFolder()
        defer { try? FileManager.default.removeItem(at: upstream); try? FileManager.default.removeItem(at: fork) }
        var state = CompanionState()
        state.installBaselineSet = true; state.lastDate = "d"
        state.dex = stakesState([stakesPikachu]).dex
        var upstreamJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        upstreamJSON["battleHealth"] = nil
        try JSONSerialization.data(withJSONObject: upstreamJSON)
            .write(to: upstream.appendingPathComponent(UpstreamSaveImport.fileName))
        XCTAssertEqual(UpstreamSaveImport.runIfNeeded(from: upstream, to: fork), .imported)
        let store = CompanionStore(provider: StakesLineProvider(), clock: { stakesNow },
                                   fileURL: fork.appendingPathComponent(UpstreamSaveImport.fileName),
                                   rng: StakesRNG(state: 1), dittoDisguiseRollingEnabled: false)
        // The imported save itself loaded, not a fresh one that a failed decode would fall back to.
        XCTAssertEqual(store.state.dex.compactMap(\.profile?.instanceID), ["p"], "the imported save did not load")
        XCTAssertEqual(store.state.battleHealth, [:])
        XCTAssertEqual(store.healthShare(of: "p"), 1)
    }

    func testAnOldRecordsFileDecodesWithoutXPCounts() throws {
        let json = #"{"version":1,"wins":3,"losses":1,"draws":0,"streak":2,"bestStreak":2,"dailyStars":[]}"#
        let records = try JSONDecoder().decode(PracticeRecords.self, from: Data(json.utf8))
        XCTAssertNil(records.xpDay); XCTAssertNil(records.xpWins)
        XCTAssertEqual(records.wins, 3); XCTAssertEqual(records.streak, 2)
    }
}

// MARK: Store

/// The save side of PR 03C: HP between battles, the healing items, the IV reroll, battle XP and the shop prices.
@MainActor
final class PracticeStakesStoreTests: XCTestCase {
    private static let maxIVs = PokemonIVs(hp: 31, attack: 31, defense: 31, specialAttack: 31, specialDefense: 31, speed: 31)

    /// A save whose current Pokémon has the instance id "mon", IVs all 31, a nature, shiny and a Ditto disguise.
    private func makeState(items: [ItemKind: Int] = [:], health: [String: Double] = [:], active: Bool = true,
                           usedAtStage: Int = 50_000_000) -> CompanionState {
        var state = CompanionState()
        state.installBaselineSet = true; state.usedSinceInstall = 10_000_000_000; state.lastDate = "d1"
        state.inventory = Dictionary(uniqueKeysWithValues: items.map { ($0.key.rawValue, $0.value) })
        state.battleHealth = health
        if active {
            var profile = PokemonProfile.generate(seed: 42, instanceID: "mon")
            profile.ivs = Self.maxIVs
            profile.gender = .female; profile.abilityName = "overgrow"; profile.abilitySlot = 1
            profile.moves = [PokemonKnownMove(name: "tackle", learnedAtLevel: 1)]
            state.active = MonState(baseID: 1, pathIDs: [1], stageIndex: 0, usedAtStage: usedAtStage, rarity: .common,
                                    totalForms: 3, isShiny: true, nature: .adamant, profile: profile,
                                    dittoDisguise: 1, dittoRevealed: false)
        }
        return state
    }
    private func makeStore(_ state: CompanionState, at url: URL, seed: UInt64 = 7,
                           defaults: UserDefaults = .standard) throws -> CompanionStore {
        try JSONEncoder().encode(state).write(to: url)
        return reopen(url, seed: seed, defaults: defaults)
    }
    private func reopen(_ url: URL, seed: UInt64 = 7, defaults: UserDefaults = .standard) -> CompanionStore {
        CompanionStore(provider: StakesLineProvider(), clock: { stakesNow }, fileURL: url, rng: StakesRNG(state: seed),
                       dittoDisguiseRollingEnabled: false, defaults: defaults)
    }
    private func encoded(_ mon: MonState?) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(XCTUnwrap(mon))
    }

    // MARK: HP

    func testHPStartsFullClampsAndDropsAFullEntry() throws {
        let folder = try stakesFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("companion-state.json")
        let store = try makeStore(makeState(), at: url)
        XCTAssertEqual(store.healthShare(of: "mon"), 1); XCTAssertEqual(store.state.battleHealth, [:])
        store.setHealthShare(0.4, of: "mon")
        XCTAssertEqual(store.healthShare(of: "mon"), 0.4); XCTAssertEqual(store.state.battleHealth, ["mon": 0.4])
        store.setHealthShare(-0.2, of: "mon")
        XCTAssertEqual(store.healthShare(of: "mon"), 0, "below 0 is fainted")
        store.setHealthShare(1.7, of: "mon")
        XCTAssertEqual(store.healthShare(of: "mon"), 1)
        XCTAssertEqual(store.state.battleHealth, [:], "full HP keeps no entry, so the save stays small")
        store.setHealthShare(0.25, of: "mon")
        XCTAssertEqual(reopen(url).healthShare(of: "mon"), 0.25, "kept in the save")
    }

    func testAHandEditedShareIsReadWithinRange() throws {
        let folder = try stakesFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = try makeStore(makeState(health: ["mon": 3.5, "other": -2]), at: folder.appendingPathComponent("s.json"))
        XCTAssertEqual(store.healthShare(of: "mon"), 1)
        XCTAssertEqual(store.healthShare(of: "other"), 0)
    }

    /// Setting the HP an individual already has, as a battle with stakes won or drawn at full HP does, leaves the save
    /// file alone; a change writes it.
    func testAnUnchangedHPLeavesTheSaveFileAlone() throws {
        let folder = try stakesFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("s.json")
        let store = try makeStore(makeState(health: ["mon": 0.4]), at: url)
        try FileManager.default.removeItem(at: url)
        store.setHealthShare(0.4, of: "mon")
        store.setHealthShare(1, of: "fresh")
        store.setHealthShare(1.5, of: "fresh")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "nothing changed, so nothing was written")
        store.setHealthShare(0.5, of: "mon")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "a change is written")
    }

    // MARK: Healing items

    func testAPotionHealsHalfUpToFullAndOnlyAWoundedPokemon() throws {
        let folder = try stakesFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = try makeStore(makeState(items: [.potion: 3], health: ["mon": 0.3]), at: folder.appendingPathComponent("s.json"))
        XCTAssertTrue(store.useHealingItem(.potion, on: "mon"))
        XCTAssertEqual(store.healthShare(of: "mon"), 0.3 + BattleItem.potionHeal, accuracy: 1e-9)
        XCTAssertEqual(store.itemCount(.potion), 2)
        XCTAssertTrue(store.useHealingItem(.potion, on: "mon"))
        XCTAssertEqual(store.healthShare(of: "mon"), 1, "never above full")
        XCTAssertEqual(store.state.battleHealth, [:]); XCTAssertEqual(store.itemCount(.potion), 1)
        XCTAssertFalse(store.useHealingItem(.potion, on: "mon"), "nothing to heal at full HP")
        XCTAssertEqual(store.itemCount(.potion), 1, "a refused use spends nothing")
        store.setHealthShare(0, of: "mon")
        XCTAssertFalse(store.useHealingItem(.potion, on: "mon"), "a fainted Pokémon needs a Revive")
        XCTAssertEqual(store.itemCount(.potion), 1); XCTAssertEqual(store.healthShare(of: "mon"), 0)
    }

    func testAHyperPotionHealsFullyAndOnlyAWoundedPokemon() throws {
        let folder = try stakesFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = try makeStore(makeState(items: [.hyperPotion: 2], health: ["mon": 0.2, "down": 0]),
                                  at: folder.appendingPathComponent("s.json"))
        XCTAssertFalse(store.useHealingItem(.hyperPotion, on: "down"), "a fainted Pokémon needs a Revive")
        XCTAssertFalse(store.useHealingItem(.hyperPotion, on: "fresh"), "nothing to heal at full HP")
        XCTAssertEqual(store.itemCount(.hyperPotion), 2)
        XCTAssertTrue(store.useHealingItem(.hyperPotion, on: "mon"))
        XCTAssertEqual(store.healthShare(of: "mon"), 1); XCTAssertEqual(store.itemCount(.hyperPotion), 1)
        XCTAssertEqual(store.state.battleHealth, ["down": 0])
    }

    func testAReviveOnlyBringsBackAFaintedPokemonToHalf() throws {
        let folder = try stakesFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = try makeStore(makeState(items: [.revive: 2], health: ["mon": 0, "hurt": 0.3]),
                                  at: folder.appendingPathComponent("s.json"))
        XCTAssertFalse(store.useHealingItem(.revive, on: "hurt"), "not fainted")
        XCTAssertFalse(store.useHealingItem(.revive, on: "fresh"), "not fainted")
        XCTAssertEqual(store.itemCount(.revive), 2)
        XCTAssertTrue(store.useHealingItem(.revive, on: "mon"))
        XCTAssertEqual(store.healthShare(of: "mon"), BattleItem.reviveShare); XCTAssertEqual(store.itemCount(.revive), 1)
        XCTAssertFalse(store.useHealingItem(.revive, on: "mon"), "back up: no longer fainted")
        XCTAssertEqual(store.itemCount(.revive), 1)
    }

    func testHealingNeedsTheItemAndAHealingKind() throws {
        let folder = try stakesFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = try makeStore(makeState(items: [.rareCandy: 1, .mint: 1, .shinyCharm: 1, .ivReroll: 1], health: ["mon": 0.3]),
                                  at: folder.appendingPathComponent("s.json"))
        for kind in [ItemKind.potion, .hyperPotion] {
            XCTAssertFalse(store.useHealingItem(kind, on: "mon"), "\(kind): none in the bag")
        }
        for kind in [ItemKind.rareCandy, .mint, .shinyCharm, .ivReroll] {
            XCTAssertFalse(store.useHealingItem(kind, on: "mon"), "\(kind) does not heal")
            XCTAssertEqual(store.itemCount(kind), 1, "\(kind) not spent")
        }
        XCTAssertEqual(store.healthShare(of: "mon"), 0.3)
    }

    func testAHealIsSaved() throws {
        let folder = try stakesFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("s.json")
        let store = try makeStore(makeState(items: [.potion: 2], health: ["mon": 0.1]), at: url)
        XCTAssertTrue(store.useHealingItem(.potion, on: "mon"))
        let reopened = reopen(url)
        XCTAssertEqual(reopened.itemCount(.potion), 1)
        XCTAssertEqual(reopened.healthShare(of: "mon"), 0.1 + BattleItem.potionHeal, accuracy: 1e-9)
    }

    // MARK: IV reroll

    func testIVRerollKeepsEverythingButTheIVs() throws {
        let folder = try stakesFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("s.json")
        let store = try makeStore(makeState(items: [.ivReroll: 2]), at: url)
        let before = try XCTUnwrap(store.state.active)
        XCTAssertEqual(before.profile?.ivs, Self.maxIVs)
        let ivs = try XCTUnwrap(store.useIVReroll())
        let after = try XCTUnwrap(store.state.active)
        XCTAssertEqual(after.profile?.ivs, ivs)
        XCTAssertNotEqual(ivs, Self.maxIVs, "the new IVs apply even when lower")
        for value in [ivs.hp, ivs.attack, ivs.defense, ivs.specialAttack, ivs.specialDefense, ivs.speed] {
            XCTAssertTrue((0...31).contains(value), "\(value)")
        }
        var expected = before
        expected.profile?.ivs = ivs
        XCTAssertEqual(try encoded(after), try encoded(expected),
                       "species, level, growth, nature, shiny and the Ditto disguise stay")
        XCTAssertEqual(store.itemCount(.ivReroll), 1)
        XCTAssertEqual(reopen(url).state.active?.profile?.ivs, ivs, "saved")
    }

    func testIVRerollNeedsTheItemAndACurrentPokemon() throws {
        let folder = try stakesFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let without = try makeStore(makeState(), at: folder.appendingPathComponent("a.json"))
        XCTAssertNil(without.useIVReroll())
        XCTAssertEqual(without.state.active?.profile?.ivs, Self.maxIVs)
        let egg = try makeStore(makeState(items: [.ivReroll: 1], active: false), at: folder.appendingPathComponent("b.json"))
        XCTAssertNil(egg.useIVReroll())
        XCTAssertEqual(egg.itemCount(.ivReroll), 1, "nothing spent without a current Pokémon")
    }

    func testIVRerollDrawsFromTheStoresRandomNumbers() throws {
        let folder = try stakesFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        func reroll(seed: UInt64, _ name: String) throws -> PokemonIVs? {
            try makeStore(makeState(items: [.ivReroll: 1]), at: folder.appendingPathComponent(name), seed: seed).useIVReroll()
        }
        let first = try reroll(seed: 3, "a.json"), again = try reroll(seed: 3, "b.json"), other = try reroll(seed: 4, "c.json")
        XCTAssertNotNil(first)
        XCTAssertEqual(first, again)
        XCTAssertNotEqual(first, other)
    }

    // MARK: Battle XP

    func testBattleXPGrowsTheCurrentPokemonWithoutUsageStatistics() throws {
        let folder = try stakesFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("s.json")
        let store = try makeStore(makeState(), at: url)
        let before = store.state
        XCTAssertTrue(store.grantBattleXP(PracticeStakes.winXP))
        XCTAssertEqual(store.state.active?.usedAtStage, (before.active?.usedAtStage ?? 0) + PracticeStakes.winXP)
        XCTAssertGreaterThan(store.state.active?.profile?.growthTokens ?? 0, before.active?.profile?.growthTokens ?? 0)
        XCTAssertEqual(store.state.usedSinceInstall, before.usedSinceInstall, "not usage: the wallet and statistics stay")
        XCTAssertEqual(store.state.spentTokens, before.spentTokens)
        XCTAssertEqual(store.state.eggUsage, before.eggUsage)
        XCTAssertEqual(reopen(url).state.active?.usedAtStage, (before.active?.usedAtStage ?? 0) + PracticeStakes.winXP)
    }

    /// The same path as a Rare Candy: with the line loaded, crossing the stage threshold (125M) evolves and carries
    /// the rest over.
    func testBattleXPEvolvesLikeACandyOnceTheLineIsLoaded() async throws {
        let folder = try stakesFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        var state = makeState(usedAtStage: 123_000_000)
        state.active?.dittoDisguise = nil
        let store = try makeStore(state, at: folder.appendingPathComponent("s.json"))
        store.update(todayTokensByProvider: ["test": 0], todayDate: "d1", monthTotal: 0,
                     burnTier: .idle, limitWarning: false, hasUsageData: true)
        for _ in 0..<50 where store.currentLine == nil { await Task.yield() }
        XCTAssertNotNil(store.currentLine)
        XCTAssertEqual(store.state.active?.stageIndex, 0)
        XCTAssertTrue(store.grantBattleXP(PracticeStakes.winXP))
        XCTAssertEqual(store.state.active?.stageIndex, 1, "evolved")
        XCTAssertEqual(store.state.active?.usedAtStage, 123_000_000 + PracticeStakes.winXP - 125_000_000)
    }

    func testNoCurrentPokemonGetsNoBattleXP() throws {
        let folder = try stakesFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("s.json")
        let store = try makeStore(makeState(active: false), at: url)
        let saved = try Data(contentsOf: url)
        XCTAssertFalse(store.grantBattleXP(PracticeStakes.winXP))
        XCTAssertNil(store.state.active)
        XCTAssertEqual(store.state.eggUsage, 0)
        XCTAssertEqual(try Data(contentsOf: url), saved, "nothing written")
    }

    // MARK: Shop

    func testTheBattleItemsAreSoldAtTheirScaledPrices() throws {
        XCTAssertEqual(ItemKind.potion.shopPrice, BattleItem.potionPrice)
        XCTAssertEqual(ItemKind.hyperPotion.shopPrice, BattleItem.hyperPotionPrice)
        XCTAssertEqual(ItemKind.revive.shopPrice, BattleItem.revivePrice)
        XCTAssertEqual(ItemKind.ivReroll.shopPrice, BattleItem.ivRerollPrice)
        let suite = "PracticeStakesTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(2.0, forKey: "shopDifficulty")
        let folder = try stakesFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = try makeStore(makeState(), at: folder.appendingPathComponent("s.json"), defaults: defaults)
        XCTAssertEqual(store.price(of: .potion), 2 * BattleItem.potionPrice)
        XCTAssertEqual(store.price(of: .hyperPotion), 2 * BattleItem.hyperPotionPrice)
        XCTAssertEqual(store.price(of: .revive), 2 * BattleItem.revivePrice)
        XCTAssertEqual(store.price(of: .ivReroll), 2 * BattleItem.ivRerollPrice)
        for kind in [ItemKind.potion, .hyperPotion, .revive, .ivReroll] {
            XCTAssertTrue(store.purchasableItems.contains(kind), "\(kind) on sale")
            XCTAssertFalse(kind.isPassive, "\(kind) is used up")
        }
        let wallet = store.availableTokens
        XCTAssertTrue(store.buy(.revive, count: 2))
        XCTAssertEqual(store.availableTokens, wallet - 4 * BattleItem.revivePrice)
        XCTAssertEqual(store.itemCount(.revive), 2)
    }
}

// MARK: Session

/// Battles against wild opponents and today's opponent have stakes: the player keeps the HP it has left (0 after a
/// loss: fainted), and a win grows the current Pokémon, ten wins a day. Sparring between own Pokémon changes nothing.
@MainActor
final class PracticeStakesSessionTests: XCTestCase {
    func testAWinKeepsTheHPLeftAndGrowsTheCurrentPokemon() async throws {
        let effects = StakesEffects()
        let session = stakesSession([stakesPikachu, stakesMagikarp], wild: StakesWildStub(speciesID: 129, moves: ["quick-attack"]),
                                    effects: effects)
        session.playerID = "p"
        await stakesSearch(session)
        stakesFight(session, against: try XCTUnwrap(session.wildCandidates.first).id)
        XCTAssertEqual(session.battle?.result?.winner, "p1")
        let share = try XCTUnwrap(session.battle?.view?.p1.hpShare)
        XCTAssertGreaterThan(share, 0); XCTAssertLessThan(share, 1, "Quick Attack hit first")
        XCTAssertEqual(effects.shares["p"], share)
        XCTAssertEqual(effects.grants, [PracticeStakes.winXP])
        XCTAssertEqual(session.lastStakes, PracticeStakesUpdate(healthShare: share, xp: PracticeStakes.winXP,
                                                                xpWinsLeft: PracticeStakes.dailyXPWins - 1))
        XCTAssertEqual(session.records.xpDay, "2026-10-30"); XCTAssertEqual(session.records.xpWins, 1)
        XCTAssertEqual(session.records.wins, 1)
        session.start()
        XCTAssertNil(session.lastStakes, "a new battle has no stakes settled yet")
    }

    func testALossFaintsThePlayerAndPaysNothing() async throws {
        let effects = StakesEffects()
        let session = stakesSession([stakesPikachu, stakesMagikarp], wild: StakesWildStub(speciesID: 25, moves: ["thunderbolt"]),
                                    effects: effects)
        session.playerID = "m"
        await stakesSearch(session)
        stakesFight(session, against: try XCTUnwrap(session.wildCandidates.first).id)
        XCTAssertEqual(session.battle?.result?.winner, "p2")
        XCTAssertEqual(effects.shares["m"], 0, "a loss faints")
        XCTAssertEqual(effects.grants, [])
        XCTAssertEqual(session.lastStakes, PracticeStakesUpdate(healthShare: 0, xp: 0, xpWinsLeft: PracticeStakes.dailyXPWins))
        XCTAssertNil(session.records.xpWins)
        XCTAssertEqual(session.records.losses, 1)
    }

    func testADrawKeepsTheHPLeftAndPaysNothing() async throws {
        let effects = StakesEffects()
        let session = stakesSession([stakesStaller, stakesPikachu], wild: StakesWildStub(speciesID: 242, moves: stakesStatusMoves),
                                    effects: effects)
        session.playerID = "s"
        await stakesSearch(session)
        stakesFight(session, against: try XCTUnwrap(session.wildCandidates.first).id)
        XCTAssertNil(session.battle?.result?.winner); XCTAssertEqual(session.battle?.view?.turn, 200)
        XCTAssertEqual(effects.shares["s"], 1, "no move did damage")
        XCTAssertEqual(effects.grants, [])
        XCTAssertEqual(session.lastStakes, PracticeStakesUpdate(healthShare: 1, xp: 0, xpWinsLeft: PracticeStakes.dailyXPWins))
        XCTAssertEqual(session.records.draws, 1)
    }

    /// Giving up is running away: the HP left at that moment stays, without fainting, without XP; still a loss.
    func testRunningAwayKeepsTheHPLeftWithoutFaintingOrXP() async throws {
        let effects = StakesEffects()
        let session = stakesSession([stakesTackler, stakesPikachu], wild: StakesWildStub(speciesID: 129, moves: ["tackle"]),
                                    effects: effects)
        session.playerID = "b"
        await stakesSearch(session)
        session.opponentID = try XCTUnwrap(session.wildCandidates.first).id
        session.mode = .manual
        session.start()
        session.choose(slot: 1)
        XCTAssertEqual(session.battle?.phase, .running)
        let share = try XCTUnwrap(session.battle?.view?.p1.hpShare)
        XCTAssertGreaterThan(share, 0); XCTAssertLessThan(share, 1, "Magikarp's Tackle hit")
        session.forfeit()
        XCTAssertEqual(effects.shares["b"], share, "the HP left when running away, not fainted")
        XCTAssertEqual(effects.grants, [])
        XCTAssertEqual(session.lastStakes, PracticeStakesUpdate(healthShare: share, xp: 0, xpWinsLeft: PracticeStakes.dailyXPWins))
        XCTAssertEqual(session.records.losses, 1, "still a loss")
    }

    func testAFaintedPlayerSitsOutWildAndDailyBattlesButCanStillSpar() async throws {
        let effects = StakesEffects()
        effects.shares["p"] = 0
        let session = stakesSession([stakesPikachu, stakesMagikarp], wild: StakesWildStub(speciesID: 129, moves: ["splash"]),
                                    effects: effects)
        session.playerID = "p"
        await stakesSearch(session)
        let wild = try XCTUnwrap(session.wildCandidates.first).id
        session.opponentID = wild
        XCTAssertEqual(session.startBlock, .fainted)
        session.start()
        XCTAssertNil(session.battle, "a fainted Pokémon can't face a wild opponent")
        session.opponentID = try XCTUnwrap(session.dailyCandidate).id
        XCTAssertEqual(session.startBlock, .fainted)
        session.start()
        XCTAssertNil(session.battle, "nor today's opponent")
        stakesFight(session, against: "m")
        XCTAssertNil(session.startBlock, "sparring stays open")
        XCTAssertEqual(session.battle?.phase, .finished)
        XCTAssertEqual(effects.shares["p"], 0, "sparring heals nothing")
        XCTAssertEqual(effects.writes, 0); XCTAssertEqual(effects.grants, [])
        XCTAssertNil(session.lastStakes)
        effects.shares["p"] = 0.01
        session.opponentID = wild
        XCTAssertNil(session.startBlock, "any HP left can fight")
    }

    func testSparringChangesNothingOutsideTheSession() async throws {
        let effects = StakesEffects()
        let session = stakesSession([stakesPikachu, stakesMagikarp], wild: StakesWildStub(speciesID: 129, moves: ["splash"]),
                                    effects: effects)
        session.playerID = "p"
        stakesFight(session, against: "m")
        XCTAssertEqual(session.battle?.result?.winner, "p1")
        session.playerID = "m"
        stakesFight(session, against: "p")
        XCTAssertEqual(session.battle?.result?.winner, "p2")
        XCTAssertEqual(effects.writes, 0); XCTAssertEqual(effects.grants, [])
        XCTAssertNil(session.lastStakes)
        XCTAssertNil(session.records.xpDay)
        XCTAssertEqual(session.records.wins, 1); XCTAssertEqual(session.records.losses, 1)
    }

    func testXPPaysTenWinsADayAndStartsOverTheNextDay() async throws {
        let effects = StakesEffects(), today = StakesToday()
        let session = stakesSession([stakesPikachu, stakesMagikarp], wild: StakesWildStub(speciesID: 129, moves: ["splash"]),
                                    effects: effects, today: today)
        session.playerID = "p"
        await stakesSearch(session)
        let wild = try XCTUnwrap(session.wildCandidates.first).id
        for win in 1...PracticeStakes.dailyXPWins {
            stakesFight(session, against: wild)
            XCTAssertEqual(session.lastStakes?.xp, PracticeStakes.winXP, "win \(win)")
            XCTAssertEqual(session.lastStakes?.xpWinsLeft, PracticeStakes.dailyXPWins - win)
        }
        stakesFight(session, against: wild)
        XCTAssertEqual(session.battle?.result?.winner, "p1")
        XCTAssertEqual(session.lastStakes, PracticeStakesUpdate(healthShare: 1, xp: 0, xpWinsLeft: 0), "the eleventh win pays nothing")
        XCTAssertEqual(effects.grants.count, PracticeStakes.dailyXPWins)
        XCTAssertEqual(session.records.xpWins, PracticeStakes.dailyXPWins)
        XCTAssertEqual(session.records.wins, PracticeStakes.dailyXPWins + 1)
        today.date += 86_400
        stakesFight(session, against: wild)
        XCTAssertEqual(session.lastStakes?.xp, PracticeStakes.winXP, "a new day pays again")
        XCTAssertEqual(session.lastStakes?.xpWinsLeft, PracticeStakes.dailyXPWins - 1)
        XCTAssertEqual(session.records.xpDay, "2026-10-31"); XCTAssertEqual(session.records.xpWins, 1)
    }

    func testAWinWithoutACurrentPokemonPaysNoXPAndCountsNoXPWin() async throws {
        let effects = StakesEffects()
        effects.hasCurrent = false
        let session = stakesSession([stakesPikachu, stakesMagikarp], wild: StakesWildStub(speciesID: 129, moves: ["splash"]),
                                    effects: effects)
        session.playerID = "p"
        await stakesSearch(session)
        stakesFight(session, against: try XCTUnwrap(session.wildCandidates.first).id)
        XCTAssertEqual(session.battle?.result?.winner, "p1")
        XCTAssertEqual(session.lastStakes, PracticeStakesUpdate(healthShare: 1, xp: 0, xpWinsLeft: PracticeStakes.dailyXPWins))
        XCTAssertNil(session.records.xpWins)
    }

    func testTodaysOpponentHasStakesToo() async throws {
        let effects = StakesEffects()
        let session = stakesSession([stakesPikachu, stakesMagikarp], wild: StakesWildStub(speciesID: 129, moves: ["quick-attack"]),
                                    effects: effects)
        session.playerID = "p"
        await stakesSearch(session)
        stakesFight(session, against: try XCTUnwrap(session.dailyCandidate).id)
        XCTAssertEqual(session.battle?.result?.winner, "p1")
        let share = try XCTUnwrap(session.battle?.view?.p1.hpShare)
        XCTAssertLessThan(share, 1)
        XCTAssertEqual(effects.shares["p"], share); XCTAssertEqual(effects.grants, [PracticeStakes.winXP])
        XCTAssertEqual(session.lastRecord?.daily, true)
    }

    func testHPIsReportedForOwnCandidatesOnly() async throws {
        let effects = StakesEffects()
        effects.shares["m"] = 0.25
        let session = stakesSession([stakesPikachu, stakesMagikarp], wild: StakesWildStub(speciesID: 129, moves: ["splash"]),
                                    effects: effects)
        session.playerID = "p"
        await stakesSearch(session)
        XCTAssertEqual(session.healthShare(of: try XCTUnwrap(session.player)), 1)
        XCTAssertEqual(session.healthShare(of: try XCTUnwrap(session.roster?.eligible.first { $0.id == "m" })), 0.25)
        XCTAssertNil(session.healthShare(of: try XCTUnwrap(session.wildCandidates.first)))
        XCTAssertNil(session.healthShare(of: try XCTUnwrap(session.dailyCandidate)))
        let detached = stakesSession([stakesPikachu], wild: StakesWildStub(speciesID: 129, moves: ["splash"]), effects: nil)
        XCTAssertNil(detached.healthShare(of: try XCTUnwrap(detached.player)))
    }

    /// Without `effects` (tests, previews) a battle against a wild opponent stays inside the session.
    func testWithoutEffectsAWildBattleSettlesNothing() async throws {
        let session = stakesSession([stakesPikachu, stakesMagikarp], wild: StakesWildStub(speciesID: 129, moves: ["splash"]),
                                    effects: nil)
        session.playerID = "p"
        await stakesSearch(session)
        stakesFight(session, against: try XCTUnwrap(session.wildCandidates.first).id)
        XCTAssertEqual(session.battle?.result?.winner, "p1")
        XCTAssertNil(session.lastStakes); XCTAssertNil(session.records.xpDay)
        XCTAssertNil(session.startBlock)
        XCTAssertEqual(session.battle?.messages.first, stakesSparringOpening, "nothing changes, so it says so")
    }

    // MARK: Starting HP

    /// A hurt player enters a battle with stakes at its HP: a share worth 40.6 HP starts at 41 of its max HP, and the
    /// input log keeps 41, so a replay starts the same way. The opponent starts full and is given no HP.
    func testAHurtPlayerStartsABattleWithStakesAtItsHPAndTheInputLogKeepsIt() async throws {
        let effects = StakesEffects()
        let session = stakesSession([stakesTackler, stakesPikachu], wild: StakesWildStub(speciesID: 129, moves: ["splash"]),
                                    effects: effects)
        session.playerID = "b"
        await stakesSearch(session)
        let maxHP = try XCTUnwrap(session.player?.snapshot?.publicInfo.stats["hp"])
        effects.shares["b"] = 40.6 / Double(maxHP)
        session.opponentID = try XCTUnwrap(session.wildCandidates.first).id
        session.mode = .automatic
        session.start()
        let view = try XCTUnwrap(session.battle?.view, "the battle started")
        XCTAssertEqual([view.p1.hp, view.p1.maxhp], [41, maxHP], "40.6 HP rounds to 41")
        XCTAssertEqual([view.p2.hp, view.p2.maxhp], [100, 100], "the opponent starts full")
        XCTAssertEqual(session.battle?.messages.first, stakesOpening)
        session.skipToResult()
        let config = try XCTUnwrap(session.battle?.result?.inputLog.config)
        XCTAssertEqual(config.p1.hp, 41, "the input log keeps the starting HP")
        XCTAssertNil(config.p2.hp)
    }

    /// A share worth less than half an HP still starts at 1, since the engine refuses 0. A full one sends no HP at all,
    /// so its input log is the one from before starting HP existed.
    func testATinyShareStartsAtOneHPAndAFullOneSendsNoHP() async throws {
        let effects = StakesEffects()
        let session = stakesSession([stakesTackler, stakesPikachu], wild: StakesWildStub(speciesID: 129, moves: ["splash"]),
                                    effects: effects)
        session.playerID = "b"
        await stakesSearch(session)
        let maxHP = try XCTUnwrap(session.player?.snapshot?.publicInfo.stats["hp"])
        session.opponentID = try XCTUnwrap(session.wildCandidates.first).id
        session.mode = .automatic
        effects.shares["b"] = 0.4 / Double(maxHP)
        session.start()
        XCTAssertEqual(session.battle?.view?.p1.hp, 1, "0.4 HP starts at 1 instead of being refused as 0")
        session.skipToResult()
        XCTAssertEqual(session.battle?.result?.inputLog.config.p1.hp, 1)
        effects.shares["b"] = 1
        session.start()
        XCTAssertEqual(session.battle?.view?.p1.hp, maxHP)
        session.skipToResult()
        let result = try XCTUnwrap(session.battle?.result, "a full start is a valid battle")
        XCTAssertNil(result.inputLog.config.p1.hp, "full HP sends none")
    }

    /// Sparring starts both sides full whatever HP they have, and still says that nothing changes.
    func testSparringStartsBothSidesFullWhateverTheirHP() throws {
        let effects = StakesEffects()
        effects.shares = ["b": 0.5, "p": 0]
        let session = stakesSession([stakesTackler, stakesPikachu], wild: StakesWildStub(speciesID: 129, moves: ["splash"]),
                                    effects: effects)
        session.playerID = "b"
        session.opponentID = "p"
        session.mode = .automatic
        session.start()
        let view = try XCTUnwrap(session.battle?.view, "the battle started")
        XCTAssertEqual(view.p1.hp, view.p1.maxhp, "sparring starts full")
        XCTAssertEqual([view.p2.hp, view.p2.maxhp], [100, 100])
        XCTAssertEqual(session.battle?.messages.first, stakesSparringOpening)
        session.skipToResult()
        let config = try XCTUnwrap(session.battle?.result?.inputLog.config)
        XCTAssertNil(config.p1.hp); XCTAssertNil(config.p2.hp)
    }
}

/// A battle's first log line: only sparring (or a session without the save) promises that nothing changes.
private let stakesSparringOpening = "연습전을 시작합니다. 성장과 보유 상태는 바뀌지 않습니다."
private let stakesOpening = "연습전을 시작합니다. 깎인 체력은 배틀이 끝나도 남습니다."

// MARK: The save on disk

/// Practice reaches the save only through `PracticeBattleEffects`. A real store under a real battle with stakes must
/// change exactly the battle's HP entry and the growth of the current Pokémon in the saved JSON, nothing else.
@MainActor
final class PracticeStakesFileTests: XCTestCase {
    private func json(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
    /// The save without what a battle with stakes may change: the HP entries and the current Pokémon's growth.
    private func withoutStakes(_ save: [String: Any]) throws -> String {
        var save = save
        save["battleHealth"] = nil
        var active = try XCTUnwrap(save["active"] as? [String: Any])
        active["usedAtStage"] = nil
        var profile = try XCTUnwrap(active["profile"] as? [String: Any])
        profile["growthTokens"] = nil; profile["level"] = nil
        active["profile"] = profile
        save["active"] = active
        return String(decoding: try JSONSerialization.data(withJSONObject: save, options: [.sortedKeys]), as: UTF8.self)
    }

    func testABattleWithStakesChangesOnlyTheHPEntryAndTheGrowthInTheSave() async throws {
        let folder = try stakesFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let saveURL = folder.appendingPathComponent("companion-state.json")
        var state = stakesState([stakesMagikarp])
        state.installBaselineSet = true; state.usedSinceInstall = 3_000_000_000; state.spentTokens = 200_000_000
        state.lastDate = "d1"; state.inventory = ["potion": 2, "mint": 1]
        state.active = MonState(baseID: 25, pathIDs: [25], stageIndex: 0, usedAtStage: 10_000_000, rarity: .common,
                                totalForms: 1, nature: .hardy,
                                profile: stakesProfile("pika", moves: ["thunderbolt"], ability: "static"))
        try JSONEncoder().encode(state).write(to: saveURL)
        let store = CompanionStore(provider: StakesLineProvider(), clock: { stakesNow }, fileURL: saveURL,
                                   rng: StakesRNG(state: 3), dittoDisguiseRollingEnabled: false)
        let before = try json(saveURL)
        let session = PracticeSession(
            engineURL: stakesEngineURL, clock: { 0 }, drivesAutomatically: false,
            wildSource: PracticeWildSource(provider: StakesWildStub(speciesID: 129, moves: ["quick-attack"]),
                                           details: StakesWildStub(speciesID: 129, moves: ["quick-attack"])),
            wildSeed: { 11 }, recordStore: PracticeRecordStore(fileURL: folder.appendingPathComponent("practice-records.json")),
            now: { stakesNow }, calendar: stakesUTC, effects: store)
        session.prepare(state: store.state, activeName: nil)
        XCTAssertEqual(session.playerID, "pika", "the current Pokémon fights")
        await stakesSearch(session)
        stakesFight(session, against: try XCTUnwrap(session.wildCandidates.first).id)
        XCTAssertEqual(session.battle?.result?.winner, "p1")
        let share = try XCTUnwrap(session.lastStakes?.healthShare)
        XCTAssertLessThan(share, 1, "Quick Attack hit first")

        let after = try json(saveURL)
        XCTAssertEqual(after["battleHealth"] as? [String: Double], ["pika": share], "the battle's HP entry, and only it")
        XCTAssertEqual((before["battleHealth"] as? [String: Double]) ?? [:], [:])
        let usedBefore = try XCTUnwrap((before["active"] as? [String: Any])?["usedAtStage"] as? Int)
        let usedAfter = try XCTUnwrap((after["active"] as? [String: Any])?["usedAtStage"] as? Int)
        XCTAssertEqual(usedAfter, usedBefore + PracticeStakes.winXP, "the win's XP, once")
        XCTAssertEqual(try withoutStakes(after), try withoutStakes(before), "nothing else in the save changed")
    }
}
