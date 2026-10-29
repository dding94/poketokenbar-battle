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
