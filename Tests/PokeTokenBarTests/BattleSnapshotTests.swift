import XCTest
@testable import PokeTokenBar

@MainActor
final class BattleSnapshotTests: XCTestCase {
    private func engine() throws -> BattleEngine {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try BattleEngine(url: root.appendingPathComponent("engine/dist/battle-engine.js"))
    }
    private func profile(id: String = "synthetic-individual-a") -> PokemonProfile {
        var p = PokemonProfile.generate(seed: 42, instanceID: id)
        p.level = 50; p.gender = .male; p.abilityName = "static"
        p.ivs = PokemonIVs(hp: 31, attack: 31, defense: 31, specialAttack: 31, specialDefense: 31, speed: 31)
        p.moves = [PokemonKnownMove(name: "thunderbolt", learnedAtLevel: 26)]
        return p
    }
    func testMapsIndividualValuesAndExcludesGrowthProgressFromHash() throws {
        let engine = try engine()
        var mon = MonState(baseID: 25, pathIDs: [25,26], stageIndex: 0, usedAtStage: 10,
                           rarity: .common, totalForms: 2, nature: .adamant, profile: profile())
        let a = try BattleSnapshot.from(mon, using: engine)
        mon.usedAtStage += 200; mon.profile?.growthTokens += 200
        let b = try BattleSnapshot.from(mon, using: engine)
        XCTAssertEqual(a.hash, b.hash)
        XCTAssertEqual(a.instanceID, "synthetic-individual-a")
        XCTAssertEqual(a.set.nature, "adamant")
        XCTAssertEqual(a.set.ivs["special-attack"], 31)
        XCTAssertEqual(a.publicInfo.stats["atk"], 82)
        XCTAssertEqual(a.publicInfo.stats["spa"], 63)
        XCTAssertEqual(a.publicInfo.stats["hp"], 110)
        XCTAssertEqual(a.set.moves, ["thunderbolt"])
        XCTAssertNoThrow(try a.validate(using: engine))
    }
    func testSameSpeciesDifferentInstancesNeverShareSnapshotIdentity() throws {
        let engine = try engine()
        let a = try BattleSnapshot.make(speciesID: 25, nature: .hardy, profile: profile(), using: engine)
        let b = try BattleSnapshot.make(speciesID: 25, nature: .hardy, profile: profile(id: "synthetic-b"), using: engine)
        XCTAssertNotEqual(a.hash, b.hash)
        XCTAssertNotEqual(a.instanceID, b.instanceID)
        var changed = profile(); changed.level = 51
        let c = try BattleSnapshot.make(speciesID: 25, nature: .hardy, profile: changed, using: engine)
        XCTAssertNotEqual(a.hash, c.hash)
    }
    func testMissingDataIsHeldWithoutInventingDefaults() throws {
        let engine = try engine()
        XCTAssertThrowsError(try BattleSnapshot.make(speciesID: 25, nature: nil, profile: profile(), using: engine)) {
            XCTAssertEqual($0 as? BattleSnapshot.Failure, .missingNature)
        }
        var p = profile(); p.abilityName = nil
        XCTAssertThrowsError(try BattleSnapshot.make(speciesID: 25, nature: .hardy, profile: p, using: engine)) {
            XCTAssertEqual($0 as? BattleSnapshot.Failure, .missingAbility)
        }
        p = profile(); p.moves = []
        XCTAssertThrowsError(try BattleSnapshot.make(speciesID: 25, nature: .hardy, profile: p, using: engine)) {
            XCTAssertEqual($0 as? BattleSnapshot.Failure, .missingMoves)
        }
    }
    func testInvalidMoveFormAndIVAreRejectedBySharedEngineValidation() throws {
        let engine = try engine()
        for invalid in ["not-a-move", ">eval"] {
            var p = profile(); p.moves = [PokemonKnownMove(name: invalid, learnedAtLevel: 1)]
            XCTAssertThrowsError(try BattleSnapshot.make(speciesID: 25, nature: .hardy, profile: p, using: engine)) {
                XCTAssertEqual($0 as? BattleEngine.Failure, .engine("invalid_moves"))
            }
        }
        XCTAssertThrowsError(try BattleSnapshot.make(speciesID: 25, form: PokemonForm("mega"), nature: .hardy, profile: profile(), using: engine)) {
            XCTAssertEqual($0 as? BattleEngine.Failure, .engine("invalid_form"))
        }
        var p = profile(); p.ivs.hp = 32
        XCTAssertThrowsError(try BattleSnapshot.make(speciesID: 25, nature: .hardy, profile: p, using: engine)) {
            XCTAssertEqual($0 as? BattleEngine.Failure, .engine("invalid_ivs"))
        }
    }
    func testPublicDescriptionDoesNotContainMoveOrAbility() throws {
        let snapshot = try BattleSnapshot.make(speciesID: 25, nature: .hardy, profile: profile(), using: engine())
        let text = String(decoding: try JSONEncoder().encode(snapshot.publicInfo), as: UTF8.self)
        XCTAssertFalse(text.contains("thunderbolt")); XCTAssertFalse(text.contains("static"))
    }
    func testSyntheticLegacySaveShapeRoundTripsWithoutMutatingGrowth() throws {
        var state = CompanionState()
        state.active = MonState(baseID: 25, pathIDs: [25,26], stageIndex: 0, usedAtStage: 123,
                                rarity: .common, totalForms: 2, nature: .hardy, profile: profile())
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(state)
        let restored = try JSONDecoder().decode(CompanionState.self, from: before)
        let snapshot = try BattleSnapshot.from(XCTUnwrap(restored.active), using: engine())
        XCTAssertEqual(snapshot.set.level, 50)
        XCTAssertEqual(try encoder.encode(state), before)
        XCTAssertEqual(try JSONDecoder().decode(BattleSnapshot.self, from: encoder.encode(snapshot)), snapshot)
    }
    func testDecodedUnknownSchemaAndForgedPublicStatsAreRejected() throws {
        let engine = try engine()
        let snapshot = try BattleSnapshot.make(speciesID: 25, nature: .hardy, profile: profile(), using: engine)
        let data = try JSONEncoder().encode(snapshot)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["schemaVersion", "publicInfo"] {
            var forged = original
            if key == "schemaVersion" { forged[key] = 2 }
            else {
                var info = try XCTUnwrap(forged[key] as? [String: Any])
                info["stats"] = ["hp": 99999]
                forged[key] = info
            }
            let decoded = try JSONDecoder().decode(BattleSnapshot.self, from: JSONSerialization.data(withJSONObject: forged))
            XCTAssertThrowsError(try decoded.validate(using: engine)) {
                XCTAssertEqual($0 as? BattleSnapshot.Failure, .invalidSchema)
            }
        }
    }

    func testUnresolvedProfileGenderAndIdentityAreRejected() throws {
        let engine = try engine()
        XCTAssertThrowsError(try BattleSnapshot.make(speciesID: 25, nature: .hardy, profile: nil, using: engine)) {
            XCTAssertEqual($0 as? BattleSnapshot.Failure, .missingProfile)
        }
        var p = profile(); p.gender = nil
        XCTAssertThrowsError(try BattleSnapshot.make(speciesID: 25, nature: .hardy, profile: p, using: engine)) {
            XCTAssertEqual($0 as? BattleSnapshot.Failure, .missingGender)
        }
        p = profile(id: "")
        XCTAssertThrowsError(try BattleSnapshot.make(speciesID: 25, nature: .hardy, profile: p, using: engine)) {
            XCTAssertEqual($0 as? BattleSnapshot.Failure, .invalidIdentity)
        }
        let mon = MonState(baseID: 25, pathIDs: [], stageIndex: 0, usedAtStage: 0,
                           rarity: .common, totalForms: 1, nature: .hardy, profile: profile())
        XCTAssertThrowsError(try BattleSnapshot.from(mon, using: engine)) {
            XCTAssertEqual($0 as? BattleSnapshot.Failure, .invalidSchema)
        }
    }

}
