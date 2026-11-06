import XCTest
@testable import PokeTokenBar

@MainActor
final class OnlineBattleReplayVisibleNamesTests: XCTestCase {
    private struct Golden: Decodable { let battle: OnlineBattleView }

    func testP2RewindMapsOnlyCurrentlyRevealedFoeMoves() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "golden", withExtension: "json", subdirectory: "OnlineBattle"))
        let battle = try XCTUnwrap(JSONDecoder().decode([Golden].self, from: Data(contentsOf: url)).first?.battle)
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let replay = try OnlineBattleReplay(battle: battle, localTrainerID: "trainer-two", l: L(.ko), engineFactory: { _ in
            try BattleEngine(url: sourceRoot.appendingPathComponent("engine/dist/battle-engine.js"))
        })
        XCTAssertEqual(replay.localSide, .p2)
        let savedFoe = try XCTUnwrap(battle.p1.snapshot)
        let before = OnlineBattleReplayVisibleNames.slugs(visible: replay.frames[0].view.p1, snapshot: savedFoe)
        XCTAssertTrue(before.moves.isEmpty)
        XCTAssertTrue(before.abilities.isEmpty)
        let revealed = OnlineBattleReplayVisibleNames.slugs(visible: replay.frames[1].view.p1, snapshot: savedFoe)
        XCTAssertEqual(revealed.moves, ["quickattack": "quick-attack"])
        XCTAssertFalse(revealed.moves.keys.contains("thunderbolt"))
        let rewound = OnlineBattleReplayVisibleNames.slugs(visible: replay.frames[0].view.p1, snapshot: savedFoe)
        XCTAssertTrue(rewound.moves.isEmpty, "Returning to the first frame must hide future moves again")
    }

    func testVisibleHyphenatedAbilityAndMoveMapWithoutLeakingUnrevealedEntries() {
        let original = OnlineBattleScreenRenderingTests.snapshot()
        let set = BattleSet(speciesNum: 25, form: nil, level: 50, gender: .male, nature: "Hardy",
                            ability: "run-away", moves: ["quick-attack", "future-sight"], ivs: [:], shiny: false)
        let snapshot = OnlineBattleSnapshot(instanceId: "synthetic", set: set, publicInfo: original.publicInfo, hp: 90)
        let visible = BattleView.Pokemon(speciesNum: 25, species: "Pikachu", level: 50, types: ["Electric"],
                                         hp: 80, maxhp: 100, status: "", moves: ["quickattack"], ability: "runaway")
        let slugs = OnlineBattleReplayVisibleNames.slugs(visible: visible, snapshot: snapshot)
        XCTAssertEqual(slugs.moves, ["quickattack": "quick-attack"])
        XCTAssertEqual(slugs.abilities, ["runaway": "run-away"])
        XCTAssertFalse(slugs.moves.values.contains("future-sight"))
        let hidden = BattleView.Pokemon(speciesNum: 25, species: "Pikachu", level: 50, types: ["Electric"],
                                        hp: 100, maxhp: 100, status: "", moves: [], ability: nil)
        let hiddenSlugs = OnlineBattleReplayVisibleNames.slugs(visible: hidden, snapshot: snapshot)
        XCTAssertTrue(hiddenSlugs.moves.isEmpty)
        XCTAssertTrue(hiddenSlugs.abilities.isEmpty)
    }
}
