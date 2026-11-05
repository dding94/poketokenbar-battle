import CryptoKit
import XCTest
@testable import PokeTokenBar

/// A live online battle between two Pokémon the test picks, with real engine-checked public info. Synthetic data
/// only; the golden "manual" battle supplies the room, config and seeds.
@MainActor
enum OnlineBattleHintFixture {
    struct Mon {
        var species: Int
        var moves: [String]
        var ability = "pressure"
        var level = 50
    }
    private static let ivs = ["hp": 31, "attack": 31, "defense": 31, "special-attack": 31, "special-defense": 31, "speed": 31]

    private static func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(BattleJSON.encode(value).utf8))
    }

    static func battle(p1: Mon, p2: Mon) throws -> OnlineBattleView {
        let engine = try BattleEngine(url: OnlineBattleArenaFixture.engineURL)
        let golden = try OnlineBattleArenaFixture.golden("manual")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: BattleJSON.encoder().encode(golden)) as? [String: Any])
        var config = try XCTUnwrap(json["config"] as? [String: Any])
        for (seat, mon) in [("p1", p1), ("p2", p2)] {
            let set = BattleSet(speciesNum: mon.species, form: nil, level: mon.level, gender: .genderless, nature: "hardy",
                                ability: mon.ability, moves: mon.moves, ivs: ivs, shiny: false)
            let described: BattlePublicInfo = try BattleJSON.decode(engine.call(.describeSet, arguments: [BattleJSON.encode(set)]))
            let hp = try XCTUnwrap(described.stats["hp"])
            var side = try XCTUnwrap(json[seat] as? [String: Any])
            side["snapshot"] = ["instanceId": "instance-\(seat)", "set": try object(set), "public": try object(described), "hp": hp] as [String: Any]
            json[seat] = side
            var player = try XCTUnwrap(config[seat] as? [String: Any])
            player["set"] = try object(set); player["hp"] = hp
            config[seat] = player
        }
        json["config"] = config
        json["state"] = "RUNNING"; json["result"] = NSNull(); json["reason"] = NSNull()
        json["journal"] = [Any](); json["roundSeq"] = 0; json["deadline"] = NSNull(); json["ownChoice"] = NSNull()
        return try JSONDecoder().decode(OnlineBattleView.self, from: JSONSerialization.data(withJSONObject: json))
    }

    static func trainer(_ seat: OnlineBattleSide) -> String { seat == .p1 ? "trainer-one" : "trainer-two" }

    static func resolver(_ battle: OnlineBattleView, seat: OnlineBattleSide) throws -> OnlineBattleResolver {
        try OnlineBattleResolver(battle: battle, localTrainerID: trainer(seat), engine: BattleEngine(url: OnlineBattleArenaFixture.engineURL))
    }
}

/// T17: the move cards of the online arena show the matchup, STAB and power/accuracy of my own moves, worked
/// out from my own set and the foe's public types only.
@MainActor
final class OnlineBattleMoveHintTests: XCTestCase {
    private typealias Mon = OnlineBattleHintFixture.Mon
    private let charmander = Mon(species: 4, moves: ["ember", "scratch", "quick-attack", "growl"])
    private let bulbasaur = Mon(species: 1, moves: ["splash"])

    private func resolver(_ me: Mon, _ foe: Mon, seat: OnlineBattleSide = .p1) throws -> OnlineBattleResolver {
        let battle = seat == .p1 ? try OnlineBattleHintFixture.battle(p1: me, p2: foe) : try OnlineBattleHintFixture.battle(p1: foe, p2: me)
        return try OnlineBattleHintFixture.resolver(battle, seat: seat)
    }
    private func playFirstRound(_ resolver: OnlineBattleResolver) throws {
        try resolver.consume(journal: [OnlineBattlePair(roundSeq: 1, p1: .move(1), p2: .move(1), releasedAt: 0)])
    }

    // MARK: the matchup, STAB and power of my moves

    func testFireMoveAgainstAGrassTypeIsDoubledAndSameTypeShowsStab() throws {
        for seat in [OnlineBattleSide.p1, .p2] {
            let resolver = try resolver(charmander, bulbasaur, seat: seat); defer { resolver.close() }
            let hints = resolver.moveHints()
            let ember = try XCTUnwrap(hints[1], "\(seat)")
            XCTAssertEqual(ember.multiplier, 2, "Fire against Grass/Poison, \(seat)")
            XCTAssertTrue(ember.stab, "Charmander is a Fire type, \(seat)")
            XCTAssertEqual(ember.info.basePower, 40); XCTAssertEqual(ember.info.accuracy, 100); XCTAssertEqual(ember.info.category, "Special")
            let scratch = try XCTUnwrap(hints[2])
            XCTAssertEqual(scratch.multiplier, 1); XCTAssertFalse(scratch.stab, "Normal is not Charmander's type")
            XCTAssertEqual(scratch.info.basePower, 40)
            let quick = try XCTUnwrap(hints[3])
            XCTAssertEqual(quick.info.priority, 1)
            let growl = try XCTUnwrap(hints[4])
            XCTAssertTrue(growl.info.isStatus); XCTAssertNil(growl.multiplier, "a status move has no matchup"); XCTAssertFalse(growl.stab)
            XCTAssertEqual(Set(hints.keys), [1, 2, 3, 4])
        }
    }

    func testHintsExistOnlyWhileTheRequestIsAMoveRequest() throws {
        let resolver = try resolver(charmander, bulbasaur); defer { resolver.close() }
        XCTAssertEqual(resolver.request.kind, "move")
        XCTAssertFalse(resolver.moveHints().isEmpty)
        resolver.close()
        XCTAssertTrue(resolver.moveHints().isEmpty, "a closed resolver offers nothing")
    }

    func testStruggleAndRechargeHaveNoHint() throws {
        // The golden "recharge" battle ends with Mew's forced Recharge: a forced request carries no listed move.
        let battle = try OnlineBattleArenaFixture.golden("recharge")
        let resolver = try OnlineBattleResolver(battle: battle, localTrainerID: "trainer-one", engine: BattleEngine(url: OnlineBattleArenaFixture.engineURL))
        defer { resolver.close() }
        for count in 0...battle.journal.count {
            try resolver.consume(journal: Array(battle.journal.prefix(count)))
            let hints = resolver.moveHints()
            for move in resolver.request.moves where move.id == "recharge" || move.id == "struggle" {
                XCTAssertNil(hints[move.slot], "round \(count): \(move.id)")
            }
        }
    }

    // MARK: agreement with the engine

    private enum Verdict: String { case superEffective = "supereffective", resisted, immune, neutral }

    /// What the engine itself says about my first move hitting the foe, read from my side's battle log.
    private func engineVerdict(_ logs: [String]) throws -> Verdict {
        XCTAssertTrue(logs.contains { $0.hasPrefix("|move|p1a") || $0.hasPrefix("|move|p2a") }, "the round must have been played: \(logs)")
        for verdict in [Verdict.superEffective, .resisted, .immune] where logs.contains(where: { $0.hasPrefix("|-\(verdict.rawValue)|") }) {
            return verdict
        }
        return .neutral
    }

    private func verdict(_ multiplier: Double?) -> Verdict? {
        guard let multiplier else { return nil }
        return multiplier == 0 ? .immune : multiplier > 1 ? .superEffective : multiplier < 1 ? .resisted : .neutral
    }

    /// The hint's word on a matchup is the engine's: the chart is the engine's own, and every row of a table of
    /// real rounds (single and dual types, immunities, a cancelled pair, fixed damage) reads the same as the
    /// message the engine printed when the move landed.
    func testTheHintReadsTheSameAsWhatTheEngineSaysWhenTheMoveLands() throws {
        // (my species, my move, foe species, expected multiplier)
        let rows: [(Int, String, Int, Double)] = [
            (4, "ember", 1, 2), (4, "ember", 4, 0.5), (25, "thunderbolt", 27, 0), (25, "thunderbolt", 242, 1),
            (151, "ice-beam", 149, 4),   // Dragon/Flying
            (151, "ice-beam", 6, 1),     // Fire/Flying: x0.5 and x2 cancel out
            (151, "seismic-toss", 94, 0), // fixed damage still respects immunity
            (151, "seismic-toss", 1, 1),  // fixed damage ignores resistance, so no message
            (151, "night-shade", 242, 0),
        ]
        for seat in [OnlineBattleSide.p1, .p2] {
            for (species, move, foeSpecies, expected) in rows {
                let label = "\(seat) \(move) vs \(foeSpecies)"
                let resolver = try resolver(Mon(species: species, moves: [move]), Mon(species: foeSpecies, moves: ["splash"]), seat: seat)
                defer { resolver.close() }
                let hint = try XCTUnwrap(resolver.moveHints()[1], label)
                XCTAssertEqual(hint.multiplier, expected, label)
                let move1 = OnlineBattlePair(roundSeq: 1, p1: .move(1), p2: .move(1), releasedAt: 0)
                try resolver.consume(journal: [move1])
                let engineSays = try engineVerdict(resolver.logs)
                XCTAssertEqual(verdict(hint.multiplier), engineSays, "\(label): the hint and the engine disagree")
            }
        }
    }

    /// Freeze-Dry and Flying Press ignore the plain chart, so a multiplier from it would contradict the engine.
    /// Their card shows power and accuracy but no matchup.
    func testMovesThatBreakTheTypeChartShowNoMatchup() throws {
        let rows: [(Int, String, Int)] = [(144, "freeze-dry", 7), (214, "flying-press", 1), (644, "thousand-arrows", 6)]
        for (species, move, foeSpecies) in rows {
            let resolver = try resolver(Mon(species: species, moves: [move]), Mon(species: foeSpecies, moves: ["splash"]))
            defer { resolver.close() }
            let hint = try XCTUnwrap(resolver.moveHints()[1], move)
            XCTAssertNil(hint.multiplier, "\(move) has no chart-based matchup")
            XCTAssertGreaterThan(hint.info.basePower, 0)
        }
    }

    // MARK: only public information

    /// Everything the hint needs is my own set, my own types and the foe's public types: a foe with a completely
    /// different hidden set (moves, ability) and the same public species changes nothing.
    func testTheFoesHiddenSetNeverChangesTheHints() throws {
        let plain = Mon(species: 1, moves: ["splash"])
        let armed = Mon(species: 1, moves: ["flamethrower", "earthquake", "ice-beam", "thunderbolt"], ability: "chlorophyll")
        for seat in [OnlineBattleSide.p1, .p2] {
            let a = try resolver(charmander, plain, seat: seat), b = try resolver(charmander, armed, seat: seat)
            defer { a.close(); b.close() }
            XCTAssertEqual(a.moveHints(), b.moveHints(), "\(seat)")
            XCTAssertFalse(a.moveHints().isEmpty)
        }
    }

    /// The foe's side of the hint is its public types (a different species changes the matchup), and the
    /// own side's STAB is my own type.
    func testTheMatchupFollowsTheFoesPublicTypesAndStabMyOwn() throws {
        let water = try resolver(charmander, Mon(species: 7, moves: ["splash"])); defer { water.close() }
        XCTAssertEqual(water.moveHints()[1]?.multiplier, 0.5, "Fire against Water")
        let flying = try resolver(charmander, Mon(species: 149, moves: ["splash"])); defer { flying.close() }
        XCTAssertEqual(flying.moveHints()[1]?.multiplier, 1, "Fire against Dragon/Flying")
        let psychic = try resolver(Mon(species: 151, moves: ["ember", "psychic"]), bulbasaur); defer { psychic.close() }
        XCTAssertEqual(psychic.moveHints()[1]?.stab, false, "Mew is not a Fire type"); XCTAssertEqual(psychic.moveHints()[2]?.stab, true)
    }

    /// Asking for hints must not touch the battle: the golden battles replay to the same result with hints read
    /// before every round.
    func testReadingHintsLeavesTheBattleResultUntouched() throws {
        for name in ["manual", "timeout", "imprison", "recharge", "pp"] {
            let battle = try OnlineBattleArenaFixture.golden(name)
            let resolver = try OnlineBattleResolver(battle: battle, localTrainerID: "trainer-two", engine: BattleEngine(url: OnlineBattleArenaFixture.engineURL))
            defer { resolver.close() }
            for count in 0..<battle.journal.count {
                _ = resolver.moveHints()
                try resolver.consume(journal: Array(battle.journal.prefix(count + 1)))
            }
            XCTAssertEqual(try resolver.terminalReport(), battle.result, name)
        }
    }

    // MARK: a failed load only drops the hints

    private func stubEngine(_ source: String) throws -> BattleEngine {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-t17-stub-\(UUID().uuidString).js")
        let data = Data(source.utf8)
        try data.write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        return try BattleEngine(url: url, expectedHash: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    func testAnEngineThatCannotDescribeAnythingGivesNoDataAndDoesNotThrow() throws {
        let engine = try stubEngine("""
            globalThis.PTBEngine = {
              typeChart: () => JSON.stringify({ok: false, error: 'engine_failure'}),
              describeMoves: () => JSON.stringify({ok: false, error: 'invalid_moves'}),
            };
            """)
        let data = OnlineBattleResolver.loadHintData(engine: engine, ownMoves: ["ember", "scratch"])
        XCTAssertNil(data.chart); XCTAssertTrue(data.moves.isEmpty)
    }

    func testWithoutAChartTheCardKeepsPowerAndStabButNoMatchup() throws {
        let engine = try stubEngine("""
            globalThis.PTBEngine = {
              typeChart: () => JSON.stringify({ok: false, error: 'engine_failure'}),
              describeMoves: (ids) => JSON.stringify({moves: ids.map(id => ({id: id, name: id, type: 'Fire', category: 'Special',
                basePower: 40, accuracy: 100, priority: 0, pp: 25, fixedDamage: false, variableType: false}))}),
            };
            """)
        let data = OnlineBattleResolver.loadHintData(engine: engine, ownMoves: ["ember"])
        XCTAssertNil(data.chart)
        let info = try XCTUnwrap(data.moves["ember"])
        let hint = PracticeMoveHint(info: info, chart: data.chart, attackerTypes: ["Fire"], defenderTypes: ["Grass"])
        XCTAssertNil(hint.multiplier); XCTAssertTrue(hint.stab); XCTAssertEqual(hint.info.basePower, 40)
    }

    func testTheRealEngineLoadsTheChartAndEveryOwnMove() throws {
        let engine = try BattleEngine(url: OnlineBattleArenaFixture.engineURL)
        let data = OnlineBattleResolver.loadHintData(engine: engine, ownMoves: ["ember", "quick-attack"])
        XCTAssertEqual(data.chart?.types.count, 18)
        XCTAssertEqual(Set(data.moves.keys), ["ember", "quickattack"], "keyed by the engine's move id, as a request lists it")
    }

    // MARK: the card gets them

    func testTheArenaHandsEachCardItsOwnHintAndNothingElse() throws {
        let battle = try OnlineBattleHintFixture.battle(p1: charmander, p2: bulbasaur)
        let fixture = try OnlineBattleArenaFixture.arena(seat: .p1, custom: battle); defer { fixture.close() }
        XCTAssertEqual(fixture.model.moveHints, fixture.resolver.moveHints())
        let arena = OnlineBattleArena(model: fixture.model, l: L(.ko), artwork: false, speciesNameProvider: OnlineBattleSyntheticNameProvider(),
                                      speciesNameStore: PokemonNameDisplayStore())
        let moves = try XCTUnwrap(fixture.model.request?.moves)
        XCTAssertEqual(moves.count, 4)
        for move in moves {
            let card = arena.moveCard(move)
            XCTAssertEqual(card.hint, fixture.model.moveHints[move.slot], "slot \(move.slot)")
            XCTAssertNotNil(card.hint, "slot \(move.slot)")
        }
        XCTAssertEqual(arena.moveCard(moves[0]).hint?.multiplier, 2)
        // A card whose hint is missing (a failed load) is the plain card.
        fixture.model.moveHints = [:]
        XCTAssertNil(arena.moveCard(moves[0]).hint)
    }
}
