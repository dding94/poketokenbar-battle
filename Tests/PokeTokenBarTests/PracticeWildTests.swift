import AppKit
import SwiftUI
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

/// Index requests held open until `resume()`, so a player change can land while a search is awaiting. Every request
/// is held: a search can run next to today's opponent's, and a lost continuation would hang the awaiting test.
private actor GatedProvider: PokeProviding, PokemonDetailProviding {
    private let inner: WildStub
    private var held: [CheckedContinuation<Void, Never>] = []
    init(_ inner: WildStub) { self.inner = inner }
    func line(baseSpeciesID: Int) async throws -> EvoLine { try await inner.line(baseSpeciesID: baseSpeciesID) }
    func baseSpeciesIndex() async throws -> [BaseSpecies] {
        await withCheckedContinuation { held.append($0) }
        return try await inner.baseSpeciesIndex()
    }
    func baseSpecies(id: Int) async throws -> BaseSpecies? { try await inner.baseSpecies(id: id) }
    func pokemonDetails(speciesID: Int) async throws -> PokemonDetails { try await inner.pokemonDetails(speciesID: speciesID) }
    func suspendedCount() -> Int { held.count }
    /// Lets every request held so far go on.
    func resume() { let released = held; held = []; released.forEach { $0.resume() } }
}

/// One species that only knows Splash, so a battle against it ends the same way on every seed: Magikarp (129) falls
/// to Pikachu's Thunderbolt in one turn, Chansey (113) takes at least six. Neither can hurt the player.
private struct SplashStub: PokeProviding, PokemonDetailProviding {
    let speciesID: Int
    func line(baseSpeciesID: Int) async throws -> EvoLine { evoLine(tree(speciesID), .common) }
    func baseSpeciesIndex() async throws -> [BaseSpecies] { [BaseSpecies(id: speciesID, captureRate: 255)] }
    func baseSpecies(id: Int) async throws -> BaseSpecies? { try await baseSpeciesIndex().first { $0.id == id } }
    func pokemonDetails(speciesID: Int) async throws -> PokemonDetails {
        PokemonDetails(
            speciesID: speciesID, name: "species-\(speciesID)", height: 10, weight: 100, baseExperience: 64, genderRate: 4,
            types: ["normal"],
            baseStats: ["hp": 45, "attack": 49, "defense": 49, "special-attack": 65, "special-defense": 65, "speed": 45],
            abilities: [PokemonAbilityOption(name: "swift-swim", slot: 1, isHidden: false)],
            moves: [PokemonMoveOption(name: "splash", learnMethods: [PokemonMoveLearnMethod(method: "level-up", level: 1)])])
    }
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

/// Waits until the gated provider holds `count` requests, i.e. that many searches are suspended inside their first
/// await. A search also makes today's opponent when it has none for today (`searchesInFlight`).
@MainActor
private func waitSuspended(_ gate: GatedProvider, count: Int = 1) async -> Bool {
    for _ in 0..<2500 {
        if await gate.suspendedCount() >= count { return true }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    return false
}

/// The wild search and today's opponent's, when each is in flight.
@MainActor
private func searchesInFlight(_ session: PracticeSession) -> Int {
    [session.wildState, session.dailyState].filter { $0 == .searching }.count
}

/// A whole search through the gate: start, let every request it started reach the index, release them, await the
/// tasks (today's opponent's too, so nothing is left running against the stub).
@MainActor
private func completeSearch(_ session: PracticeSession, _ gate: GatedProvider) async -> Bool {
    session.findWildOpponents()
    guard await waitSuspended(gate, count: searchesInFlight(session)) else { return false }
    let tasks = [session.wildTask, session.dailyTask]
    await gate.resume()
    for task in tasks { await task?.value }
    return session.wildState == .ready
}

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
        let reached = await waitSuspended(gate, count: searchesInFlight(session))
        XCTAssertTrue(reached, "the search reached the gated index request")
        let stale = session.wildTask, staleDaily = session.dailyTask
        session.playerID = "c"
        XCTAssertEqual(session.wildState, .idle)
        await gate.resume()
        await stale?.value   // the stale task has finished: nothing is left that could still land
        await staleDaily?.value
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
        var reached = await waitSuspended(gate, count: searchesInFlight(session))
        XCTAssertTrue(reached)
        var stale = session.wildTask
        let staleDaily = session.dailyTask
        session.releaseIfIdle()
        XCTAssertEqual(session.wildState, .idle)
        await gate.resume()
        await stale?.value
        await staleDaily?.value
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
        stub.clock = clock
        let session = PracticeSession(engineURL: engineURL, clock: { clock.now }, drivesAutomatically: false,
                                      wildSource: PracticeWildSource(provider: stub, details: stub), wildSeed: { 11 })
        session.prepare(state: state(), activeName: nil)
        // The first search also makes today's opponent on the same stub clock; let it land before the clock runs.
        session.findWildOpponents()
        await session.wildTask?.value; await session.dailyTask?.value
        stub.secondsPerRequest = 11
        session.findWildOpponents()
        XCTAssertNotEqual(session.dailyState, .searching, "a reroll leaves today's opponent alone")
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

// MARK: Today's opponent

/// Today's opponent is one more wild candidate, made from the day's seed next to the wild search with the same
/// lifecycle and generation guard. A reroll leaves it alone; another player or another day makes it again. Its
/// stars count against the day it was made for.
@MainActor
final class PracticeDailySessionTests: XCTestCase {
    /// The wall clock the session reads for the day; tests move it. UTC keeps the day keys machine-independent.
    private final class Today { var date = Date(timeIntervalSince1970: 1_793_400_000) }   // 2026-10-30 22:40 UTC
    private static let day1 = "2026-10-30", day2 = "2026-10-31"
    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }

    private func profile(_ id: String, move: String) -> PokemonProfile {
        var p = PokemonProfile.generate(seed: 42, instanceID: id)
        p.level = 50; p.gender = .male; p.abilityName = "static"
        p.moves = [PokemonKnownMove(name: move, learnedAtLevel: 1)]
        return p
    }
    /// Pikachu with Thunderbolt as the player, and two Blissey ("o", "c") to pick as own opponents.
    private func state(player: String = "p") -> CompanionState {
        var state = CompanionState()
        state.dex = [(player, 25, "thunderbolt"), ("o", 242, "tackle"), ("c", 242, "tackle")].map { id, species, move in
            DexEntry(baseID: species, finalID: species, chainOrder: [species], rarity: .common, caughtAt: nil,
                     nature: .hardy, profile: profile(id, move: move))
        }
        return state
    }
    private func makeSession(_ stub: some PokeProviding & PokemonDetailProviding, today: Today = Today(),
                             store: PracticeRecordStore = PracticeRecordStore(fileURL: nil),
                             seed: @escaping () -> UInt64 = { 11 }, player: String = "p") -> PracticeSession {
        let session = PracticeSession(engineURL: engineURL, clock: { 0 }, drivesAutomatically: false,
                                      wildSource: PracticeWildSource(provider: stub, details: stub), wildSeed: seed,
                                      recordStore: store, now: { today.date }, calendar: Self.utc)
        session.prepare(state: state(player: player), activeName: nil)
        return session
    }
    /// Starts a search and awaits both tasks it may have started.
    private func searchAll(_ session: PracticeSession) async {
        session.findWildOpponents()
        let tasks = [session.wildTask, session.dailyTask]
        for task in tasks { await task?.value }
    }
    /// The goals a finished battle met, from its own view: what the session must have counted.
    private func metGoals(_ battle: PracticeBattle?) throws -> Set<PracticeDailyGoal> {
        let view = try XCTUnwrap(battle?.view)
        let outcome = PracticeOutcome(winner: battle?.result?.winner)
        return Set(PracticeDailyGoal.allCases.filter {
            $0.isMet(outcome: outcome, turns: view.turn, playerHPShare: view.p1.hpShare)
        })
    }
    private func fightToday(_ session: PracticeSession) throws {
        session.opponentID = try XCTUnwrap(session.dailyCandidate).id
        session.mode = .automatic
        session.start()
        session.skipToResult()
    }

    func testASearchAlsoMakesTodaysOpponentFromTheDaySeed() async throws {
        let stub = WildStub.standard()
        let session = makeSession(stub)
        XCTAssertEqual(session.dailyState, .idle); XCTAssertNil(session.dailyCandidate)
        session.findWildOpponents()
        XCTAssertEqual(session.wildState, .searching); XCTAssertEqual(session.dailyState, .searching)
        let tasks = [session.wildTask, session.dailyTask]
        for task in tasks { await task?.value }
        XCTAssertEqual(session.dailyState, .ready)
        let daily = try XCTUnwrap(session.dailyCandidate)
        XCTAssertEqual(daily.id, "daily-2026-10-30")
        XCTAssertFalse(session.wildCandidates.contains { $0.id == daily.id })
        // The wild generator itself: one candidate around the player's level, on the day's seed.
        let generator = PracticeWildGenerator(source: PracticeWildSource(provider: stub, details: stub),
                                              engine: try BattleEngine(url: engineURL))
        let made = try await generator.make(count: 1, around: 50, seed: PracticeDaily.seed(dayKey: Self.day1))
        let expected = try XCTUnwrap(made.first)
        XCTAssertEqual(daily.snapshot, expected.snapshot)
        XCTAssertEqual(daily.name, expected.name); XCTAssertEqual(daily.origin, expected.origin)
        // It resolves as an opponent, and a battle starts against it.
        session.opponentID = daily.id
        XCTAssertEqual(session.opponent?.id, daily.id)
        XCTAssertNotNil(session.matchup)
        session.start()
        let battle = try XCTUnwrap(session.battle)
        XCTAssertEqual(battle.phase, .running)
        XCTAssertEqual(battle.opponent?.id, daily.id)
        XCTAssertEqual(battle.view?.p2.speciesNum, daily.snapshot?.set.speciesNum)
    }

    func testTheSameDayMakesTheSameOpponentAndAnotherDayAnother() async throws {
        let first = makeSession(WildStub.standard())
        await searchAll(first)
        let again = makeSession(WildStub.standard())
        await searchAll(again)
        XCTAssertNotNil(first.dailyCandidate?.snapshot)
        XCTAssertEqual(again.dailyCandidate?.id, first.dailyCandidate?.id)
        XCTAssertEqual(again.dailyCandidate?.snapshot, first.dailyCandidate?.snapshot)
        let tomorrow = Today(); tomorrow.date += 86_400
        let next = makeSession(WildStub.standard(), today: tomorrow)
        await searchAll(next)
        XCTAssertEqual(next.dailyCandidate?.id, "daily-2026-10-31")
        XCTAssertNotEqual(next.dailyCandidate?.snapshot, first.dailyCandidate?.snapshot)
    }

    func testARerollLeavesTodaysOpponentAndItsSelectionAlone() async throws {
        let counter = Counter()
        let session = makeSession(WildStub.standard(), seed: { counter.value += 1; return counter.value })
        await searchAll(session)
        let daily = try XCTUnwrap(session.dailyCandidate)
        session.opponentID = daily.id
        session.findWildOpponents()
        XCTAssertEqual(session.wildState, .searching)
        XCTAssertEqual(session.dailyState, .ready, "the same day's opponent is not made again")
        await session.wildTask?.value
        XCTAssertEqual(session.wildCandidates.map(\.id), ["wild-2-0", "wild-2-1", "wild-2-2"])
        XCTAssertEqual(session.dailyCandidate?.id, daily.id)
        XCTAssertEqual(session.dailyCandidate?.snapshot, daily.snapshot)
        XCTAssertEqual(session.opponentID, daily.id, "the replaced batch never held today's opponent")
    }

    func testChangingThePlayerDropsTodaysOpponent() async throws {
        let session = makeSession(WildStub.standard())
        await searchAll(session)
        session.opponentID = try XCTUnwrap(session.dailyCandidate).id
        session.playerID = "c"
        XCTAssertEqual(session.dailyState, .idle); XCTAssertNil(session.dailyCandidate)
        XCTAssertEqual(session.opponentID, "p", "today's opponent was matched to the old player's level")
        await searchAll(session)
        XCTAssertEqual(session.dailyState, .ready)
        XCTAssertEqual(session.dailyCandidate?.id, "daily-2026-10-30")
    }

    func testADailySearchInFlightIsDiscardedWhenThePlayerChanges() async throws {
        let gate = GatedProvider(WildStub.standard())
        let session = makeSession(gate)
        session.findWildOpponents()
        let reached = await waitSuspended(gate, count: 2)
        XCTAssertTrue(reached, "the wild search and today's opponent's both wait at the index")
        let stale = session.dailyTask, staleWild = session.wildTask
        session.playerID = "c"
        XCTAssertEqual(session.dailyState, .idle)
        await gate.resume()
        await stale?.value; await staleWild?.value
        XCTAssertEqual(session.dailyState, .idle, "the stale result must not land on the new player")
        XCTAssertNil(session.dailyCandidate)
    }

    func testStartStopsADailySearchAndItsLateResultChangesNothing() async throws {
        let gate = GatedProvider(WildStub.standard())
        let session = makeSession(gate)
        session.findWildOpponents()
        let reached = await waitSuspended(gate, count: 2)
        XCTAssertTrue(reached)
        let stale = session.dailyTask, staleWild = session.wildTask
        session.mode = .manual
        session.start()
        XCTAssertEqual(session.dailyState, .idle, "starting stops the search; nothing was made yet")
        let battle = try XCTUnwrap(session.battle)
        await gate.resume()
        await stale?.value; await staleWild?.value
        XCTAssertEqual(session.dailyState, .idle); XCTAssertNil(session.dailyCandidate)
        XCTAssertTrue(session.battle === battle); XCTAssertEqual(battle.opponent?.id, "o")
    }

    /// Yesterday's opponent is not today's: a new day's search drops it at once, with a selection of it, so it can
    /// no longer be started. `start()` then stops the search like the wild one, and its late result never lands.
    func testANewDaysSearchDropsYesterdaysOpponentAndStartStopsIt() async throws {
        let gate = GatedProvider(WildStub.standard()), today = Today()
        let session = makeSession(gate, today: today)
        let found = await completeSearch(session, gate)
        XCTAssertTrue(found)
        session.opponentID = try XCTUnwrap(session.dailyCandidate).id
        today.date += 86_400
        session.findWildOpponents()
        XCTAssertEqual(session.dailyState, .searching, "a new day makes a new opponent")
        XCTAssertNil(session.dailyCandidate, "yesterday's opponent goes at once")
        XCTAssertEqual(session.opponentID, "o", "its selection falls back to an own individual")
        let reached = await waitSuspended(gate, count: 2)
        XCTAssertTrue(reached)
        let stale = session.dailyTask, staleWild = session.wildTask
        session.mode = .manual
        session.start()
        XCTAssertEqual(session.dailyState, .idle)
        XCTAssertEqual(session.battle?.opponent?.id, "o")
        await gate.resume()
        await stale?.value; await staleWild?.value
        XCTAssertEqual(session.dailyState, .idle); XCTAssertNil(session.dailyCandidate, "the late result must not land")
        XCTAssertEqual(session.opponentID, "o")
        XCTAssertEqual(session.battle?.phase, .running)
    }

    /// A search while today's opponent is still being made: a quick reroll leaves that search alone, while a new day
    /// (midnight during the search) starts it over for the new day.
    func testASearchWhileTodaysOpponentIsBeingMadeKeepsItThatDayAndStartsOverTheNext() async throws {
        let gate = GatedProvider(WildStub.standard()), today = Today()
        let session = makeSession(gate, today: today)
        session.findWildOpponents()
        let reached = await waitSuspended(gate, count: 2)
        XCTAssertTrue(reached)
        let sameDay = session.dailyTask
        session.findWildOpponents()
        XCTAssertEqual(session.dailyState, .searching)
        XCTAssertTrue(session.dailyTask == sameDay, "a reroll on the same day leaves the search for today's opponent alone")
        today.date += 86_400
        session.findWildOpponents()
        XCTAssertEqual(session.dailyState, .searching)
        XCTAssertFalse(session.dailyTask == sameDay, "a new day starts it over")
        // Three wild searches and two for today's opponent reach the index.
        let held = await waitSuspended(gate, count: 5)
        XCTAssertTrue(held)
        let tasks = [session.wildTask, session.dailyTask, sameDay]
        await gate.resume()
        for task in tasks { await task?.value }
        XCTAssertEqual(session.dailyState, .ready)
        XCTAssertEqual(session.dailyCandidate?.id, "daily-2026-10-31", "the old day's search never lands")
    }

    func testANewDayMakesANewOpponentWhenASearchStarts() async throws {
        let today = Today()
        let session = makeSession(WildStub.standard(), today: today)
        await searchAll(session)
        let yesterday = try XCTUnwrap(session.dailyCandidate)
        session.opponentID = yesterday.id
        // The same day: a search leaves it.
        session.findWildOpponents()
        XCTAssertEqual(session.dailyState, .ready); XCTAssertEqual(session.opponentID, yesterday.id)
        await session.wildTask?.value
        today.date += 86_400
        session.findWildOpponents()
        XCTAssertEqual(session.dailyState, .searching); XCTAssertNil(session.dailyCandidate)
        XCTAssertEqual(session.opponentID, "o", "yesterday's opponent is gone, so the selection falls back to an own one")
        let tasks = [session.wildTask, session.dailyTask]
        for task in tasks { await task?.value }
        XCTAssertEqual(session.dailyCandidate?.id, "daily-2026-10-31")
        XCTAssertNotEqual(session.dailyCandidate?.snapshot, yesterday.snapshot)
        XCTAssertEqual(session.opponentID, "o", "the new opponent is offered, not selected")
    }

    /// The wild batch outlives the popover, so no wild search is due on a new day. The refresh is: `dailyRefreshDue`
    /// turns true, and `refreshDailyIfStale` drops yesterday's opponent at once and makes today's alone, leaving the
    /// wild batch as it is. The same day has nothing due.
    func testANewDayMakesTheRefreshDueAndItReplacesYesterdaysOpponentAlone() async throws {
        let today = Today()
        let session = makeSession(WildStub.standard(), today: today)
        await searchAll(session)
        let wildIDs = session.wildCandidates.map(\.id), wildTask = session.wildTask
        session.opponentID = try XCTUnwrap(session.dailyCandidate).id
        XCTAssertFalse(session.dailyRefreshDue, "today's is made")
        session.refreshDailyIfStale()
        XCTAssertEqual(session.dailyState, .ready, "nothing to make again on the same day")
        today.date += 86_400
        XCTAssertTrue(session.dailyRefreshDue, "yesterday's is on screen")
        session.refreshDailyIfStale()
        XCTAssertEqual(session.dailyState, .searching); XCTAssertNil(session.dailyCandidate)
        XCTAssertEqual(session.opponentID, "o", "yesterday's opponent is no longer today's")
        XCTAssertFalse(session.dailyRefreshDue, "a search in flight is not due again")
        XCTAssertEqual(session.wildState, .ready); XCTAssertEqual(session.wildCandidates.map(\.id), wildIDs)
        XCTAssertTrue(session.wildTask == wildTask, "the wild batch is not searched again")
        await session.dailyTask?.value
        XCTAssertEqual(session.dailyCandidate?.id, "daily-2026-10-31")
        XCTAssertFalse(session.dailyRefreshDue)
    }

    /// `start()` or a release stops the search for today's opponent and leaves nothing, so the refresh is due again;
    /// it needs a player and an engine, and `prepare` alone makes nothing (the selection screen asks). The stopped
    /// search never lands.
    func testAStoppedSearchLeavesTheRefreshDue() async throws {
        let gate = GatedProvider(WildStub.standard()), today = Today()
        let session = makeSession(gate, today: today)
        let found = await completeSearch(session, gate)
        XCTAssertTrue(found)
        today.date += 86_400
        session.refreshDailyIfStale()
        XCTAssertEqual(session.dailyState, .searching)
        let reached = await waitSuspended(gate)
        XCTAssertTrue(reached)
        let stale = session.dailyTask
        session.releaseIfIdle()
        XCTAssertEqual(session.dailyState, .idle); XCTAssertEqual(session.wildState, .ready)
        XCTAssertTrue(session.dailyRefreshDue)
        session.refreshDailyIfStale()
        XCTAssertEqual(session.dailyState, .idle, "released: no player or engine to make it with")
        await gate.resume()
        await stale?.value
        XCTAssertEqual(session.dailyState, .idle, "the stopped search does not land")
        session.prepare(state: state(), activeName: nil)
        XCTAssertEqual(session.dailyState, .idle, "preparing makes nothing; the selection screen asks")
        XCTAssertTrue(session.dailyRefreshDue)
        session.refreshDailyIfStale()
        XCTAssertEqual(session.dailyState, .searching)
        let resumed = await waitSuspended(gate)
        XCTAssertTrue(resumed)
        let task = session.dailyTask
        await gate.resume()
        await task?.value
        XCTAssertEqual(session.dailyCandidate?.id, "daily-2026-10-31")
    }

    /// The default calendar follows the system time zone (`.autoupdatingCurrent`); `.current` would keep the zone of
    /// the moment the session was made. The process's default time zone stands in for the system's here.
    func testTheDayFollowsATimeZoneChangeAfterLaunch() async throws {
        let original = NSTimeZone.default
        defer { NSTimeZone.default = original }
        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "Pacific/Pago_Pago"))   // UTC-11
        let instant = Date(timeIntervalSince1970: 1_793_400_000)   // 2026-10-30 22:40 UTC
        let stub = WildStub.standard()
        let session = PracticeSession(engineURL: engineURL, clock: { 0 }, drivesAutomatically: false,
                                      wildSource: PracticeWildSource(provider: stub, details: stub), wildSeed: { 11 },
                                      now: { instant })
        session.prepare(state: state(), activeName: nil)
        await searchAll(session)
        XCTAssertEqual(session.dailyCandidate?.id, "daily-2026-10-30", "the 30th in Pago Pago")
        XCTAssertFalse(session.dailyRefreshDue)
        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "Pacific/Kiritimati"))   // UTC+14
        XCTAssertTrue(session.dailyRefreshDue, "the same instant is the 31st in Kiritimati")
    }

    func testPrepareKeepsTodaysOpponentSelectedForTheSamePlayerOnly() async throws {
        let session = makeSession(WildStub.standard())
        await searchAll(session)
        let daily = try XCTUnwrap(session.dailyCandidate)
        session.opponentID = daily.id
        session.prepare(state: state(), activeName: nil)
        XCTAssertEqual(session.opponentID, daily.id)
        XCTAssertEqual(session.opponent?.snapshot, daily.snapshot)
        XCTAssertNotNil(session.matchup)
        XCTAssertEqual(session.dailyState, .ready, "nothing to make again")
        // The player is gone from the save: another player, so today's opponent goes with the wild batch.
        session.prepare(state: state(player: "q"), activeName: nil)
        XCTAssertEqual(session.playerID, "q")
        XCTAssertNil(session.dailyCandidate); XCTAssertEqual(session.dailyState, .idle)
        XCTAssertEqual(session.opponentID, "o")
    }

    /// A finished battle on screen keeps yesterday's opponent for its rematch: the refresh waits for the selection.
    func testAResultOnScreenKeepsYesterdaysOpponentForItsRematch() async throws {
        let today = Today()
        let session = makeSession(SplashStub(speciesID: 129), today: today)
        await searchAll(session)
        let yesterday = try XCTUnwrap(session.dailyCandidate)
        try fightToday(session)
        XCTAssertEqual(session.battle?.phase, .finished)
        today.date += 86_400
        session.prepare(state: state(), activeName: nil)
        XCTAssertTrue(session.dailyRefreshDue)
        session.refreshDailyIfStale()
        XCTAssertEqual(session.dailyState, .ready)
        XCTAssertEqual(session.dailyCandidate?.id, yesterday.id)
        XCTAssertEqual(session.opponentID, yesterday.id)
        XCTAssertEqual(session.battle?.phase, .finished, "the result is not dropped")
        session.start()
        XCTAssertEqual(session.battle?.opponent?.id, yesterday.id, "the rematch is against the same opponent")
    }

    // MARK: The selection screen (real path)

    /// Hosts the practice screen as the popover does, so the selection screen's own triggers run.
    private func host(_ session: PracticeSession) -> NSWindow {
        let view = NSHostingView(rootView: PracticeScreen(session: session, l: L(.en), artwork: false, onClose: {}))
        view.frame = NSRect(x: 0, y: 0, width: PopoverMetrics.width, height: 640)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: PopoverMetrics.width, height: 640),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        view.layoutSubtreeIfNeeded()
        return window
    }
    /// Lets SwiftUI run its updates until `condition` holds; false after 5 s.
    private func settle(_ window: NSWindow, until condition: () -> Bool) async -> Bool {
        for _ in 0..<500 {
            window.contentView?.layoutSubtreeIfNeeded()
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    /// `start()` stops a search for today's opponent and leaves it idle, and after a battle against an own opponent no
    /// wild search runs ("Other opponent" searches only after a wild foe, and the wild trigger watches the wild state
    /// only). Back on the selection screen, the screen itself makes it again.
    func testTheSelectionScreenMakesTodaysOpponentAgainAfterABattleStoppedItsSearch() async throws {
        let gate = GatedProvider(WildStub.standard()), today = Today()
        let session = makeSession(gate, today: today)
        let found = await completeSearch(session, gate)
        XCTAssertTrue(found)
        let wildIDs = session.wildCandidates.map(\.id), wildTask = session.wildTask
        today.date += 86_400
        let window = host(session)
        defer { window.orderOut(nil); window.contentView = nil }
        var searching = await settle(window) { session.dailyState == .searching }
        XCTAssertTrue(searching, "the selection screen makes the new day's opponent")
        var held = await waitSuspended(gate)
        XCTAssertTrue(held)
        let stopped = session.dailyTask
        session.opponentID = "o"; session.mode = .automatic
        session.start()
        XCTAssertEqual(session.dailyState, .idle, "the battle stopped the search")
        session.skipToResult()
        XCTAssertEqual(session.battle?.phase, .finished)
        let resultShown = await settle(window) { session.resultSeen }
        XCTAssertTrue(resultShown, "precondition: the result screen replaced the selection")
        // "Other opponent" after an own foe only goes back to the selection.
        session.backToSelection()
        searching = await settle(window) { session.dailyState == .searching }
        XCTAssertTrue(searching, "back on the selection screen, today's opponent is made again")
        XCTAssertTrue(session.wildTask == wildTask, "without a wild search"); XCTAssertEqual(session.wildCandidates.map(\.id), wildIDs)
        held = await waitSuspended(gate, count: 2)
        XCTAssertTrue(held)
        let remade = session.dailyTask
        await gate.resume()
        await stopped?.value; await remade?.value
        XCTAssertEqual(session.dailyCandidate?.id, "daily-2026-10-31")
    }

    /// A battle against an own opponent crosses midnight. "Other opponent" after an own foe only goes back to the
    /// selection and `prepare` does not run, so the screen itself must replace yesterday's opponent with today's.
    func testTheSelectionScreenReplacesYesterdaysOpponentAfterMidnight() async throws {
        let today = Today()
        let session = makeSession(WildStub.standard(), today: today)
        await searchAll(session)
        let yesterday = try XCTUnwrap(session.dailyCandidate)
        let wildIDs = session.wildCandidates.map(\.id), wildTask = session.wildTask
        let window = host(session)
        defer { window.orderOut(nil); window.contentView = nil }
        session.opponentID = "o"; session.mode = .automatic
        session.start(); session.skipToResult()
        XCTAssertEqual(session.battle?.phase, .finished)
        let resultShown = await settle(window) { session.resultSeen }
        XCTAssertTrue(resultShown, "precondition: the result screen replaced the selection")
        today.date += 86_400
        XCTAssertEqual(session.dailyCandidate?.id, yesterday.id, "nothing changes under the result screen")
        session.backToSelection()
        let replaced = await settle(window) { session.dailyCandidate?.id == "daily-2026-10-31" }
        XCTAssertTrue(replaced, "the selection screen replaces yesterday's opponent")
        XCTAssertTrue(session.wildTask == wildTask, "without a wild search"); XCTAssertEqual(session.wildCandidates.map(\.id), wildIDs)
        XCTAssertEqual(session.todayStars, [])
        await session.dailyTask?.value
    }

    func testReleaseIfIdleStopsADailySearchAndKeepsAMadeOpponent() async throws {
        let gate = GatedProvider(WildStub.standard())
        let session = makeSession(gate)
        session.findWildOpponents()
        let reached = await waitSuspended(gate, count: 2)
        XCTAssertTrue(reached)
        let stale = session.dailyTask, staleWild = session.wildTask
        session.releaseIfIdle()
        XCTAssertEqual(session.dailyState, .idle)
        await gate.resume()
        await stale?.value; await staleWild?.value
        XCTAssertEqual(session.dailyState, .idle); XCTAssertNil(session.dailyCandidate)
        // One that was made stays across a release and still resolves; the same player keeps it selected.
        session.prepare(state: state(), activeName: nil)
        let found = await completeSearch(session, gate)
        XCTAssertTrue(found)
        let daily = try XCTUnwrap(session.dailyCandidate)
        session.opponentID = daily.id
        session.releaseIfIdle()
        XCTAssertNil(session.roster)
        XCTAssertEqual(session.dailyState, .ready); XCTAssertEqual(session.opponent?.id, daily.id)
        session.prepare(state: state(), activeName: nil)
        XCTAssertEqual(session.opponentID, daily.id)
        XCTAssertEqual(session.opponent?.snapshot, daily.snapshot)
    }

    func testAnUnavailableOpponentIsRetriedByTheNextSearch() async throws {
        let stub = WildStub.standard(); stub.failIndex = true
        let session = makeSession(stub)
        await searchAll(session)
        XCTAssertEqual(session.dailyState, .unavailable); XCTAssertNil(session.dailyCandidate)
        stub.failIndex = false
        XCTAssertFalse(session.dailyRefreshDue, "a failure is not due, so a screen that is offline cannot loop")
        session.refreshDailyIfStale()
        XCTAssertEqual(session.dailyState, .unavailable, "the next search retries it")
        await searchAll(session)
        XCTAssertEqual(session.dailyState, .ready)
        XCTAssertEqual(session.dailyCandidate?.id, "daily-2026-10-30")
    }

    // MARK: Stars

    func testBeatingTodaysOpponentEarnsItsStarsOnce() async throws {
        let session = makeSession(SplashStub(speciesID: 129))
        await searchAll(session)
        try fightToday(session)
        XCTAssertEqual(session.battle?.result?.winner, "p1")
        let view = try XCTUnwrap(session.battle?.view)
        XCTAssertEqual(view.turn, 1); XCTAssertEqual(view.p1.hp, view.p1.maxhp, "Splash never hurts")
        let all = Set(PracticeDailyGoal.allCases)
        XCTAssertEqual(session.lastRecord, PracticeRecordUpdate(outcome: .win, streak: 1, bestStreak: 1, endedStreak: nil,
                                                                daily: true, newStars: all, stars: all))
        XCTAssertEqual(session.records.dailyDay, Self.day1); XCTAssertEqual(session.records.dailyStars, all)
        // The rematch is the same opponent: nothing left to earn today.
        session.start(); session.skipToResult()
        XCTAssertEqual(session.lastRecord, PracticeRecordUpdate(outcome: .win, streak: 2, bestStreak: 2, endedStreak: nil,
                                                                daily: true, newStars: [], stars: all))
    }

    func testASlowWinEarnsOnlyTheStarsItMet() async throws {
        let session = makeSession(SplashStub(speciesID: 113))
        await searchAll(session)
        try fightToday(session)
        XCTAssertEqual(session.battle?.result?.winner, "p1")
        let view = try XCTUnwrap(session.battle?.view)
        XCTAssertGreaterThanOrEqual(view.turn, 6, "Chansey outlasts several Thunderbolts")
        XCTAssertEqual(view.p1.hp, view.p1.maxhp)
        let met = try metGoals(session.battle)
        XCTAssertTrue(met.isSuperset(of: [.win, .healthyWin]))
        XCTAssertEqual(session.lastRecord?.newStars, met); XCTAssertEqual(session.lastRecord?.stars, met)
        XCTAssertEqual(session.records.dailyStars, met)
    }

    func testAnotherDayClearsTheStarsBeforeAddingAndTheFileKeepsThem() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("practice-daily-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PracticeRecordStore(fileURL: folder.appendingPathComponent("practice-records.json"))
        let first = makeSession(SplashStub(speciesID: 129), store: store)
        await searchAll(first)
        try fightToday(first)
        XCTAssertEqual(store.load().dailyStars, Set(PracticeDailyGoal.allCases))
        // The next day, after a relaunch.
        let tomorrow = Today(); tomorrow.date += 86_400
        let second = makeSession(SplashStub(speciesID: 113), today: tomorrow, store: store)
        XCTAssertEqual(second.records.dailyDay, Self.day1)
        await searchAll(second)
        try fightToday(second)
        let met = try metGoals(second.battle)
        XCTAssertEqual(second.lastRecord?.newStars, met, "yesterday's stars were cleared before today's were added")
        XCTAssertEqual(second.lastRecord?.stars, met)
        let saved = store.load()
        XCTAssertEqual(saved.dailyDay, Self.day2); XCTAssertEqual(saved.dailyStars, met); XCTAssertEqual(saved.wins, 2)
    }

    func testOnlyTodaysOpponentEarnsStars() async throws {
        let session = makeSession(SplashStub(speciesID: 129))
        await searchAll(session)
        // A wild Magikarp from the batch: the same kind of win, but not today's opponent.
        session.opponentID = try XCTUnwrap(session.wildCandidates.first).id
        session.mode = .automatic
        session.start(); session.skipToResult()
        XCTAssertEqual(session.battle?.result?.winner, "p1")
        XCTAssertEqual(session.lastRecord?.daily, false)
        XCTAssertEqual(session.lastRecord?.newStars, []); XCTAssertEqual(session.lastRecord?.stars, [])
        XCTAssertNil(session.records.dailyDay); XCTAssertEqual(session.records.dailyStars, [])
        // Giving up against today's opponent is a loss that earns nothing.
        session.opponentID = try XCTUnwrap(session.dailyCandidate).id
        session.mode = .manual
        session.start(); session.forfeit()
        XCTAssertEqual(session.lastRecord, PracticeRecordUpdate(outcome: .loss, streak: 0, bestStreak: 1, endedStreak: 1,
                                                                daily: true, newStars: [], stars: []))
        XCTAssertEqual(session.records.dailyDay, Self.day1); XCTAssertEqual(session.records.dailyStars, [])
    }

    /// The failure view's way back is `forfeit()`, and a battle that failed is not a loss. Practice candidates never
    /// share an individual, so the test makes one: an own entry with the instance id the generator gave today's
    /// opponent's profile ("wild-<seed>-0"); the engine refuses the same individual on both sides.
    func testForfeitingAFailedBattleCountsNothing() async throws {
        let instance = "wild-\(PracticeDaily.seed(dayKey: Self.day1))-0"
        let session = makeSession(SplashStub(speciesID: 129), player: instance)
        await searchAll(session)
        XCTAssertEqual(session.dailyCandidate?.snapshot?.instanceID, instance)
        session.opponentID = try XCTUnwrap(session.dailyCandidate).id
        session.start()
        XCTAssertEqual(session.battle?.phase, .failed, "precondition: the battle failed to start")
        session.forfeit()
        XCTAssertNil(session.battle)
        XCTAssertEqual(session.records, PracticeRecords()); XCTAssertNil(session.lastRecord)
    }
}

// MARK: Opponent temperament

/// A wild opponent's temperament reaches the engine through the whole chain: the generator rolls a nature, the
/// candidate maps it, and the battle hands it to the engine as `config.p2.policy`.
@MainActor
final class PracticeTemperamentWildTests: XCTestCase {
    private static let attackRaising: Set<String> = ["lonely", "brave", "adamant", "naughty", "modest", "mild", "quiet", "rash"]

    func testAWildOpponentWithAnAttackRaisingNatureRunsAggressive() async throws {
        let stub = SplashStub(speciesID: 129)
        // The first seed whose wild Magikarp has an attack-raising nature (8 of 25 natures).
        let generator = PracticeWildGenerator(source: PracticeWildSource(provider: stub, details: stub),
                                              engine: try BattleEngine(url: engineURL))
        var found: UInt64?
        for seed in UInt64(1)...64 {
            let made = try await generator.make(count: 1, around: 50, seed: seed)
            if let nature = made.first?.snapshot?.set.nature, Self.attackRaising.contains(nature) { found = seed; break }
        }
        let seed = try XCTUnwrap(found)
        var profile = PokemonProfile.generate(seed: 42, instanceID: "p")
        profile.level = 50; profile.gender = .male; profile.abilityName = "static"
        profile.moves = [PokemonKnownMove(name: "thunderbolt", learnedAtLevel: 1)]
        var state = CompanionState()
        state.dex = [DexEntry(baseID: 25, finalID: 25, chainOrder: [25], rarity: .common, caughtAt: nil,
                              nature: .adamant, profile: profile)]
        let session = PracticeSession(engineURL: engineURL, clock: { 0 }, drivesAutomatically: false,
                                      wildSource: PracticeWildSource(provider: stub, details: stub), wildSeed: { seed })
        session.prepare(state: state, activeName: nil)
        session.findWildOpponents()
        let tasks = [session.wildTask, session.dailyTask]
        for task in tasks { await task?.value }
        let wild = try XCTUnwrap(session.wildCandidates.first)
        XCTAssertTrue(Self.attackRaising.contains(try XCTUnwrap(wild.snapshot?.set.nature)))
        XCTAssertEqual(wild.temperament, .aggressive)
        session.opponentID = wild.id
        session.mode = .automatic
        session.start(); session.skipToResult()
        let log = try XCTUnwrap(session.battle?.result?.inputLog)
        XCTAssertEqual(log.config.p2.policy, "aggressive")
        XCTAssertNil(log.config.p1.policy, "the player's automatic turns stay standard, whatever its own nature")
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

/// The practice side must stay read-only towards the save. `CompanionStore.rollsShiny` is a pure static and the one
/// allowed use of the store; any other store use, file write, defaults or keychain API in these files is a way to reach
/// the save. One file writes: `Core/PracticeRecordStore.swift` keeps the practice records in a file of their own, so it
/// may use the file APIs that takes (the atomic write, and moving a damaged file aside). It still may not delete, trash,
/// copy or replace a file or change its attributes, nor touch the store, the state paths, save transfers, defaults or
/// the keychain: it can only write the URL it is given. `PracticeRecordFileTests` checks at run time that this URL is
/// not the save.
final class PracticeReadOnlyGuardTests: XCTestCase {
    static let writeAPIs = ["FileManager", "UserDefaults", "AppStatePaths", "SaveTransfer", "SaveSnapshot", ".write(to",
                            "createFile", "removeItem", "moveItem", "copyItem", "replaceItem", "FileHandle", "SecItem",
                            "Keychain", ".save(", "trashItem", "setAttributes"]
    /// The one practice file that may write, and the only file APIs it may use.
    static let recordStorePath = "Core/PracticeRecordStore.swift"
    static let recordStoreAllowed: Set<String> = ["FileManager", ".write(to", "moveItem"]

    /// The forbidden APIs `source` uses; `path` ("Core/PracticeSession.swift") gives the record store its allowance.
    static func hits(in source: String, path: String = "") -> [String] {
        let code = source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? String(line) }
            .joined(separator: "\n")
        let allowed = path == recordStorePath ? recordStoreAllowed : []
        var found = writeAPIs.filter { code.contains($0) && !allowed.contains($0) }
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

    func testOnlyTheRecordStoreMayWriteAndNeverTowardsTheSave() {
        let store = Self.recordStorePath
        XCTAssertEqual(Self.hits(in: "try data.write(to: url, options: .atomic)", path: store), [])
        XCTAssertEqual(Self.hits(in: "try FileManager.default.moveItem(atPath: a, toPath: b)", path: store), [])
        XCTAssertEqual(Self.hits(in: "try FileManager.default.removeItem(at: url)", path: store), ["removeItem"])
        XCTAssertEqual(Self.hits(in: "try FileManager.default.copyItem(at: a, to: b)", path: store), ["copyItem"])
        XCTAssertEqual(Self.hits(in: "_ = try FileManager.default.replaceItemAt(a, withItemAt: b)", path: store), ["replaceItem"])
        // "Never deletes" covers the trash, and the store does not change permissions or dates either.
        XCTAssertEqual(Self.hits(in: "try FileManager.default.trashItem(at: url, resultingItemURL: nil)", path: store),
                       ["trashItem"])
        XCTAssertEqual(Self.hits(in: "try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: p)",
                                 path: store), ["setAttributes"])
        XCTAssertEqual(Self.hits(in: "try FileManager.default.trashItem(at: url, resultingItemURL: nil)",
                                 path: "Core/PracticeSession.swift"), ["FileManager", "trashItem"])
        XCTAssertEqual(Self.hits(in: "let url = AppStatePaths.directory()", path: store), ["AppStatePaths"])
        XCTAssertEqual(Self.hits(in: "CompanionStore.shared.save()", path: store), [".save(", "CompanionStore"])
        XCTAssertEqual(Self.hits(in: "try SaveTransfer.export(state)", path: store), ["SaveTransfer"])
        XCTAssertEqual(Self.hits(in: "SaveSnapshotManager.loadLatestValidSnapshot(for: url)", path: store), ["SaveSnapshot"])
        XCTAssertEqual(Self.hits(in: "KeychainAccess.read(service: s)", path: store), ["Keychain"])
        XCTAssertEqual(Self.hits(in: "UserDefaults.standard.set(1, forKey: k)", path: store), ["UserDefaults"])
        // Any other practice file, or a file of the same name in another folder, gets nothing.
        XCTAssertEqual(Self.hits(in: "try data.write(to: url, options: .atomic)", path: "Core/PracticeSession.swift"), [".write(to"])
        XCTAssertEqual(Self.hits(in: "try FileManager.default.moveItem(atPath: a, toPath: b)", path: "UI/PracticeRecordStore.swift"),
                       ["FileManager", "moveItem"])
    }

    func testPracticeSourcesUseNoSaveOrFileWriteAPI() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/PokeTokenBar")
        // Every practice file by prefix, so a new one is scanned without editing a list.
        for (folder, required) in [("Core", ["PracticeSession.swift", "PracticeRecordStore.swift", "HatchRule.swift"]),
                                   ("UI", ["PracticeSelectionView.swift", "PracticeScreen.swift"])] {
            let directory = root.appendingPathComponent(folder)
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .filter { ($0.hasPrefix("Practice") && $0.hasSuffix(".swift")) || (folder == "Core" && $0 == "HatchRule.swift") }
            XCTAssertTrue(required.allSatisfy(names.contains), "scanned \(names)")
            for name in names {
                let source = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
                XCTAssertEqual(Self.hits(in: source, path: "\(folder)/\(name)"), [], "\(folder)/\(name) reaches for the save or the disk")
            }
        }
    }
}
