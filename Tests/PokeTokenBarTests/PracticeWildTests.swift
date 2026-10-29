import XCTest
@testable import PokeTokenBar

// MARK: Stub data (no network; legal app data so `BattleSnapshot.make` succeeds)

private func tree(_ id: Int, _ children: [EvoNode] = []) -> EvoNode { EvoNode(speciesID: id, children: children) }
private func ids(_ node: EvoNode) -> [Int] { [node.speciesID] + node.children.flatMap(ids) }
/// `ko` names only for the listed species, so the English-only fallback stays reachable.
private func evoLine(_ root: EvoNode, _ rarity: Rarity, ko: [Int: String] = [:]) -> EvoLine {
    var names: [Int: [String: String]] = [:]
    for id in ids(root) {
        names[id] = ["en": "EN\(id)"]
        if let name = ko[id] { names[id]?["ko"] = name }
    }
    return EvoLine(baseID: root.speciesID, tree: root, rarity: rarity, names: names)
}

private let grassMoves: [(String, Int)] = [
    ("tackle", 1), ("growl", 3), ("leech-seed", 7), ("vine-whip", 9), ("poison-powder", 13), ("sleep-powder", 13),
    ("take-down", 15), ("razor-leaf", 19), ("sweet-scent", 21), ("growth", 25), ("double-edge", 27),
    ("worry-seed", 31), ("synthesis", 33), ("seed-bomb", 37),
]
private let genericMoves: [(String, Int)] = [
    ("tackle", 1), ("growl", 3), ("quick-attack", 9), ("bite", 15), ("swift", 21), ("slam", 27),
    ("double-edge", 33), ("hyper-beam", 45), ("giga-impact", 60),
]
private func learnset(_ speciesID: Int) -> [(String, Int)] { [1, 2, 3].contains(speciesID) ? grassMoves : genericMoves }
/// The last four level-up moves learned at or below `level`, ties by name: the app's automatic moveset.
private func expectedMoves(_ speciesID: Int, level: Int) -> [String] {
    Array(learnset(speciesID).filter { $0.1 <= level }
        .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0 < $1.0 }.map(\.0).suffix(4))
}
private func details(_ id: Int) -> PokemonDetails {
    PokemonDetails(
        speciesID: id, name: "species-\(id)", height: 10, weight: 100, baseExperience: 64,
        genderRate: [100, 101].contains(id) ? -1 : 1, types: ["normal"],
        baseStats: ["hp": 45, "attack": 49, "defense": 49, "special-attack": 65, "special-defense": 65, "speed": 45],
        abilities: [PokemonAbilityOption(name: "overgrow", slot: 1, isHidden: false),
                    PokemonAbilityOption(name: "chlorophyll", slot: 3, isHidden: true)],
        moves: learnset(id).map { PokemonMoveOption(name: $0.0, learnMethods: [PokemonMoveLearnMethod(method: "level-up", level: $0.1)]) })
}

private struct StubFailure: Error {}

/// A clock the stub advances on every request, so a test can spend the search budget without waiting.
private final class FakeClock: @unchecked Sendable { nonisolated(unsafe) var now: TimeInterval = 0 }

/// PokéAPI stand-in: lines by base id, an index, and switches for each way the real client fails offline.
private final class WildStub: PokeProviding, PokemonDetailProviding, @unchecked Sendable {
    let lines: [Int: EvoLine]
    let captureRates: [Int: Int]
    nonisolated(unsafe) var failIndex = false
    nonisolated(unsafe) var failLines = false
    nonisolated(unsafe) var failingDetails: Set<Int> = []
    nonisolated(unsafe) var failAllDetails = false
    nonisolated(unsafe) private(set) var lineCalls = 0
    /// Every `line`/`pokemonDetails` request advances `clock` by `secondsPerRequest`.
    nonisolated(unsafe) var clock: FakeClock?
    nonisolated(unsafe) var secondsPerRequest: TimeInterval = 0
    nonisolated(unsafe) var cancelInLine = false
    nonisolated(unsafe) var cancelInDetails = false
    init(lines: [Int: EvoLine], captureRates: [Int: Int]) { self.lines = lines; self.captureRates = captureRates }

    func line(baseSpeciesID: Int) async throws -> EvoLine {
        lineCalls += 1
        clock?.now += secondsPerRequest
        if cancelInLine { throw CancellationError() }
        if failLines { throw StubFailure() }
        guard let value = lines[baseSpeciesID] else { throw StubFailure() }
        return value
    }
    func baseSpeciesIndex() async throws -> [BaseSpecies] {
        if failIndex { throw StubFailure() }
        return captureRates.keys.sorted().map { BaseSpecies(id: $0, captureRate: captureRates[$0]!) }
    }
    func baseSpecies(id: Int) async throws -> BaseSpecies? { try await baseSpeciesIndex().first { $0.id == id } }
    func pokemonDetails(speciesID: Int) async throws -> PokemonDetails {
        clock?.now += secondsPerRequest
        if cancelInDetails { throw CancellationError() }
        if failAllDetails || failingDetails.contains(speciesID) { throw StubFailure() }
        return details(speciesID)
    }

    /// Bulbasaur, Charmander and Squirtle lines (3 forms), Eevee (branching, 2 forms), Voltorb (2 forms).
    static func standard() -> WildStub {
        let all: [Int: EvoLine] = [
            1: evoLine(tree(1, [tree(2, [tree(3)])]), .uncommon, ko: [1: "이상해씨", 2: "이상해풀", 3: "이상해꽃"]),
            4: evoLine(tree(4, [tree(5, [tree(6)])]), .uncommon, ko: [4: "파이리", 5: "리자드", 6: "리자몽"]),
            7: evoLine(tree(7, [tree(8, [tree(9)])]), .uncommon, ko: [7: "꼬부기", 8: "어니부기", 9: "거북왕"]),
            133: evoLine(tree(133, [tree(134), tree(135), tree(196)]), .rare, ko: [133: "이브이", 134: "샤미드", 135: "쥬피썬더"]),
            100: evoLine(tree(100, [tree(101)]), .common, ko: [100: "찌리리공", 101: "붐볼"]),
        ]
        return WildStub(lines: all, captureRates: [1: 45, 4: 45, 7: 45, 133: 45, 100: 190])
    }
    /// Only the three-stage Bulbasaur line.
    static func bulbasaurOnly() -> WildStub {
        let all = [1: evoLine(tree(1, [tree(2, [tree(3)])]), .uncommon, ko: [1: "이상해씨", 2: "이상해풀", 3: "이상해꽃"])]
        return WildStub(lines: all, captureRates: [1: 45])
    }
    /// Burmy 412 -> Wormadam 413 / Mothim 414: a line with forms and a branch.
    static func burmyOnly() -> WildStub {
        WildStub(lines: [412: evoLine(tree(412, [tree(413), tree(414)]), .common)], captureRates: [412: 120])
    }
}

/// An index request held open until `resume()`, so a player change can land while a search is awaiting.
private actor GatedProvider: PokeProviding, PokemonDetailProviding {
    private let inner: WildStub
    private var continuation: CheckedContinuation<Void, Never>?
    init(_ inner: WildStub) { self.inner = inner }
    func line(baseSpeciesID: Int) async throws -> EvoLine { try await inner.line(baseSpeciesID: baseSpeciesID) }
    func baseSpeciesIndex() async throws -> [BaseSpecies] {
        await withCheckedContinuation { continuation = $0 }
        return try await inner.baseSpeciesIndex()
    }
    func baseSpecies(id: Int) async throws -> BaseSpecies? { try await inner.baseSpecies(id: id) }
    func pokemonDetails(speciesID: Int) async throws -> PokemonDetails { try await inner.pokemonDetails(speciesID: speciesID) }
    func isSuspended() -> Bool { continuation != nil }
    func resume() { continuation?.resume(); continuation = nil }
}

/// Same splitmix64 stream the generator is specified to use, so a test can replay the draw order.
private struct ReplayRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private final class Counter { var value: UInt64 = 0 }

@MainActor
private func waitUntil(timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    return condition()
}

private let engineURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("engine/dist/battle-engine.js")

// MARK: Hatch rule and level/stage rules

@MainActor
final class PracticeWildRulesTests: XCTestCase {
    /// The loop `CompanionStore.chooseBase` ran inline before the extraction, kept here verbatim as the reference.
    private func inlineReference(_ index: [BaseSpecies], collected: Set<Int>, roll: UInt64) -> Int? {
        let weights = index.map { CollectionWeight.adjusted($0.captureRate, isCollected: collected.contains($0.id)) }
        let total = weights.reduce(0, +)
        var r = Int(roll % UInt64(total))
        for (i, w) in weights.enumerated() {
            r -= w
            if r < 0 { return index[i].id }
        }
        return index.last?.id
    }

    func testHatchRuleMatchesTheOldInlineLoopForManyRollsAndWeights() {
        let index = [BaseSpecies(id: 10, captureRate: 255), BaseSpecies(id: 20, captureRate: 45),
                     BaseSpecies(id: 30, captureRate: 3), BaseSpecies(id: 40, captureRate: 1),
                     BaseSpecies(id: 50, captureRate: 120)]
        for collected: Set<Int> in [[], [10], [30, 40], [10, 20, 30, 40, 50]] {
            let weights = index.map { CollectionWeight.adjusted($0.captureRate, isCollected: collected.contains($0.id)) }
            let total = UInt64(weights.reduce(0, +))
            var cumulative: UInt64 = 0
            var rolls: [UInt64] = [0, 1, total - 1, total, total + 1, 2 * total - 1, UInt64.max, UInt64.max - 1]
            for weight in weights {
                cumulative += UInt64(weight)
                rolls += [cumulative - 1, cumulative, cumulative + 1]
            }
            var rng = ReplayRNG(seed: 2024)
            rolls += (0..<400).map { _ in rng.next() }
            for roll in rolls {
                XCTAssertEqual(HatchRule.pickBase(from: index, isCollected: { collected.contains($0) }, roll: roll),
                               inlineReference(index, collected: collected, roll: roll), "roll \(roll) collected \(collected)")
            }
        }
    }

    func testHatchRuleBoundariesAndCollectedHalving() {
        let index = [BaseSpecies(id: 1, captureRate: 255), BaseSpecies(id: 2, captureRate: 3), BaseSpecies(id: 3, captureRate: 1)]
        // Nothing collected: weights 255 / 3 / 1.
        XCTAssertEqual(HatchRule.pickBase(from: index, isCollected: { _ in false }, roll: 254), 1)
        XCTAssertEqual(HatchRule.pickBase(from: index, isCollected: { _ in false }, roll: 255), 2)
        XCTAssertEqual(HatchRule.pickBase(from: index, isCollected: { _ in false }, roll: 257), 2)
        XCTAssertEqual(HatchRule.pickBase(from: index, isCollected: { _ in false }, roll: 258), 3)
        XCTAssertEqual(HatchRule.pickBase(from: index, isCollected: { _ in false }, roll: 259), 1, "roll wraps at the total")
        // Species 1 collected: 127 (halved, rounded down) / 3 / 1. A collected weight never drops below 1.
        XCTAssertEqual(HatchRule.pickBase(from: index, isCollected: { $0 == 1 }, roll: 126), 1)
        XCTAssertEqual(HatchRule.pickBase(from: index, isCollected: { $0 == 1 }, roll: 127), 2)
        XCTAssertEqual(HatchRule.pickBase(from: index, isCollected: { $0 == 1 }, roll: 130), 3)
        XCTAssertEqual(HatchRule.pickBase(from: index, isCollected: { $0 == 3 }, roll: 258), 3, "weight 1 stays 1 when collected")
        XCTAssertEqual(HatchRule.pickBase(from: [BaseSpecies(id: 9, captureRate: 7)], isCollected: { _ in false }, roll: 12345), 9)
        XCTAssertNil(HatchRule.pickBase(from: [], isCollected: { _ in false }, roll: 5))
    }

    func testLevelStaysWithinThreeOfThePlayerAndWithinTheAppRange() {
        for roll in 0..<7 {
            XCTAssertEqual(PracticeWildRules.level(around: 50, roll: UInt64(roll)), 47 + roll)
        }
        XCTAssertEqual(PracticeWildRules.level(around: 50, roll: 7), 47, "the offset is roll % 7")
        XCTAssertEqual(PracticeWildRules.level(around: 50, roll: UInt64.max), 50 + Int(UInt64.max % 7) - 3)
        for player in [5, 6, 7, 8, 97, 98, 99, 100] {
            for roll in 0..<7 {
                let level = PracticeWildRules.level(around: player, roll: UInt64(roll))
                XCTAssertGreaterThanOrEqual(level, 5)
                XCTAssertLessThanOrEqual(level, 100)
                XCTAssertEqual(level, min(100, max(5, player + roll - 3)), "player \(player) roll \(roll)")
            }
        }
        XCTAssertEqual(PracticeWildRules.level(around: 5, roll: 0), 5)
        XCTAssertEqual(PracticeWildRules.level(around: 100, roll: 6), 100)
    }

    // MARK: stageIndex oracle

    /// The lowest earned growth at which the app's own `advanceGrowth` reports `level`.
    private func lowestGrowth(reaching level: Int, rarity: Rarity) -> Int {
        var low = 0, high = PokemonBalance.graduationTotal(rarity)
        while low < high {
            let mid = (low + high) / 2
            var profile = PokemonProfile.generate(seed: 1, instanceID: "oracle")
            profile.advanceGrowth(to: mid, rarity: rarity)
            if profile.level >= level { high = mid } else { low = mid + 1 }
        }
        return low
    }
    /// The stage the app's evolution loop has reached after `growth` standard tokens: it evolves into stage `s`
    /// once the thresholds of the stages before it are paid (`reconstructedGrowthTokens` sums them).
    private func appStage(growth: Int, rarity: Rarity, forms: Int) -> Int {
        var stage = 0
        for s in 1..<max(1, forms) {
            let needed = CompanionStore.reconstructedGrowthTokens(rarity: rarity, totalForms: forms, completedStages: s, currentStageUsage: 0)
            if growth >= needed { stage = s }
        }
        return stage
    }

    /// Rule: the stage the app's own Pokémon is in at the lowest growth that reaches the level. Checked against
    /// `advanceGrowth` (level) and `phaseThreshold` (stage costs) for every level, rarity and line length 1...6.
    func testStageIndexInvertsTheAppsGrowthForEveryLevelRarityAndLineLength() {
        for rarity in [Rarity.common, .uncommon, .rare, .legendary] {
            for level in 5...100 {
                let growth = lowestGrowth(reaching: level, rarity: rarity)
                for forms in 1...6 {
                    XCTAssertEqual(PracticeWildRules.stageIndex(level: level, totalForms: forms),
                                   appStage(growth: growth, rarity: rarity, forms: forms),
                                   "\(rarity) forms \(forms) level \(level) growth \(growth)")
                }
            }
        }
    }

    /// Each stage change is pinned from the app's side: the first level of a stage is reached no earlier than the
    /// previous stages are paid for, and the level before it is reached while the previous stage is still running.
    func testStageBoundariesAreTheLevelsWhereTheAppEvolves() {
        for forms in 2...5 {
            for stage in 1..<forms {
                let paid = CompanionStore.reconstructedGrowthTokens(rarity: .common, totalForms: forms, completedStages: stage, currentStageUsage: 0)
                let first = (5...100).first { PracticeWildRules.stageIndex(level: $0, totalForms: forms) == stage }
                XCTAssertNotNil(first, "forms \(forms) stage \(stage) is reachable")
                guard let first else { continue }
                XCTAssertGreaterThanOrEqual(lowestGrowth(reaching: first, rarity: .common), paid, "forms \(forms) stage \(stage)")
                XCTAssertLessThan(lowestGrowth(reaching: first - 1, rarity: .common), paid, "forms \(forms) stage \(stage)")
                XCTAssertEqual(PracticeWildRules.stageIndex(level: first - 1, totalForms: forms), stage - 1, "forms \(forms) stage \(stage)")
            }
        }
        // Pinned values (common/any rarity): two forms switch at Lv.37, three at Lv.21 and Lv.53.
        XCTAssertEqual((5...100).filter { PracticeWildRules.stageIndex(level: $0, totalForms: 2) == 0 }.last, 36)
        XCTAssertEqual((5...100).first { PracticeWildRules.stageIndex(level: $0, totalForms: 3) == 1 }, 21)
        XCTAssertEqual((5...100).first { PracticeWildRules.stageIndex(level: $0, totalForms: 3) == 2 }, 53)
        // Exact tie: five forms reach stage 2 at 1/5 of the growth, and Lv.24 needs exactly 1/5 of it.
        XCTAssertEqual(PracticeWildRules.stageIndex(level: 23, totalForms: 5), 1)
        XCTAssertEqual(PracticeWildRules.stageIndex(level: 24, totalForms: 5), 2)
        XCTAssertEqual(PracticeWildRules.stageIndex(level: 5, totalForms: 1), 0)
        XCTAssertEqual(PracticeWildRules.stageIndex(level: 100, totalForms: 1), 0)
        XCTAssertEqual(PracticeWildRules.stageIndex(level: 100, totalForms: 3), 2, "the app graduates from the last stage")
        XCTAssertEqual(PracticeWildRules.stageIndex(level: 5, totalForms: 3), 0)
        XCTAssertEqual(PracticeWildRules.stageIndex(level: 5, totalForms: 0), 0, "a degenerate line count is one form")
    }
}

// MARK: Store-driven stage oracle (the app's own evolution loop)

private struct GrowthLineProvider: PokeProviding, PokemonDetailProviding {
    var forms: Int
    func line(baseSpeciesID: Int) async throws -> EvoLine {
        var node = EvoNode(speciesID: forms, children: [])
        if forms > 1 { for id in (1..<forms).reversed() { node = EvoNode(speciesID: id, children: [node]) } }
        return EvoLine(baseID: 1, tree: node, rarity: .common,
                       names: Dictionary(uniqueKeysWithValues: (1...forms).map { ($0, ["en": "P\($0)"]) }))
    }
    func baseSpeciesIndex() async throws -> [BaseSpecies] { [] }
    func baseSpecies(id: Int) async throws -> BaseSpecies? { nil }
    func pokemonDetails(speciesID: Int) async throws -> PokemonDetails {
        PokemonDetails(speciesID: speciesID, name: "p", height: 1, weight: 1, baseExperience: nil, genderRate: -1,
                       types: [], baseStats: [:], abilities: [], moves: [])
    }
}

@MainActor
final class PracticeWildStoreOracleTests: XCTestCase {
    nonisolated(unsafe) private var paths: [URL] = []
    nonisolated(unsafe) private var suites: [String] = []
    override func tearDown() {
        for path in paths { try? FileManager.default.removeItem(at: path) }
        for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
        super.tearDown()
    }
    private func store(forms: Int) throws -> CompanionStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wild-oracle-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        paths.append(dir)
        let file = dir.appendingPathComponent("state.json")
        try JSONEncoder().encode(CompanionState()).write(to: file)
        let suite = "wild-oracle-\(UUID())"
        suites.append(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return CompanionStore(provider: GrowthLineProvider(forms: forms), fileURL: file,
                              dittoDisguiseRollingEnabled: false, defaults: defaults)
    }
    private func lowestGrowth(reaching level: Int) -> Int {
        var low = 0, high = PokemonBalance.graduationTotal(.common)
        while low < high {
            let mid = (low + high) / 2
            var profile = PokemonProfile.generate(seed: 1, instanceID: "oracle")
            profile.advanceGrowth(to: mid, rarity: .common)
            if profile.level >= level { high = mid } else { low = mid + 1 }
        }
        return low
    }

    /// A real hatched Pokémon fed the lowest growth that reaches a level (plus one token) shows the level and stage
    /// `stageIndex` predicts; a graduate counts as its last stage at Lv.100. The extra token is needed because the
    /// store rebuilds growth through a Double fraction (`reconcileActiveProfileGrowth`) that can come out one token
    /// short, so feeding the exact minimum can show the level before.
    func testHatchedPokemonFedTheLowestGrowthOfALevelIsAtThePredictedStage() async throws {
        for forms in 1...3 {
            for level in 5...100 {
                let s = try store(forms: forms)
                await s.hatch(baseID: 1)
                s.applyUsage(lowestGrowth(reaching: level) + 1)
                let stage: Int, shown: Int
                if let active = s.state.active {
                    stage = active.stageIndex; shown = try XCTUnwrap(active.profile?.level)
                } else {
                    stage = forms - 1; shown = try XCTUnwrap(s.state.dex.last?.profile?.level)
                }
                XCTAssertEqual(shown, level, "forms \(forms)")
                XCTAssertEqual(PracticeWildRules.stageIndex(level: level, totalForms: forms), stage, "forms \(forms) level \(level)")
            }
        }
    }
}

// MARK: Generator

@MainActor
final class PracticeWildGeneratorTests: XCTestCase {
    private func engine() throws -> BattleEngine { try BattleEngine(url: engineURL) }
    private func generator(_ stub: WildStub) throws -> PracticeWildGenerator {
        PracticeWildGenerator(source: PracticeWildSource(provider: stub, details: stub), engine: try engine())
    }
    private func set(_ candidate: PracticeCandidate) throws -> BattleSet { try XCTUnwrap(candidate.snapshot).set }
    /// Path length of the stub line that contains `speciesID`, along the path that reaches it.
    private func formsOf(_ speciesID: Int, in stub: WildStub) -> Int {
        for line in stub.lines.values {
            func depth(_ node: EvoNode, _ d: Int) -> Int? {
                if node.speciesID == speciesID { return d }
                for child in node.children { if let hit = depth(child, d + 1) { return hit } }
                return nil
            }
            if depth(line.tree, 1) != nil { return line.tree.depth }
        }
        return 1
    }

    func testSameSeedGivesTheSameCandidatesAndAnotherSeedDoesNot() async throws {
        let stub = WildStub.standard()
        let first = try await generator(stub).make(count: 3, around: 50, seed: 77)
        let second = try await generator(stub).make(count: 3, around: 50, seed: 77)
        XCTAssertEqual(first.count, 3)
        XCTAssertEqual(first.map(\.id), second.map(\.id))
        XCTAssertEqual(first.map(\.name), second.map(\.name))
        XCTAssertEqual(first.map(\.snapshot), second.map(\.snapshot))
        XCTAssertEqual(first.map(\.origin), second.map(\.origin))
        let other = try await generator(stub).make(count: 3, around: 50, seed: 78)
        XCTAssertNotEqual(first.map(\.snapshot), other.map(\.snapshot))
    }

    func testLevelsStayWithinThreeOfThePlayerAndWithinTheAppRange() async throws {
        let stub = WildStub.standard()
        for player in [5, 6, 30, 50, 97, 100] {
            for seed: UInt64 in 1...6 {
                let made = try await generator(stub).make(count: 3, around: player, seed: seed)
                XCTAssertFalse(made.isEmpty)
                for candidate in made {
                    let level = try set(candidate).level
                    XCTAssertGreaterThanOrEqual(level, max(5, player - 3), "player \(player) seed \(seed)")
                    XCTAssertLessThanOrEqual(level, min(100, player + 3), "player \(player) seed \(seed)")
                    XCTAssertEqual(try XCTUnwrap(candidate.snapshot).publicInfo.level, level)
                }
            }
        }
    }

    func testEvolutionStageFollowsTheLevelRuleAndSpeciesAreUnique() async throws {
        let stub = WildStub.standard()
        for player in [5, 30, 50, 100] {
            for seed: UInt64 in 10...15 {
                let made = try await generator(stub).make(count: 3, around: player, seed: seed)
                XCTAssertFalse(made.isEmpty, "player \(player) seed \(seed)")
                let species = try made.map { try set($0).speciesNum }
                XCTAssertEqual(Set(species).count, species.count, "duplicates skipped (player \(player) seed \(seed))")
                for candidate in made {
                    let battleSet = try set(candidate)
                    let forms = formsOf(battleSet.speciesNum, in: stub)
                    let stage = PracticeWildRules.stageIndex(level: battleSet.level, totalForms: forms)
                    // Stage 0 is the base species; deeper stages sit that many steps down the line.
                    let depth = stub.lines.values.compactMap { line -> Int? in
                        func find(_ node: EvoNode, _ d: Int) -> Int? {
                            if node.speciesID == battleSet.speciesNum { return d }
                            for child in node.children { if let hit = find(child, d + 1) { return hit } }
                            return nil
                        }
                        return find(line.tree, 0)
                    }.first
                    XCTAssertEqual(depth, stage, "species \(battleSet.speciesNum) level \(battleSet.level) forms \(forms)")
                }
            }
        }
    }

    func testStagesAtKnownLevelsOnTheThreeFormLine() async throws {
        let stub = WildStub.bulbasaurOnly()
        // 3 forms: Lv.5-20 base, 21-52 middle, 53-100 final. One line, so duplicates leave a single candidate.
        for (player, expected) in [(8, 1), (30, 2), (90, 3), (100, 3)] {
            let made = try await generator(stub).make(count: 3, around: player, seed: 5)
            XCTAssertEqual(made.count, 1)
            XCTAssertEqual(try made.first.map { try set($0).speciesNum }, expected, "player \(player)")
        }
    }

    func testMovesAreTheLastFourLevelUpMovesAtOrBelowTheLevel() async throws {
        let stub = WildStub.standard()
        for player in [5, 12, 30, 60, 100] {
            let made = try await generator(stub).make(count: 3, around: player, seed: UInt64(player))
            XCTAssertFalse(made.isEmpty)
            for candidate in made {
                let battleSet = try set(candidate)
                XCTAssertEqual(battleSet.moves, expectedMoves(battleSet.speciesNum, level: battleSet.level),
                               "species \(battleSet.speciesNum) level \(battleSet.level)")
                XCTAssertTrue(["overgrow", "chlorophyll"].contains(battleSet.ability))
                XCTAssertNotNil(PokemonNature(rawValue: battleSet.nature))
            }
        }
    }

    func testIdentityNameAndOriginComeFromTheLineAndTheRoll() async throws {
        let stub = WildStub.standard()
        let made = try await generator(stub).make(count: 3, around: 50, seed: 424242)
        XCTAssertEqual(made.count, 3)
        for (index, candidate) in made.enumerated() {
            XCTAssertEqual(candidate.id, "wild-424242-\(index)")
            XCTAssertEqual(candidate.snapshot?.instanceID, candidate.id)
            XCTAssertNil(candidate.blockedReason)
            let battleSet = try set(candidate)
            let line = try XCTUnwrap(stub.lines.values.first { ids($0.tree).contains(battleSet.speciesNum) })
            XCTAssertEqual(candidate.name, line.names[battleSet.speciesNum]?["ko"])
            XCTAssertEqual(candidate.origin, .wild(rarity: line.rarity, shiny: battleSet.shiny))
        }
    }

    func testNameFallsBackToTheSnapshotSpeciesWithoutAKoreanName() async throws {
        let stub = WildStub(lines: [1: evoLine(tree(1, [tree(2, [tree(3)])]), .common)], captureRates: [1: 45])
        let made = try await generator(stub).make(count: 1, around: 8, seed: 3)
        let candidate = try XCTUnwrap(made.first)
        XCTAssertEqual(candidate.name, candidate.snapshot?.publicInfo.species)
        XCTAssertFalse(candidate.name.isEmpty)
    }

    /// Pins the draw order: base, level, branch choices (one per evolving node), form, shiny, nature, profile seed.
    func testDrawOrderIsBaseLevelBranchShinyNatureProfileSeed() async throws {
        let seed: UInt64 = 987_654
        let made = try await generator(WildStub.bulbasaurOnly()).make(count: 1, around: 50, seed: seed)
        let battleSet = try set(try XCTUnwrap(made.first))
        var rng = ReplayRNG(seed: seed)
        _ = rng.next()                                       // base (a single-species index)
        let level = PracticeWildRules.level(around: 50, roll: rng.next())
        _ = rng.next(); _ = rng.next()                       // two evolving nodes, one choice each; Bulbasaur has no forms
        let shiny = CompanionStore.rollsShiny(roll: rng.next(), charmOwned: false)
        let nature = PokemonNature.allCases[Int(rng.next() % UInt64(PokemonNature.allCases.count))]
        let profile = PokemonProfile.generate(seed: rng.next(), instanceID: "replay")
        XCTAssertEqual(battleSet.level, level)
        XCTAssertEqual(battleSet.shiny, shiny)
        XCTAssertEqual(battleSet.nature, nature.rawValue)
        XCTAssertEqual(battleSet.ivs["hp"], profile.ivs.hp)
        XCTAssertEqual(battleSet.ivs["speed"], profile.ivs.speed)
        XCTAssertEqual(battleSet.ivs["special-attack"], profile.ivs.specialAttack)
    }

    func testLineWithFormsRollsTheFormAfterTheBranchAndResolvesItPerSpecies() async throws {
        let seed: UInt64 = 31
        let made = try await generator(WildStub.burmyOnly()).make(count: 1, around: 50, seed: seed)
        let battleSet = try set(try XCTUnwrap(made.first))
        var rng = ReplayRNG(seed: seed)
        _ = rng.next()                                        // base
        _ = rng.next()                                        // level
        let child = [413, 414][Int(rng.next() % 2)]           // Burmy branches into Wormadam or Mothim (stage 1 at Lv.47...53)
        let form = PokemonForm.roll(rng.next(), among: PokemonForm.lineForms(baseID: 412), collected: [])
        XCTAssertEqual(battleSet.speciesNum, child)
        XCTAssertEqual(battleSet.form, PokemonForm.resolved(speciesID: child, form: form)?.rawValue)
        if child == 414 { XCTAssertNil(battleSet.form, "Mothim has a single appearance") }
        else { XCTAssertNotNil(battleSet.form) }
    }

    func testOfflineLineFallsBackToTheBaseSpeciesWhenItsDetailsLoad() async throws {
        let stub = WildStub.standard()
        stub.failLines = true
        let made = try await generator(stub).make(count: 3, around: 80, seed: 9)
        XCTAssertEqual(made.count, 3)
        for candidate in made {
            let battleSet = try set(candidate)
            XCTAssertTrue(stub.captureRates.keys.contains(battleSet.speciesNum), "only base species without a line: \(battleSet.speciesNum)")
            XCTAssertEqual(candidate.name, candidate.snapshot?.publicInfo.species)
            guard case .wild(let rarity, _) = candidate.origin else { XCTFail("origin"); continue }
            XCTAssertEqual(rarity, Rarity.from(captureRate: stub.captureRates[battleSet.speciesNum]!, isLegendary: false, isMythical: false),
                           "rarity from the index capture rate")
            XCTAssertEqual(battleSet.moves, expectedMoves(battleSet.speciesNum, level: battleSet.level))
        }
    }

    func testCandidatesWhoseDetailsFailAreSkipped() async throws {
        let stub = WildStub.standard()
        stub.failingDetails = [1, 2, 3, 4, 5, 6]
        for seed: UInt64 in 1...5 {
            let made = try await generator(stub).make(count: 3, around: 50, seed: seed)
            XCTAssertFalse(made.isEmpty, "seed \(seed)")
            for candidate in made { XCTAssertFalse([1, 2, 3, 4, 5, 6].contains(try set(candidate).speciesNum)) }
        }
    }

    func testThrowsWhenNothingCanBeMade() async throws {
        func expectThrow(_ stub: WildStub, _ label: String) async throws {
            do {
                let made = try await generator(stub).make(count: 3, around: 50, seed: 1)
                XCTFail("\(label): expected a throw, got \(made.count) candidates")
            } catch {}
        }
        let noIndex = WildStub.standard(); noIndex.failIndex = true
        try await expectThrow(noIndex, "index unavailable")
        let noDetails = WildStub.standard(); noDetails.failAllDetails = true
        try await expectThrow(noDetails, "no details")
        try await expectThrow(WildStub(lines: [:], captureRates: [:]), "empty index")
    }

    func testStopsAfterCountTimesFourAttemptsWhenSpeciesKeepRepeating() async throws {
        let stub = WildStub.bulbasaurOnly()
        let made = try await generator(stub).make(count: 3, around: 30, seed: 8)
        XCTAssertEqual(made.count, 1, "a single line gives a single species")
        XCTAssertEqual(stub.lineCalls, 12, "count x 4 attempts, no more")
    }

    private func timed(_ stub: WildStub, budget: TimeInterval, clock: FakeClock) throws -> PracticeWildGenerator {
        PracticeWildGenerator(source: PracticeWildSource(provider: stub, details: stub), engine: try engine(),
                              clock: { clock.now }, budget: budget)
    }

    func testSpentBudgetStartsNoNewAttemptAndReturnsWhatWasMade() async throws {
        // 11 s per request, 2 requests per attempt: one attempt takes 22 s and the 20 s budget is gone.
        let clock = FakeClock(), stub = WildStub.standard()
        stub.clock = clock; stub.secondsPerRequest = 11
        let made = try await timed(stub, budget: 20, clock: clock).make(count: 3, around: 50, seed: 5)
        XCTAssertEqual(made.count, 1)
        XCTAssertEqual(stub.lineCalls, 1, "no second attempt after the budget is spent")
        // Control: the same slow stub with a generous budget still fills the batch.
        let slowClock = FakeClock(), generous = WildStub.standard()
        generous.clock = slowClock; generous.secondsPerRequest = 11
        let full = try await timed(generous, budget: 100_000, clock: slowClock).make(count: 3, around: 50, seed: 5)
        XCTAssertEqual(full.count, 3)
    }

    func testSpentBudgetWithNothingMadeThrowsInsteadOfRetryingTwelveTimes() async throws {
        let clock = FakeClock(), stub = WildStub.standard()
        stub.clock = clock; stub.secondsPerRequest = 11; stub.failAllDetails = true
        do {
            let made = try await timed(stub, budget: 20, clock: clock).make(count: 3, around: 50, seed: 5)
            XCTFail("expected a throw, got \(made.count) candidates")
        } catch {
            XCTAssertEqual(error as? PracticeWildError, .noCandidates)
        }
        XCTAssertEqual(stub.lineCalls, 1)
        // Control: without time passing, all twelve attempts are used.
        let still = FakeClock(), steady = WildStub.standard()
        steady.clock = still; steady.failAllDetails = true
        _ = try? await timed(steady, budget: 20, clock: still).make(count: 3, around: 50, seed: 5)
        XCTAssertEqual(steady.lineCalls, 12)
    }

    func testCancellationInARequestIsRethrownNotSkipped() async throws {
        for inLine in [true, false] {
            let stub = WildStub.standard()
            if inLine { stub.cancelInLine = true } else { stub.cancelInDetails = true }
            do {
                let made = try await generator(stub).make(count: 3, around: 50, seed: 2)
                XCTFail("expected a throw, got \(made.count) candidates")
            } catch {
                XCTAssertTrue(error is CancellationError, "\(inLine ? "line" : "details"): \(error)")
            }
            XCTAssertEqual(stub.lineCalls, 1, "the search stops at the first cancellation")
        }
    }

    func testCountOfZeroMakesNothing() async throws {
        let made = try await generator(WildStub.standard()).make(count: 0, around: 50, seed: 1)
        XCTAssertTrue(made.isEmpty)
    }
}

// MARK: Session

@MainActor
final class PracticeWildSessionTests: XCTestCase {
    private func profile(_ id: String, level: Int = 50) -> PokemonProfile {
        var p = PokemonProfile.generate(seed: 42, instanceID: id)
        p.level = level; p.gender = .male; p.abilityName = "pressure"
        p.moves = [PokemonKnownMove(name: "tackle", learnedAtLevel: 1)]
        return p
    }
    private func state(_ ids: [String] = ["a", "b", "c"], level: Int = 50) -> CompanionState {
        var state = CompanionState()
        state.dex = ids.map {
            DexEntry(baseID: 242, finalID: 242, chainOrder: [242], rarity: .common, caughtAt: nil,
                     nature: .hardy, profile: profile($0, level: level))
        }
        return state
    }
    private func makeSession(_ stub: some PokeProviding & PokemonDetailProviding, seed: @escaping () -> UInt64 = { 11 }) -> PracticeSession {
        PracticeSession(engineURL: engineURL, clock: { 0 }, drivesAutomatically: false,
                        wildSource: PracticeWildSource(provider: stub, details: stub), wildSeed: seed)
    }
    private func search(_ session: PracticeSession) async -> Bool {
        session.findWildOpponents()
        return await waitUntil { session.wildState != .searching }
    }
    /// Waits until the gated provider holds a request, i.e. the search is suspended inside its first await.
    private func waitSuspended(_ gate: GatedProvider) async -> Bool {
        for _ in 0..<2500 {
            if await gate.isSuspended() { return true }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return false
    }
    /// A whole search through the gate: start, let it reach the index request, release it, await its task.
    private func completeSearch(_ session: PracticeSession, _ gate: GatedProvider) async -> Bool {
        session.findWildOpponents()
        guard await waitSuspended(gate) else { return false }
        let task = session.wildTask
        await gate.resume()
        await task?.value
        return session.wildState == .ready
    }
    /// Pikachu with thunderbolt as the player, so an automatic battle against any wild stub finishes.
    private func fastState() -> CompanionState {
        var state = CompanionState()
        state.dex = [("p", 25, "thunderbolt"), ("o", 242, "tackle"), ("c", 242, "tackle")].map { id, species, move in
            var p = profile(id); p.moves = [PokemonKnownMove(name: move, learnedAtLevel: 1)]
            return DexEntry(baseID: species, finalID: species, chainOrder: [species], rarity: .common, caughtAt: nil,
                            nature: .hardy, profile: p)
        }
        return state
    }

    func testFindingWildOpponentsYieldsThreeLevelMatchedCandidates() async throws {
        let session = makeSession(WildStub.standard())
        session.prepare(state: state(), activeName: nil)
        XCTAssertEqual(session.wildState, .idle)
        XCTAssertTrue(session.wildCandidates.isEmpty)
        session.findWildOpponents()
        XCTAssertEqual(session.wildState, .searching)
        let finished = await waitUntil { session.wildState != .searching }
        XCTAssertTrue(finished)
        XCTAssertEqual(session.wildState, .ready)
        XCTAssertEqual(session.wildCandidates.count, 3)
        for candidate in session.wildCandidates {
            let level = try XCTUnwrap(candidate.snapshot).set.level
            XCTAssertGreaterThanOrEqual(level, 47); XCTAssertLessThanOrEqual(level, 53)
            XCTAssertFalse(session.roster?.eligible.contains { $0.id == candidate.id } ?? true)
            guard case .wild = candidate.origin else { XCTFail("origin"); continue }
        }
        XCTAssertEqual(session.wildCandidates.map(\.id), ["wild-11-0", "wild-11-1", "wild-11-2"])
    }

    func testSearchNeedsAPreparedEngineAndAPlayer() async throws {
        let session = makeSession(WildStub.standard())
        session.findWildOpponents()
        XCTAssertEqual(session.wildState, .idle, "no engine yet")
        session.prepare(state: state(["only"]), activeName: nil)
        session.playerID = nil
        session.findWildOpponents()
        XCTAssertEqual(session.wildState, .idle, "no player")
    }

    func testWildOpponentResolvesAndABattleStartsAgainstIt() async throws {
        let session = makeSession(WildStub.standard())
        session.prepare(state: state(), activeName: nil)
        let finished = await search(session)
        XCTAssertTrue(finished)
        let wild = try XCTUnwrap(session.wildCandidates.first)
        session.opponentID = wild.id
        XCTAssertEqual(session.opponent?.id, wild.id)
        XCTAssertEqual(session.opponent?.snapshot, wild.snapshot)
        XCTAssertNotNil(session.matchup, "pairing summary works against a wild opponent")
        session.mode = .manual
        session.start()
        let battle = try XCTUnwrap(session.battle)
        XCTAssertEqual(battle.phase, .running)
        XCTAssertEqual(battle.view?.p2.level, wild.snapshot?.set.level)
        XCTAssertEqual(battle.view?.p2.speciesNum, wild.snapshot?.set.speciesNum)
        XCTAssertEqual(session.player?.id, "a")
    }

    func testRerollReplacesTheCandidatesAndAStaleWildOpponentFallsBack() async throws {
        let counter = Counter()
        let session = makeSession(WildStub.standard(), seed: { counter.value += 1; return counter.value })
        session.prepare(state: state(), activeName: nil)
        var finished = await search(session)
        XCTAssertTrue(finished)
        let firstIDs = session.wildCandidates.map(\.id)
        XCTAssertEqual(firstIDs, ["wild-1-0", "wild-1-1", "wild-1-2"])
        session.opponentID = try XCTUnwrap(firstIDs.first)
        finished = await search(session)
        XCTAssertTrue(finished)
        XCTAssertEqual(session.wildState, .ready)
        let secondIDs = session.wildCandidates.map(\.id)
        XCTAssertEqual(secondIDs, ["wild-2-0", "wild-2-1", "wild-2-2"])
        XCTAssertTrue(Set(firstIDs).isDisjoint(with: secondIDs))
        XCTAssertEqual(session.opponentID, "b", "the replaced wild opponent falls back to the default own opponent")
        XCTAssertNotNil(session.opponent)
    }

    func testChangingThePlayerDropsWildOpponentsAndFallsBack() async throws {
        let session = makeSession(WildStub.standard())
        session.prepare(state: state(), activeName: nil)
        let finished = await search(session)
        XCTAssertTrue(finished)
        session.opponentID = try XCTUnwrap(session.wildCandidates.first).id
        session.playerID = "c"
        XCTAssertEqual(session.wildState, .idle)
        XCTAssertTrue(session.wildCandidates.isEmpty)
        XCTAssertEqual(session.opponentID, "a", "a wild opponent made for the old player is replaced by an own one")
        XCTAssertEqual(session.opponent?.id, "a")
        // An own opponent stays when only the player changes.
        let again = await search(session)
        XCTAssertTrue(again)
        session.opponentID = "b"
        session.playerID = "a"
        XCTAssertEqual(session.opponentID, "b")
        XCTAssertEqual(session.wildState, .idle)
    }

    func testPrepareKeepsASelectedWildOpponentForTheSamePlayer() async throws {
        let session = makeSession(WildStub.standard())
        session.prepare(state: state(), activeName: nil)
        let finished = await search(session)
        XCTAssertTrue(finished)
        let wild = try XCTUnwrap(session.wildCandidates.dropFirst().first).id
        session.opponentID = wild
        session.prepare(state: state(), activeName: nil)
        XCTAssertEqual(session.opponentID, wild)
        XCTAssertEqual(session.wildState, .ready)
    }

    func testASearchInFlightIsDiscardedWhenThePlayerChangesBeforeItLands() async throws {
        let gate = GatedProvider(WildStub.standard())
        let session = makeSession(gate)
        session.prepare(state: state(), activeName: nil)
        session.findWildOpponents()
        XCTAssertEqual(session.wildState, .searching)
        let reached = await waitSuspended(gate)
        XCTAssertTrue(reached, "the search reached the gated index request")
        let stale = session.wildTask
        session.playerID = "c"
        XCTAssertEqual(session.wildState, .idle)
        await gate.resume()
        await stale?.value   // the stale task has finished: nothing is left that could still land
        XCTAssertEqual(session.wildState, .idle, "the stale result must not land on the new player")
        XCTAssertTrue(session.wildCandidates.isEmpty)
    }

    /// A reroll in flight must not turn into a fight with the batch it is about to replace: starting stops the
    /// search and keeps the old batch, so the selection and the engine's opponent stay the same.
    func testStartDuringARerollKeepsTheOldBatchAndTheBattleOpponent() async throws {
        let gate = GatedProvider(WildStub.standard())
        let counter = Counter()
        let session = makeSession(gate, seed: { counter.value += 1; return counter.value })
        session.prepare(state: state(), activeName: nil)
        let first = await completeSearch(session, gate)
        XCTAssertTrue(first)
        let oldIDs = session.wildCandidates.map(\.id)
        XCTAssertEqual(oldIDs.count, 3)
        let wildA = try XCTUnwrap(oldIDs.first)
        session.opponentID = wildA
        session.findWildOpponents()
        XCTAssertEqual(session.wildState, .searching)
        let reached = await waitSuspended(gate)
        XCTAssertTrue(reached)
        let stale = session.wildTask
        session.mode = .manual
        session.start()
        XCTAssertEqual(session.wildState, .ready, "starting stops the search and shows the old batch")
        XCTAssertEqual(session.wildCandidates.map(\.id), oldIDs)
        await gate.resume()
        await stale?.value
        XCTAssertEqual(session.opponentID, wildA, "the late result must not move the selection")
        XCTAssertEqual(session.wildState, .ready)
        XCTAssertEqual(session.wildCandidates.map(\.id), oldIDs)
        let battle = try XCTUnwrap(session.battle)
        XCTAssertEqual(battle.phase, .running)
        XCTAssertEqual(battle.opponent?.id, session.opponentID)
        XCTAssertEqual(battle.opponent?.snapshot?.set.speciesNum, battle.view?.p2.speciesNum)
    }

    /// Same race after the battle ended: the late result used to reset `opponentID`, and the change dropped the
    /// finished battle together with its unseen result.
    func testFinishedBattleAndItsUnseenResultSurviveAStaleRerollLanding() async throws {
        let gate = GatedProvider(WildStub.standard())
        let counter = Counter()
        let session = makeSession(gate, seed: { counter.value += 1; return counter.value })
        session.prepare(state: fastState(), activeName: nil)
        let first = await completeSearch(session, gate)
        XCTAssertTrue(first)
        let oldIDs = session.wildCandidates.map(\.id)
        let wildA = try XCTUnwrap(oldIDs.first)
        session.opponentID = wildA
        session.findWildOpponents()
        let reached = await waitSuspended(gate)
        XCTAssertTrue(reached)
        let stale = session.wildTask
        session.mode = .automatic
        session.start()
        session.skipToResult()
        XCTAssertEqual(session.battle?.phase, .finished, "precondition: the automatic battle ended")
        XCTAssertEqual(session.statusBadge, "\u{2691}")
        await gate.resume()
        await stale?.value
        XCTAssertEqual(session.battle?.phase, .finished, "the finished battle is kept")
        XCTAssertEqual(session.statusBadge, "\u{2691}", "the unseen result is still unseen")
        XCTAssertEqual(session.opponentID, wildA)
        XCTAssertEqual(session.wildCandidates.map(\.id), oldIDs)
    }

    func testReleaseIfIdleDuringASearchStopsItAndKeepsTheOldBatch() async throws {
        let gate = GatedProvider(WildStub.standard())
        let counter = Counter()
        let session = makeSession(gate, seed: { counter.value += 1; return counter.value })
        session.prepare(state: state(), activeName: nil)
        // Nothing found yet: a released search leaves the section idle.
        session.findWildOpponents()
        var reached = await waitSuspended(gate)
        XCTAssertTrue(reached)
        var stale = session.wildTask
        session.releaseIfIdle()
        XCTAssertEqual(session.wildState, .idle)
        await gate.resume()
        await stale?.value
        XCTAssertEqual(session.wildState, .idle)
        XCTAssertTrue(session.wildCandidates.isEmpty)
        // With a batch on screen it stays.
        session.prepare(state: state(), activeName: nil)
        let found = await completeSearch(session, gate)
        XCTAssertTrue(found)
        let oldIDs = session.wildCandidates.map(\.id)
        session.findWildOpponents()
        reached = await waitSuspended(gate)
        XCTAssertTrue(reached)
        stale = session.wildTask
        session.releaseIfIdle()
        XCTAssertEqual(session.wildState, .ready)
        await gate.resume()
        await stale?.value
        XCTAssertEqual(session.wildState, .ready)
        XCTAssertEqual(session.wildCandidates.map(\.id), oldIDs)
    }

    func testTheSessionClockBoundsTheSearch() async throws {
        let clock = FakeClock(), stub = WildStub.standard()
        stub.clock = clock; stub.secondsPerRequest = 11
        let session = PracticeSession(engineURL: engineURL, clock: { clock.now }, drivesAutomatically: false,
                                      wildSource: PracticeWildSource(provider: stub, details: stub), wildSeed: { 11 })
        session.prepare(state: state(), activeName: nil)
        session.findWildOpponents()
        await session.wildTask?.value
        XCTAssertEqual(session.wildState, .ready)
        XCTAssertEqual(session.wildCandidates.count, 1, "the 20 s budget ran out on the session's own clock")
    }

    func testNothingFoundIsAPayloadFreeStateAndALaterSearchRecovers() async throws {
        let stub = WildStub.standard(); stub.failIndex = true
        let session = makeSession(stub)
        session.prepare(state: state(), activeName: nil)
        let finished = await search(session)
        XCTAssertTrue(finished)
        XCTAssertEqual(session.wildState, .unavailable)
        XCTAssertTrue(session.wildCandidates.isEmpty)
        stub.failIndex = false
        let again = await search(session)
        XCTAssertTrue(again)
        XCTAssertEqual(session.wildState, .ready)
    }

    func testWildCandidatesSurviveReleaseIfIdleAndStillResolve() async throws {
        let session = makeSession(WildStub.standard())
        session.prepare(state: state(), activeName: nil)
        let finished = await search(session)
        XCTAssertTrue(finished)
        let wild = try XCTUnwrap(session.wildCandidates.first)
        session.opponentID = wild.id
        session.releaseIfIdle()
        XCTAssertNil(session.roster)
        XCTAssertEqual(session.wildCandidates.map(\.id), ["wild-11-0", "wild-11-1", "wild-11-2"])
        XCTAssertEqual(session.wildState, .ready)
        XCTAssertEqual(session.opponent?.id, wild.id)
        session.prepare(state: state(), activeName: nil)
        XCTAssertEqual(session.opponentID, wild.id, "a prepared session keeps the wild opponent of the same player")
        XCTAssertNotNil(session.opponent)
    }
}

// MARK: Wording and the read-only guard

final class PracticeWildWordingTests: XCTestCase {
    func testUnavailableWordingIsLocalizedAndKeepsTheKoreanText() {
        XCTAssertEqual(L(.ko).practiceWildUnavailable,
                       "야생 상대를 찾지 못했습니다. 인터넷 연결을 확인한 뒤 다시 찾아 주세요. 내 개체끼리는 그대로 연습할 수 있습니다.")
        XCTAssertEqual(L(.en).practiceWildUnavailable,
                       "Couldn't find wild opponents. Check your internet connection and try again. You can still practice with your own Pokémon.")
        for language in AppLanguage.allCases where language != .ko {
            XCTAssertEqual(L(language).practiceWildUnavailable, L(.en).practiceWildUnavailable, "\(language)")
        }
    }
}

/// The practice side must stay read-only. `CompanionStore.rollsShiny` is a pure static and the one allowed use of
/// the store; any other store use, file write, defaults or keychain API in these files is a way to reach the save.
final class PracticeReadOnlyGuardTests: XCTestCase {
    static let writeAPIs = ["FileManager", "UserDefaults", "AppStatePaths", "SaveTransfer", "SaveSnapshot", ".write(to",
                            "createFile", "removeItem", "moveItem", "copyItem", "replaceItem", "FileHandle", "SecItem",
                            "Keychain", ".save("]
    static func hits(in source: String) -> [String] {
        let code = source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? String(line) }
            .joined(separator: "\n")
        var found = writeAPIs.filter { code.contains($0) }
        if code.replacingOccurrences(of: "CompanionStore.rollsShiny(", with: "").contains("CompanionStore") {
            found.append("CompanionStore")
        }
        return found
    }

    func testScannerFlagsWritesAndStoreUseButNotComments() {
        XCTAssertEqual(Self.hits(in: "try data.write(to: url)"), [".write(to"])
        XCTAssertEqual(Self.hits(in: "FileManager.default.createFile(atPath: p, contents: nil)"), ["FileManager", "createFile"])
        XCTAssertEqual(Self.hits(in: "let store = CompanionStore(provider: p)"), ["CompanionStore"])
        XCTAssertEqual(Self.hits(in: "store.save()"), [".save("])
        XCTAssertEqual(Self.hits(in: "let s = CompanionStore.rollsShiny(roll: 1, charmOwned: false)"), [])
        XCTAssertEqual(Self.hits(in: "/// never calls FileManager or CompanionStore\nlet x = 1 // UserDefaults"), [])
    }

    func testPracticeSourcesUseNoSaveOrFileWriteAPI() throws {
        let core = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/PokeTokenBar/Core")
        // Every practice file by prefix, so a new one is scanned without editing a list.
        let names = try FileManager.default.contentsOfDirectory(atPath: core.path)
            .filter { ($0.hasPrefix("Practice") && $0.hasSuffix(".swift")) || $0 == "HatchRule.swift" }
        XCTAssertTrue(names.contains("PracticeSession.swift") && names.contains("HatchRule.swift"), "scanned \(names)")
        for name in names {
            let source = try String(contentsOf: core.appendingPathComponent(name), encoding: .utf8)
            XCTAssertEqual(Self.hits(in: source), [], "\(name) reaches for the save or the disk")
        }
    }
}
