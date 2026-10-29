import XCTest
@testable import PokeTokenBar

@MainActor
final class PracticeBattleTests: XCTestCase {
    private func engine() throws -> BattleEngine {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try BattleEngine(url: root.appendingPathComponent("engine/dist/battle-engine.js"))
    }
    private func profile(_ id: String, moves: [String] = ["tackle"], ability: String = "pressure") -> PokemonProfile {
        var p = PokemonProfile.generate(seed: 42, instanceID: id)
        p.level = 50; p.gender = .male; p.abilityName = ability
        p.moves = moves.map { PokemonKnownMove(name: $0, learnedAtLevel: 1) }
        return p
    }
    private func candidate(_ id: String, species: Int = 242, moves: [String] = ["tackle"], ability: String = "pressure", engine: BattleEngine) throws -> PracticeCandidate {
        let snapshot = try BattleSnapshot.make(speciesID: species, nature: .hardy, profile: profile(id, moves: moves, ability: ability), using: engine)
        return PracticeCandidate(id: id, name: id, snapshot: snapshot, blockedReason: nil)
    }
    func testRosterExcludesReleasedAndPreservesIndividualIDs() throws {
        var state = CompanionState()
        state.active = MonState(baseID: 25, pathIDs: [25], stageIndex: 0, usedAtStage: 7,
                                rarity: .common, totalForms: 1, nature: .hardy, profile: profile("active"))
        state.dex = [false, true].map { released in
            DexEntry(id: "ui-\(released)", baseID: 25, finalID: 25, chainOrder: [25], rarity: .common,
                     caughtAt: nil, nature: .hardy, profile: profile(released ? "released" : "graduated"),
                     releasedAt: released ? Date() : nil)
        }
        let roster = PracticeRoster(state: state, engine: try engine())
        XCTAssertEqual(roster.eligible.map(\.id), ["active", "graduated"])
    }
    func testRosterExplainsMissingMovesAndAbilityWithoutRepairingSave() throws {
        var state = CompanionState()
        var p = profile("missing"); p.abilityName = nil
        state.dex = [p, profile("no-moves", moves: [])].map {
            DexEntry(baseID: 25, finalID: 25, chainOrder: [25], rarity: .common, caughtAt: nil, nature: .hardy, profile: $0)
        }
        let before = try BattleJSON.encode(state)
        let roster = PracticeRoster(state: state, engine: try engine())
        XCTAssertTrue(roster.eligible.isEmpty); XCTAssertEqual(roster.candidates.count, 2)
        XCTAssertTrue(roster.candidates.first?.blockedReason?.contains("특성") == true)
        XCTAssertTrue(roster.candidates.last?.blockedReason?.contains("기술") == true)
        XCTAssertEqual(try BattleJSON.encode(state), before)
    }
    func testManualTimeoutActsOnceAtThirtySeconds() throws {
        let engine = try engine(); var now = 0.0
        let model = PracticeBattle(engine: engine, clock: { now })
        model.start(player: try candidate("a", engine: engine), opponent: try candidate("b", engine: engine), mode: .manual, seed: [1,2,3,4])
        XCTAssertEqual(model.phase, .running); XCTAssertEqual(model.view?.turn, 1)
        now = 29.9; model.tick(); XCTAssertEqual(model.view?.turn, 1)
        now = 30; model.tick(); XCTAssertEqual(model.view?.turn, 2)
        model.tick(); XCTAssertEqual(model.view?.turn, 2)
        XCTAssertTrue(model.messages.contains { $0.contains("시간 초과") })
    }
    func testSameSeedAndChoicesReplayAndNeverWriteSyntheticSave() throws {
        let engine = try engine(); let a = try candidate("a", species: 25, moves: ["thunderbolt"], engine: engine)
        let b = try candidate("b", species: 129, moves: ["splash"], engine: engine)
        let first = PracticeBattle(engine: engine), second = PracticeBattle(engine: engine)
        var state = CompanionState(); state.eggUsage = 123
        let bytes = try BattleJSON.encoder().encode(state)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: file); defer { try? FileManager.default.removeItem(at: file) }
        for model in [first, second] {
            model.start(player: a, opponent: b, mode: .manual, seed: [1,2,3,4]); model.choose(slot: 1)
            XCTAssertEqual(model.phase, .finished)
        }
        let result = try XCTUnwrap(first.result)
        XCTAssertEqual(result.logHash, second.result?.logHash)
        struct Replay: Decodable { let logHash: String }
        let replay: Replay = try BattleJSON.decode(engine.call(.replay, arguments: [BattleJSON.encode(result.inputLog)]))
        XCTAssertEqual(replay.logHash, result.logHash)
        XCTAssertEqual(try Data(contentsOf: file), bytes); XCTAssertEqual(try BattleJSON.encoder().encode(state), bytes)
    }
    func testAutoModeFinishesAndCancellationStopsProgress() throws {
        let engine = try engine(); var now = 0.0
        let model = PracticeBattle(engine: engine, clock: { now })
        let a = try candidate("a", species: 25, moves: ["thunderbolt"], engine: engine)
        let b = try candidate("b", species: 129, moves: ["splash"], engine: engine)
        model.start(player: a, opponent: b, mode: .automatic, seed: [1,2,3,4]); now = 1; model.tick()
        XCTAssertEqual(model.phase, .finished); XCTAssertEqual(model.result?.winner, "p1")
        model.start(player: a, opponent: b, mode: .manual); model.cancel(); now = 100; model.tick()
        XCTAssertEqual(model.phase, .cancelled); XCTAssertNil(model.result)
    }
    func testInvalidAndSameIndividualAreBlockedAndNotReportedAsDraw() throws {
        let engine = try engine(); let a = try candidate("a", engine: engine)
        let model = PracticeBattle(engine: engine)
        model.start(player: a, opponent: a, mode: .manual)
        XCTAssertEqual(model.phase, .failed); XCTAssertNil(model.result)
        model.start(player: a, opponent: try candidate("b", engine: engine), mode: .manual, seed: [])
        XCTAssertEqual(model.phase, .failed); XCTAssertNil(model.result)
    }
    func testRejectedChoiceKeepsRunningAndRefreshesLegalMoves() throws {
        let engine = try engine(); let model = PracticeBattle(engine: engine)
        model.start(player: try candidate("a", engine: engine), opponent: try candidate("b", engine: engine), mode: .manual)
        model.choose(slot: 4)
        XCTAssertEqual(model.phase, .running); XCTAssertEqual(model.view?.turn, 1)
        XCTAssertNotNil(model.notice); XCTAssertFalse(model.request.moves.isEmpty)
        model.choose(slot: 1); XCTAssertEqual(model.view?.turn, 2)
    }
    func testOpponentSecretsAppearOnlyAfterUse() throws {
        let engine = try engine(); let model = PracticeBattle(engine: engine)
        let a = try candidate("a", moves: ["splash"], engine: engine)
        let snapshot = try BattleSnapshot.make(speciesID: 25, nature: .hardy, profile: profile("b", moves: ["tackle"], ability: "static"), using: engine)
        model.start(player: a, opponent: PracticeCandidate(id: "b", name: "b", snapshot: snapshot, blockedReason: nil), mode: .manual)
        XCTAssertEqual(model.view?.p2.moves, []); XCTAssertNil(model.view?.p2.ability)
        model.choose(slot: 1); XCTAssertEqual(model.view?.p2.moves, ["tackle"])
    }
    func testLateManualClickUsesTimeoutPolicyAndFinishedClicksDoNothing() throws {
        let engine = try engine(); var now = 0.0
        let model = PracticeBattle(engine: engine, clock: { now })
        model.start(player: try candidate("a", species: 25, moves: ["thunderbolt", "splash"], engine: engine),
                    opponent: try candidate("b", species: 129, moves: ["splash"], engine: engine), mode: .manual, seed: [1,2,3,4])
        now = 30; model.choose(slot: 2)
        XCTAssertEqual(model.result?.winner, "p1")
        let hash = model.result?.logHash; model.choose(slot: 2); model.tick(); model.cancel()
        XCTAssertEqual(model.phase, .finished); XCTAssertEqual(model.result?.logHash, hash)
    }
    func testAutomaticCapDrawAndHiddenRestrictionRetry() throws {
        let engine = try engine(); var now = 0.0
        let model = PracticeBattle(engine: engine, clock: { now })
        let moves = ["splash", "growl", "tail-whip", "defense-curl"]
        model.start(player: try candidate("a", moves: moves, ability: "natural-cure", engine: engine),
                    opponent: try candidate("b", moves: moves, ability: "natural-cure", engine: engine), mode: .automatic, seed: [1,2,3,4])
        model.tick(); XCTAssertEqual(model.view?.turn, 1)
        for _ in 0..<200 { now += 1; model.tick() }
        XCTAssertEqual(model.phase, .finished); XCTAssertNil(model.result?.winner)
        XCTAssertEqual(model.result?.turns, 200)
        model.start(player: try candidate("a", species: 151, moves: ["imprison", "tackle"], engine: engine),
                    opponent: try candidate("b", moves: ["tackle", "splash"], engine: engine), mode: .manual, seed: [1,2,3,4])
        model.choose(slot: 1); model.mode = .automatic; now += 1; model.tick()
        XCTAssertEqual(model.phase, .running); XCTAssertEqual(model.view?.turn, 3)
        model.cancel()
    }
    func testBlockedCandidateCannotStartAndMessagesHaveUsefulFallbacks() throws {
        let engine = try engine(); let model = PracticeBattle(engine: engine)
        let blocked = PracticeCandidate(id: "missing", name: "미완성", snapshot: nil, blockedReason: "특성 없음")
        model.start(player: blocked, opponent: try candidate("b", engine: engine), mode: .manual)
        XCTAssertEqual(model.phase, .failed); XCTAssertNil(model.result)
        XCTAssertTrue(model.notice?.contains("정보") == true)
        XCTAssertEqual(PracticeText.log("|-status|p1a: Test|par", names: ["p1": "내 개체"]), "내 개체 · 마비 상태가 되었습니다.")
        XCTAssertEqual(PracticeText.log("|move|p1a: Test|Untranslated Move", names: ["p1": "내 개체"]), "내 개체 · Untranslated Move 사용")
        XCTAssertEqual(PracticeText.log("|-weather|RainDance", names: [:]), "날씨 · RainDance")
        XCTAssertNotNil(PracticeText.log("|-future-event|p1a: Test|new effect", names: [:]))
        XCTAssertNil(PracticeText.log("", names: [:]))
    }

}
