import XCTest
@testable import PokeTokenBar

final class OnlineBattleModelsTests: XCTestCase {
    func testRelayRejectsUnknownKindsInvalidSlotsAndExtraCommandKeys() throws {
        for text in [#"{"kind":"eval","command":">eval test"}"#, #"{"kind":"move","slot":0}"#, #"{"kind":"move","slot":5}"#, #"{"kind":"move","slot":1,"command":">eval test"}"#, #"{"kind":"policy","slot":1}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(OnlineBattleRelayToken.self, from: Data(text.utf8)))
        }
    }
    func testRelayRoundTripPreservesOnlyClosedTokens() throws {
        for value in [OnlineBattleRelayToken.move(1), .move(4), .timeout, .policy] {
            XCTAssertEqual(try JSONDecoder().decode(OnlineBattleRelayToken.self, from: JSONEncoder().encode(value)), value)
        }
        XCTAssertThrowsError(try JSONEncoder().encode(OnlineBattleRelayToken.move(0)))
    }
    func testServerSnapshotAndEngineConfigAreSeparateShapes() throws {
        let set = BattleSet(speciesNum: 25, form: nil, level: 50, gender: .male, nature: "hardy", ability: "static", moves: ["thunderbolt"], ivs: [:], shiny: false)
        let info = BattlePublicInfo(speciesNum: 25, species: "Pikachu", level: 50, types: ["Electric"], stats: ["hp": 100])
        let snapshot = OnlineBattleSnapshot(instanceId: "synthetic-individual", set: set, publicInfo: info, hp: 50)
        let shape = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        XCTAssertEqual(shape.keys.sorted(), ["hp", "instanceId", "public", "set"])
        let player = OnlineBattleEnginePlayer(name: "p1", set: set, hp: 50, policy: "standard")
        let config = OnlineBattleConfig(readyToken: "synthetic-ready", engineHash: "hash", rulesVersion: "rules", policyVersion: "policy", relayVersion: "relay-v1", seed: [1,2,3,4], policySeed: 1, p1: player, p2: player)
        let engineShape = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(config.engineConfig)) as? [String: Any])
        XCTAssertEqual(engineShape.keys.sorted(), ["p1", "p2", "policySeed", "seed"])
    }
}
