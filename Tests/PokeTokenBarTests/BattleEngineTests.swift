import XCTest
@testable import PokeTokenBar

final class BattleEngineTests: XCTestCase {
    private var engineURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("engine/dist/battle-engine.js")
    }
    private var expectedHash: String {
        get throws {
            try String(contentsOf: engineURL.deletingLastPathComponent().appendingPathComponent("battle-engine.sha256"), encoding: .utf8)
                .split(separator: " ")[0].description
        }
    }
    @MainActor func testLoadsVersionThroughJSONBoundary() throws {
        let engine = try BattleEngine(url: engineURL, expectedHash: expectedHash)
        let data = Data(try engine.call(.version).utf8)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(value["engine"], "@pkmn/sim@0.10.12")
        XCTAssertEqual(value["rules"], "gen9-notera-noitems-v1")
    }
    @MainActor func testMissingBundleIsAnExplicitError() {
        XCTAssertThrowsError(try BattleEngine(url: nil, expectedHash: "")) {
            XCTAssertEqual($0 as? BattleEngine.Failure, .missingBundle)
        }
    }
    @MainActor func testModifiedBundleIsRejectedBeforeEvaluation() {
        XCTAssertThrowsError(try BattleEngine(url: engineURL, expectedHash: String(repeating: "0", count: 64))) {
            XCTAssertEqual($0 as? BattleEngine.Failure, .checksumMismatch)
        }
    }
    @MainActor func testUntrustedJSONNeverBecomesJavaScriptSource() throws {
        let engine = try BattleEngine(url: engineURL, expectedHash: expectedHash)
        XCTAssertThrowsError(try engine.call(.createBattle, arguments: [">eval globalThis.hacked=true"])) {
            XCTAssertEqual($0 as? BattleEngine.Failure, .engine("invalid_json"))
        }
        XCTAssertNoThrow(try engine.call(.version))
    }
    @MainActor func testWrapperCallsDescribeMovesAndTypeChartThroughTheRepoBundle() throws {
        let engine = try BattleEngine(url: engineURL, expectedHash: expectedHash)
        struct Described: Decodable { let moves: [PracticeMoveInfo] }
        let described: Described = try BattleJSON.decode(engine.call(.describeMoves, arguments: [BattleJSON.encode(["volt-tackle", "splash"])]))
        XCTAssertEqual(described.moves.map(\.id), ["volttackle", "splash"])
        XCTAssertEqual(described.moves.first?.basePower, 120)
        XCTAssertEqual(described.moves.first?.type, "Electric")
        XCTAssertNil(described.moves.last?.accuracy)
        XCTAssertThrowsError(try engine.call(.describeMoves, arguments: [BattleJSON.encode(["nosuchmove"])])) {
            XCTAssertEqual($0 as? BattleEngine.Failure, .engine("invalid_moves"))
        }
        let chart: PracticeTypeChart = try BattleJSON.decode(engine.call(.typeChart))
        XCTAssertEqual(chart.types.count, 18)
        XCTAssertEqual(chart.damage["Electric"]?["Water"], 2)
        XCTAssertEqual(chart.damage["Electric"]?["Ground"], 0)
        XCTAssertEqual(chart.damage["Steel"]?["Water"], 0.5)
    }
    /// Snapshots record the policy version the engine runs, and every practice temperament is an engine policy.
    @MainActor func testEngineRunsTheSnapshotPolicyVersionAndEveryPracticeTemperament() throws {
        let engine = try BattleEngine(url: engineURL, expectedHash: expectedHash)
        let ivs = Dictionary(uniqueKeysWithValues: ["hp", "attack", "defense", "special-attack", "special-defense", "speed"].map { ($0, 31) })
        let set = BattleSet(speciesNum: 25, form: nil, level: 50, gender: .male, nature: "hardy", ability: "static",
                            moves: ["thunderbolt", "quick-attack"], ivs: ivs, shiny: false)
        func config(_ policy: String?) -> BattleConfig {
            BattleConfig(seed: [1, 2, 3, 4], policySeed: 42, p1: .init(name: "p1", set: set), p2: .init(name: "p2", set: set, policy: policy))
        }
        struct Created: Decodable { let id: String }
        for policy in [nil] + PracticeTemperament.allCases.map({ Optional($0.policyID) }) {
            let created: Created = try BattleJSON.decode(engine.call(.createBattle, arguments: [BattleJSON.encode(config(policy))]))
            let id = try BattleJSON.encode(created.id)
            for side in ["p1", "p2"] {
                _ = try engine.call(.choose, arguments: [id, BattleJSON.encode(side), BattleJSON.encode(["type": "auto"])])
            }
            let result: BattleResult = try BattleJSON.decode(engine.call(.result, arguments: [id]))
            XCTAssertEqual(result.inputLog.policyVersion, BattleSnapshot.policy)
            XCTAssertEqual(result.inputLog.config.p2.policy, policy)
            XCTAssertEqual(result.inputLog.choices.count, 2)
            _ = try engine.call(.destroy, arguments: [id])
        }
        XCTAssertThrowsError(try engine.call(.createBattle, arguments: [BattleJSON.encode(config("reckless"))])) {
            XCTAssertEqual($0 as? BattleEngine.Failure, .engine("invalid_policy"))
        }
    }
}
