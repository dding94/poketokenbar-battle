import XCTest
@testable import PokeTokenBar

/// The store's PokéAPI for a save that only has graduates: nothing to load.
private struct RosterNoLineProvider: PokeProviding {
    func line(baseSpeciesID: Int) async throws -> EvoLine { throw URLError(.notConnectedToInternet) }
    func baseSpeciesIndex() async throws -> [BaseSpecies] { [] }
    func baseSpecies(id: Int) async throws -> BaseSpecies? { nil }
}

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
        state.language = .ko
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
    /// Names no engine species uses, so the engine's fallback can never pass as the stored name.
    private static let storedNames = ["en": "English Name", "ko": "한국어 이름", "ja-Hrkt": "ニホンゴ"]
    private func rosterState(_ language: AppLanguage, names: [Int: [String: String]]?, species: Int = 25,
                             form: PokemonForm? = nil, profile entryProfile: PokemonProfile? = nil) -> CompanionState {
        var state = CompanionState()
        state.language = language
        state.dex = [DexEntry(baseID: species, finalID: species, chainOrder: [species], rarity: .common, caughtAt: nil,
                              nature: .hardy, profile: entryProfile ?? profile("graduate"), names: names, form: form)]
        return state
    }
    func testRosterNamesAGraduateInTheAppLanguage() throws {
        let engine = try engine()
        let expected: [(AppLanguage, String)] = [(.en, "English Name"), (.ko, "한국어 이름"), (.ja, "ニホンゴ"),
                                                 (.fr, "English Name")]   // no French name stored: `resolveName` falls back to English
        for (language, name) in expected {
            let roster = PracticeRoster(state: rosterState(language, names: [25: Self.storedNames]), engine: engine)
            XCTAssertEqual(roster.eligible.map(\.name), [name], "\(language)")
        }
    }
    /// Nothing the language can read: the engine's species name, as before. A name stored only in another language is
    /// not shown in its place (the Korean name on an English app is this defect).
    func testRosterUsesTheEngineSpeciesWhenNoStoredNameResolves() throws {
        let engine = try engine()
        for names in [nil, [25: ["ko": "한국어 이름"]]] as [[Int: [String: String]]?] {
            let roster = PracticeRoster(state: rosterState(.en, names: names), engine: engine)
            XCTAssertEqual(roster.eligible.map(\.name), ["Pikachu"])
        }
        XCTAssertEqual(PracticeRoster(state: rosterState(.ko, names: [25: ["ko": "한국어 이름"]]), engine: engine).eligible.map(\.name),
                       ["한국어 이름"])
    }
    /// The final species has no name the language can read: the closest earlier stage that has one, as in the dex.
    func testRosterFallsBackToTheClosestEarlierStageName() throws {
        let engine = try engine()
        func name(_ names: [Int: [String: String]]) -> String? {
            var state = rosterState(.en, names: names)
            state.dex[0].chainOrder = [172, 25, 26]
            state.dex[0].finalID = 26
            return PracticeRoster(state: state, engine: engine).eligible.first?.name
        }
        XCTAssertEqual(name([172: ["en": "First"], 25: ["en": "Middle"], 26: ["en": "Final"]]), "Final")
        XCTAssertEqual(name([172: ["en": "First"], 25: ["en": "Middle"]]), "Middle")
        XCTAssertEqual(name([172: ["en": "First"], 25: ["ko": "가운데"], 26: ["ko": "마지막"]]), "First")
        XCTAssertEqual(name([172: ["ko": "처음"], 25: ["ko": "가운데"], 26: ["ko": "마지막"]]), "Raichu")
    }
    /// A graduate that cannot fight still gets a row: its stored name in the app language, else the dex's "#id",
    /// never a Korean placeholder.
    func testBlockedGraduateRowFollowsTheAppLanguage() throws {
        let engine = try engine()
        var noAbility = profile("blocked"); noAbility.abilityName = nil
        let named = PracticeRoster(state: rosterState(.en, names: [25: Self.storedNames], profile: noAbility), engine: engine)
        XCTAssertEqual(named.candidates.map(\.name), ["English Name"]); XCTAssertTrue(named.eligible.isEmpty)
        let unnamed = PracticeRoster(state: rosterState(.en, names: nil, profile: noAbility), engine: engine)
        XCTAssertEqual(unnamed.candidates.map(\.name), ["#25"]); XCTAssertTrue(unnamed.eligible.isEmpty)
    }
    /// The bag and the battle lists show the same individual under the same name, form tag included.
    func testRosterNameMatchesTheBagRow() throws {
        let engine = try engine()
        let unownLetter = PokemonForm.forms(speciesID: PokemonForm.unownSpeciesID)[1]
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for language in [AppLanguage.en, .ko] {
            let state = rosterState(language, names: [201: Self.storedNames], species: PokemonForm.unownSpeciesID,
                                    form: unownLetter)
            let url = folder.appendingPathComponent("\(language.rawValue).json")
            try JSONEncoder().encode(state).write(to: url)
            let store = CompanionStore(provider: RosterNoLineProvider(), clock: { Date(timeIntervalSince1970: 0) }, fileURL: url,
                                       dittoDisguiseRollingEnabled: false)
            let roster = PracticeRoster(state: store.state, engine: engine)
            XCTAssertEqual(roster.candidates.map(\.name), store.ownedIndividuals.map(\.name), "\(language)")
            XCTAssertEqual(roster.candidates.first?.name, "\(language == .en ? "English Name" : "한국어 이름") [\(unownLetter.symbol)]")
        }
    }
    /// The name is display only: what goes to the engine and to the online server is the same in every language, so
    /// two players with different app languages still compute the same battle.
    func testAppLanguageNeverReachesTheSnapshotOrTheBattleResult() throws {
        let engine = try engine()
        let opponent = try candidate("foe", species: 129, moves: ["splash"], engine: engine)
        func outcome(_ language: AppLanguage) throws -> (payload: Data, logHash: String) {
            let entry = try XCTUnwrap(PracticeRoster(state: rosterState(language, names: [25: Self.storedNames]), engine: engine).eligible.first)
            let snapshot = try XCTUnwrap(entry.snapshot)
            let battle = PracticeBattle(engine: engine)
            battle.start(player: entry, opponent: opponent, mode: .manual, seed: [1, 2, 3, 4])
            for _ in 0..<50 where battle.phase == .running { battle.choose(slot: 1) }
            XCTAssertEqual(battle.phase, .finished)
            return (try BattleJSON.encoder().encode(OnlineBattleSnapshot(snapshot: snapshot, hp: 1)), try XCTUnwrap(battle.result).logHash)
        }
        let english = try outcome(.en), korean = try outcome(.ko)
        XCTAssertEqual(english.payload, korean.payload)
        XCTAssertEqual(english.logHash, korean.logHash)
        XCTAssertNil(String(data: english.payload, encoding: .utf8)?.range(of: "English Name"))
    }
    /// Practice turns are 15 s (03B-5); the 30 s proposal for online battles is separate.
    func testManualTimeoutActsOnceAtFifteenSeconds() throws {
        XCTAssertEqual(PracticeBattle.manualTurnSeconds, 15)
        let engine = try engine(); var now = 0.0
        let model = PracticeBattle(engine: engine, clock: { now })
        model.start(player: try candidate("a", engine: engine), opponent: try candidate("b", engine: engine), mode: .manual, seed: [1,2,3,4])
        XCTAssertEqual(model.phase, .running); XCTAssertEqual(model.view?.turn, 1); XCTAssertEqual(model.remainingSeconds, 15)
        now = 14.9; model.tick(); XCTAssertEqual(model.view?.turn, 1); XCTAssertEqual(model.remainingSeconds, 1)
        now = 15; model.tick(); XCTAssertEqual(model.view?.turn, 2); XCTAssertEqual(model.remainingSeconds, 15)
        model.tick(); XCTAssertEqual(model.view?.turn, 2)
        XCTAssertTrue(model.messages(L(.ko)).contains { $0.contains("시간 초과") })
        // The next turn gets the full limit again, from the moment it began.
        now = 29.9; model.tick(); XCTAssertEqual(model.view?.turn, 2)
        now = 30; model.tick(); XCTAssertEqual(model.view?.turn, 3)
        model.prepareSelection(); XCTAssertEqual(model.remainingSeconds, 15)
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
        now = 15; model.choose(slot: 2)
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
        XCTAssertTrue(model.notice?.text(L(.ko)).contains("정보") == true)
        XCTAssertEqual(PracticeText.log("|-status|p1a: Test|par", names: ["p1": "내 개체"], l: L(.ko)), "내 개체 · 마비 상태가 되었습니다.")
        XCTAssertEqual(PracticeText.log("|move|p1a: Test|Untranslated Move", names: ["p1": "내 개체"], l: L(.ko)), "내 개체 · Untranslated Move 사용")
        XCTAssertEqual(PracticeText.log("|-weather|RainDance", names: [:], l: L(.ko)), "날씨 · RainDance")
        XCTAssertNotNil(PracticeText.log("|-future-event|p1a: Test|new effect", names: [:], l: L(.ko)))
        XCTAssertNil(PracticeText.log("", names: [:], l: L(.ko)))
    }

    func testPauseFreezesManualDeadlineAndAutomaticStepUntilResume() throws {
        let engine = try engine(); var now = 0.0
        let model = PracticeBattle(engine: engine, clock: { now })
        model.start(player: try candidate("a", engine: engine), opponent: try candidate("b", engine: engine), mode: .manual, seed: [1,2,3,4])
        now = 5; model.pause()
        XCTAssertTrue(model.isPaused); XCTAssertEqual(model.remainingSeconds, 10)
        now = 500; model.tick(); model.choose(slot: 1)
        XCTAssertEqual(model.view?.turn, 1); XCTAssertEqual(model.remainingSeconds, 10)
        XCTAssertFalse(model.messages(L(.ko)).contains { $0.contains("시간 초과") })
        model.resume()
        XCTAssertFalse(model.isPaused)
        now = 509.9; model.tick(); XCTAssertEqual(model.view?.turn, 1)
        now = 510; model.tick(); XCTAssertEqual(model.view?.turn, 2)
        XCTAssertTrue(model.messages(L(.ko)).contains { $0.contains("시간 초과") })
        // The automatic step (due at 510.6) keeps its remaining 0.4 s across a pause.
        model.mode = .automatic; now = 510.2; model.pause()
        now = 900; model.tick(); XCTAssertEqual(model.view?.turn, 2)
        model.resume(); now = 900.3; model.tick(); XCTAssertEqual(model.view?.turn, 2)
        now = 901; model.tick(); XCTAssertEqual(model.view?.turn, 3)
        model.resume(); model.cancel(); model.pause()
        XCTAssertFalse(model.isPaused, "only a running battle can be paused")
    }

    func testChangingSelectionClearsPreviousBattlePreviewAndResult() throws {
        let engine = try engine(); let model = PracticeBattle(engine: engine)
        model.start(player: try candidate("a", species: 25, moves: ["thunderbolt"], engine: engine),
                    opponent: try candidate("b", species: 129, moves: ["splash"], engine: engine), mode: .manual, seed: [1,2,3,4])
        model.choose(slot: 1); XCTAssertEqual(model.phase, .finished)
        model.prepareSelection()
        XCTAssertEqual(model.phase, .ready); XCTAssertNil(model.view); XCTAssertNil(model.result)
        XCTAssertTrue(model.messages(L(.ko)).isEmpty); XCTAssertTrue(model.request.moves.isEmpty)
    }

    func testEventsMirrorTheLogAndLeaveTheTextMessagesAlone() throws {
        let engine = try engine(); var now = 0.0
        let model = PracticeBattle(engine: engine, clock: { now })
        XCTAssertTrue(model.events.isEmpty)
        model.start(player: try candidate("a", species: 25, moves: ["thunderbolt"], engine: engine),
                    opponent: try candidate("b", species: 129, moves: ["splash"], engine: engine), mode: .automatic, seed: [1,2,3,4])
        let opening = model.events
        guard opening.count >= 3, case .switchIn(.player, _, _) = opening[0], case .switchIn(.opponent, _, _) = opening[1],
              case .turn(1) = opening[2] else { return XCTFail("\(opening)") }
        XCTAssertTrue(opening.contains(.abilityRevealed(.player, abilityID: "pressure")), "\(opening)")
        XCTAssertTrue(opening.contains(.abilityRevealed(.opponent, abilityID: "pressure")))
        XCTAssertTrue(model.messages(L(.ko)).contains { $0.contains("특성 공개: pressure") })
        let messageCount = model.messages(L(.ko)).count
        now = 1; model.tick()
        XCTAssertEqual(model.phase, .finished)
        XCTAssertTrue(model.events.starts(with: opening))
        XCTAssertTrue(model.events.contains(.faint(.opponent)))
        XCTAssertEqual(model.events.first { if case .end = $0 { true } else { false } }, .end(winner: .player))
        XCTAssertGreaterThan(model.messages(L(.ko)).count, messageCount)
    }
    func testTimeoutAppendsOneTimedOutEventBeforeTheTurnItPicked() throws {
        let engine = try engine(); var now = 0.0
        let model = PracticeBattle(engine: engine, clock: { now })
        model.start(player: try candidate("a", engine: engine), opponent: try candidate("b", engine: engine), mode: .manual, seed: [1,2,3,4])
        XCTAssertFalse(model.events.contains(.timedOut))
        let before = model.events.count
        now = 15; model.tick()
        XCTAssertEqual(model.events.filter { $0 == .timedOut }.count, 1)
        XCTAssertEqual(model.events.dropFirst(before).first, .timedOut)
        XCTAssertTrue(model.events.dropFirst(before + 1).contains { if case .move = $0 { true } else { false } })
        model.tick()
        XCTAssertEqual(model.events.filter { $0 == .timedOut }.count, 1)
    }
    func testEventsResetOnStartAndPrepareSelection() throws {
        let engine = try engine(); var now = 0.0
        let model = PracticeBattle(engine: engine, clock: { now })
        let a = try candidate("a", species: 25, moves: ["thunderbolt"], engine: engine)
        let b = try candidate("b", species: 129, moves: ["splash"], engine: engine)
        model.start(player: a, opponent: b, mode: .manual, seed: [1,2,3,4])
        let first = model.events
        now = 15; model.tick()
        XCTAssertGreaterThan(model.events.count, first.count)
        model.start(player: a, opponent: b, mode: .manual, seed: [1,2,3,4])
        XCTAssertEqual(model.events, first)
        model.prepareSelection()
        XCTAssertTrue(model.events.isEmpty)
    }

}
