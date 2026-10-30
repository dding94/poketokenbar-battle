import XCTest
@testable import PokeTokenBar

/// A practice opponent's temperament comes from its nature: the stat the nature raises picks the engine policy.
@MainActor
final class PracticeTemperamentTests: XCTestCase {
    private var engineURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("engine/dist/battle-engine.js")
    }

    /// The 03B-5 table, one row per nature.
    private static let table: [(PokemonNature, PracticeTemperament)] = [
        (.lonely, .aggressive), (.brave, .aggressive), (.adamant, .aggressive), (.naughty, .aggressive),
        (.modest, .aggressive), (.mild, .aggressive), (.quiet, .aggressive), (.rash, .aggressive),
        (.bold, .tactical), (.relaxed, .tactical), (.impish, .tactical), (.lax, .tactical),
        (.calm, .tactical), (.gentle, .tactical), (.sassy, .tactical), (.careful, .tactical),
        (.timid, .standard), (.hasty, .standard), (.jolly, .standard), (.naive, .standard),
        (.hardy, .erratic), (.docile, .erratic), (.serious, .erratic), (.bashful, .erratic), (.quirky, .erratic),
    ]

    func testEveryNatureMapsToItsTemperament() {
        XCTAssertEqual(Self.table.count, 25)
        XCTAssertEqual(Set(Self.table.map(\.0)), Set(PokemonNature.allCases), "every nature exactly once")
        for (nature, temperament) in Self.table {
            XCTAssertEqual(PracticeTemperament(nature: nature), temperament, "\(nature)")
        }
    }

    /// The rule behind the table, against the engine's own natures: a raised attack or special attack is aggressive,
    /// a raised defense or special defense tactical, a raised speed standard, and a neutral nature erratic.
    func testTheStatANatureRaisesInTheEnginePicksTheTemperament() throws {
        let engine = try BattleEngine(url: engineURL)
        func stats(_ nature: PokemonNature) throws -> [String: Int] {
            let ivs = ["hp", "attack", "defense", "special-attack", "special-defense", "speed"].reduce(into: [String: Int]()) { $0[$1] = 31 }
            let set = BattleSet(speciesNum: 25, form: nil, level: 50, gender: .male, nature: nature.rawValue,
                                ability: "static", moves: ["thunderbolt"], ivs: ivs, shiny: false)
            let info: BattlePublicInfo = try BattleJSON.decode(engine.call(.describeSet, arguments: [BattleJSON.encode(set)]))
            return info.stats
        }
        let neutral = try stats(.hardy)
        for nature in PokemonNature.allCases {
            let raised = Set(try stats(nature).filter { $0.value > neutral[$0.key, default: .max] }.map(\.key))
            let expected: PracticeTemperament?
            switch raised {
            case ["atk"], ["spa"]: expected = .aggressive
            case ["def"], ["spd"]: expected = .tactical
            case ["spe"]: expected = .standard
            case []: expected = .erratic
            default: expected = nil
            }
            XCTAssertEqual(PracticeTemperament(nature: nature), expected, "\(nature) raises \(raised.sorted())")
        }
    }

    /// The ids the engine's auto-v2 policy accepts in `config.pN.policy`.
    func testPolicyIDsAreTheEnginePolicyNames() {
        XCTAssertEqual(PracticeTemperament.allCases.map(\.policyID), ["standard", "aggressive", "tactical", "erratic"])
    }

    /// The opponent (p2) runs its temperament's engine policy; the player's automatic turns stay standard (p1 nil).
    /// The input log is the engine's own copy of the config, and replaying it gives the same battle.
    func testTheOpponentRunsItsTemperamentAndThePlayerStaysStandard() throws {
        let engine = try BattleEngine(url: engineURL)
        func candidate(_ id: String, species: Int, move: String, nature: PokemonNature) throws -> PracticeCandidate {
            var profile = PokemonProfile.generate(seed: 42, instanceID: id)
            profile.level = 50; profile.gender = .male; profile.abilityName = "static"
            profile.moves = [PokemonKnownMove(name: move, learnedAtLevel: 1)]
            let snapshot = try BattleSnapshot.make(speciesID: species, nature: nature, profile: profile, using: engine)
            return PracticeCandidate(id: id, name: id, snapshot: snapshot, blockedReason: nil)
        }
        // An adamant player would be aggressive as an opponent; as the player it stays standard.
        let player = try candidate("player", species: 25, move: "thunderbolt", nature: .adamant)
        for nature in [PokemonNature.adamant, .careful, .jolly, .quirky] {
            let opponent = try candidate("opponent-\(nature)", species: 129, move: "splash", nature: nature)
            let battle = PracticeBattle(engine: engine, clock: { 0 })
            battle.start(player: player, opponent: opponent, mode: .automatic, seed: [1, 2, 3, 4])
            battle.runToEnd()
            let log = try XCTUnwrap(battle.result?.inputLog, "\(nature)")
            XCTAssertEqual(log.policyVersion, BattleSnapshot.policy)
            XCTAssertEqual(log.config.p2.policy, PracticeTemperament(nature: nature).policyID, "\(nature)")
            XCTAssertNil(log.config.p1.policy, "the player's automatic turns stay standard")
            struct Replay: Decodable { let logHash: String }
            let replay: Replay = try BattleJSON.decode(engine.call(.replay, arguments: [BattleJSON.encode(log)]))
            XCTAssertEqual(replay.logHash, battle.result?.logHash, "\(nature)")
        }
    }

    func testACandidateTakesTheTemperamentOfItsNature() throws {
        let engine = try BattleEngine(url: engineURL)
        func candidate(_ nature: PokemonNature) throws -> PracticeCandidate {
            var profile = PokemonProfile.generate(seed: 42, instanceID: "temperament-\(nature)")
            profile.level = 50; profile.gender = .male; profile.abilityName = "static"
            profile.moves = [PokemonKnownMove(name: "thunderbolt", learnedAtLevel: 1)]
            let snapshot = try BattleSnapshot.make(speciesID: 25, nature: nature, profile: profile, using: engine)
            return PracticeCandidate(id: snapshot.instanceID, name: "Pikachu", snapshot: snapshot, blockedReason: nil)
        }
        XCTAssertEqual(try candidate(.adamant).temperament, .aggressive)
        XCTAssertEqual(try candidate(.careful).temperament, .tactical)
        XCTAssertEqual(try candidate(.jolly).temperament, .standard)
        XCTAssertEqual(try candidate(.quirky).temperament, .erratic)
        XCTAssertNil(PracticeCandidate(id: "blocked", name: "?", snapshot: nil, blockedReason: "no moves").temperament)
    }
}
