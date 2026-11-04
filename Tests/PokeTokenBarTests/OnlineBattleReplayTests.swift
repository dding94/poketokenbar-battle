import CryptoKit
import XCTest
@testable import PokeTokenBar

final class OnlineBattleReplayTests: XCTestCase {
    private struct Fixture: Decodable { let name: String; let battle: OnlineBattleView }
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private func fixtures() throws -> [Fixture] {
        try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "golden", withExtension: "json", subdirectory: "OnlineBattle"))))
    }
    @MainActor private func engine(_ hash: String) throws -> BattleEngine {
        try BattleEngine(url: root.appendingPathComponent("engine/dist/battle-engine.js"))
    }
    private func changed(_ battle: OnlineBattleView, _ edit: (inout [String: Any]) -> Void) throws -> OnlineBattleView {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: BattleJSON.encoder().encode(battle)) as? [String: Any])
        edit(&object)
        return try JSONDecoder().decode(OnlineBattleView.self, from: JSONSerialization.data(withJSONObject: object))
    }
    @MainActor func testGoldenCompletedMatchesVerifyWithInitialAndEveryRoundFrameForBothSides() throws {
        for fixture in try fixtures() {
            for (trainer, side) in [("trainer-one", OnlineBattleSide.p1), ("trainer-two", .p2)] {
                do {
                    let replay = try OnlineBattleReplay(battle: fixture.battle, localTrainerID: trainer, engineFactory: engine)
                    XCTAssertTrue(replay.verified)
                    XCTAssertEqual(replay.battleID, fixture.battle.battleId)
                    XCTAssertEqual(replay.localSide, side)
                    XCTAssertEqual(replay.frames.map(\.roundSeq), Array(0...fixture.battle.journal.count))
                    let first = try XCTUnwrap(replay.frames.first), final = try XCTUnwrap(replay.frames.last)
                    XCTAssertFalse(first.view.ended)
                    XCTAssertTrue(final.view.ended)
                    let own = side == .p1 ? final.view.p1 : final.view.p2
                    XCTAssertEqual(own.hp, side == .p1 ? fixture.battle.result!.finalHp.p1 : fixture.battle.result!.finalHp.p2)
                    XCTAssertFalse(final.logs.isEmpty)
                    for index in 1..<replay.frames.count {
                        XCTAssertTrue(replay.frames[index].logs.starts(with: replay.frames[index - 1].logs))
                    }
                } catch { XCTFail("\(fixture.name) / \(side): \(error)") }
            }
        }
    }
    @MainActor func testFramesRevealOnlyTheInformationVisibleAtThatTimeFromP2() throws {
        let battle = try fixtures()[0].battle
        do {
            let replay = try OnlineBattleReplay(battle: battle, localTrainerID: "trainer-two", engineFactory: engine)
            let first = replay.frames[0], next = replay.frames[1]
            XCTAssertEqual(first.view.p1.moves, [])
            XCTAssertNil(first.view.p1.ability)
            XCTAssertEqual(first.view.p2.moves, ["tackle", "splash"])
            XCTAssertEqual(first.view.p1.maxhp, 100)
            XCTAssertEqual(first.view.p2.maxhp, battle.p2.snapshot!.publicInfo.stats["hp"])
            XCTAssertEqual(next.view.p1.moves, ["quickattack"])
            XCTAssertFalse(first.logs.joined().contains("전광석화"))
            XCTAssertTrue(next.logs.joined().contains("전광석화"))
            XCTAssertTrue(next.logs.joined().contains("상대 포켓몬"))
        } catch { XCTFail("Expected valid immutable frames: \(error)") }
    }
    @MainActor func testOldMatchAndExpiredInvitationStillReplayWithoutAnyTimeGate() throws {
        let battle = try changed(fixtures()[0].battle) {
            $0["createdAt"] = 1; $0["startedAt"] = 2; $0["expiresAt"] = 3; $0["reportedAt"] = 4
        }
        XCTAssertNoThrow(try OnlineBattleReplay(battle: battle, localTrainerID: "trainer-one", engineFactory: engine))
    }
    @MainActor func testVoidStartlessMissingAndForgedResultsNeverProduceReplay() throws {
        let battle = try fixtures()[0].battle
        for state in ["VOID", "CANCELLED", "DECLINED", "EXPIRED", "RUNNING"] {
            XCTAssertThrowsError(try OnlineBattleReplay(battle: changed(battle) { $0["state"] = state }, localTrainerID: "trainer-one", engineFactory: engine))
        }
        for key in ["config", "result"] {
            XCTAssertThrowsError(try OnlineBattleReplay(battle: changed(battle) { $0[key] = NSNull() }, localTrainerID: "trainer-one", engineFactory: engine))
        }
        for key in ["logHash", "journalHash", "engineHash"] {
            let bad = try changed(battle) { var report = $0["result"] as! [String: Any]; report[key] = String(repeating: "a", count: 64); $0["result"] = report }
            XCTAssertThrowsError(try OnlineBattleReplay(battle: bad, localTrainerID: "trainer-one", engineFactory: engine))
        }
        XCTAssertThrowsError(try OnlineBattleReplay(battle: changed(battle) { $0["journal"] = [] }, localTrainerID: "trainer-one", engineFactory: engine))
        XCTAssertThrowsError(try OnlineBattleReplay(battle: battle, localTrainerID: "outsider", engineFactory: engine))
    }
    @MainActor func testUnknownEngineAndUnsupportedVersionRefuseCurrentEngineFallback() throws {
        let battle = try fixtures()[0].battle
        var factoryCalls = 0
        for (key, value) in [("engineHash", String(repeating: "0", count: 64)), ("rulesVersion", "future"), ("policyVersion", "future"), ("relayVersion", "future")] {
            let bad = try changed(battle) { var config = $0["config"] as! [String: Any]; config[key] = value; $0["config"] = config }
            XCTAssertThrowsError(try OnlineBattleReplay(battle: bad, localTrainerID: "trainer-one", engineFactory: { hash in factoryCalls += 1; return try self.engine(hash) }))
        }
        XCTAssertEqual(factoryCalls, 0)
    }
    @MainActor func testInjectedEngineMustHaveTheVerifiedPinnedBytesInReplayAndLive() throws {
        let battle = try fixtures()[0].battle
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".js")
        defer { try? FileManager.default.removeItem(at: url) }
        var data = try Data(contentsOf: root.appendingPathComponent("engine/dist/battle-engine.js"))
        data.append(Data("\n// Different untrusted bytes\n".utf8))
        try data.write(to: url)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let untrusted = try BattleEngine(url: url, expectedHash: hash)
        XCTAssertThrowsError(try OnlineBattleReplay(battle: battle, localTrainerID: "trainer-one", engineFactory: { _ in untrusted }))
        XCTAssertThrowsError(try OnlineBattleResolver(battle: battle, localTrainerID: "trainer-one", engine: untrusted))
    }

}
