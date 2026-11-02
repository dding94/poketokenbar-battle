import XCTest
@testable import PokeTokenBar

final class OnlineBattleResolverTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private struct Fixture: Decodable {
        let name: String
        let battle: OnlineBattleView
        let journalBytes: String
        let inputLog: BattleInputLog
        let rejectionCount: Int
        let forcedCount: Int
    }
    private func fixtures() throws -> [Fixture] {
        try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "golden", withExtension: "json", subdirectory: "OnlineBattle"))))
    }
    @MainActor private func engine() throws -> BattleEngine {
        try BattleEngine(url: root.appendingPathComponent("engine/dist/battle-engine.js"))
    }
    @MainActor func testNodeCorpusProducesIdenticalTerminalReports() throws {
        for fixture in try fixtures() {
            let resolver = try OnlineBattleResolver(battle: fixture.battle, localTrainerID: "trainer-one", engine: engine())
            XCTAssertNoThrow(try resolver.consume(journal: fixture.battle.journal))
            XCTAssertEqual(try resolver.terminalReport(), fixture.battle.result, fixture.name)
        }
    }

    @MainActor func testBothViewpointsReplayTheNodeChoicesAndVerifyCompletion() throws {
        for fixture in try fixtures() {
            for trainer in ["trainer-one", "trainer-two"] {
                let engine = try engine()
                let resolver = try OnlineBattleResolver(battle: fixture.battle, localTrainerID: trainer, engine: engine)
                defer { resolver.close() }
                XCTAssertNoThrow(try resolver.consume(journal: fixture.battle.journal))
                XCTAssertEqual(try BattleJSON.encode(resolver.result?.inputLog), try BattleJSON.encode(Optional(fixture.inputLog)), fixture.name)
                let proof = try resolver.verifyCompleted(fixture.battle)
                XCTAssertEqual(proof.localSide, trainer == "trainer-one" ? .p1 : .p2)
                XCTAssertEqual(proof.localInstanceID, trainer == "trainer-one" ? "instance-one" : "instance-two")
                XCTAssertEqual(proof.battleID, fixture.battle.battleId)
                XCTAssertEqual(proof.resultHash.count, 64)
                let expectedHP = trainer == "trainer-one" ? fixture.battle.result!.finalHp.p1 : fixture.battle.result!.finalHp.p2
                let maxHP = trainer == "trainer-one" ? fixture.battle.p1.snapshot!.publicInfo.stats["hp"]! : fixture.battle.p2.snapshot!.publicInfo.stats["hp"]!
                XCTAssertEqual(proof.remainingHPShare, Double(expectedHP) / Double(maxHP))
                let ownView = try XCTUnwrap(resolver.view)
                XCTAssertEqual(trainer == "trainer-one" ? ownView.p1.hp : ownView.p2.hp, expectedHP)
                struct Replayed: Decodable { let logHash: String }
                let replayed: Replayed = try BattleJSON.decode(engine.call(.replay, arguments: [BattleJSON.encode(fixture.inputLog)]))
                XCTAssertEqual(replayed.logHash, fixture.battle.result!.logHash)
            }
        }
    }

    @MainActor func testCanonicalBytesUseActualServerHelperAndIgnoreReleaseTime() throws {
        for fixture in try fixtures() {
            let room = fixture.battle
            XCTAssertEqual(try OnlineBattleResolver.journalBytes(battleID: room.battleId, readyToken: room.config!.readyToken, journal: room.journal), fixture.journalBytes)
            let changed = room.journal.map { OnlineBattlePair(roundSeq: $0.roundSeq, p1: $0.p1, p2: $0.p2, releasedAt: $0.releasedAt + 1) }
            XCTAssertEqual(try OnlineBattleResolver.journalBytes(battleID: room.battleId, readyToken: room.config!.readyToken, journal: changed), fixture.journalBytes)
        }
    }

    @MainActor func testDuplicatePrefixDoesNotConsumeOrAdvanceAndOnlyTerminalProducesReport() throws {
        let room = try fixtures()[0].battle
        let resolver = try OnlineBattleResolver(battle: room, localTrainerID: "trainer-two", engine: engine())
        defer { resolver.close() }
        XCTAssertNil(try resolver.terminalReport())
        XCTAssertEqual(resolver.view?.p1.moves, [])
        XCTAssertNil(resolver.view?.p1.ability)
        XCTAssertEqual(resolver.view?.p2.moves, ["tackle", "splash"])
        try resolver.consume(journal: Array(room.journal.prefix(1)))
        XCTAssertEqual(resolver.view?.p1.moves, ["quickattack"])
        XCTAssertNil(try resolver.terminalReport())
        let logHash = resolver.result?.logHash, count = resolver.result?.inputLog.choices.count
        let logs = resolver.logs
        try resolver.consume(journal: Array(room.journal.prefix(1)))
        XCTAssertEqual(resolver.result?.logHash, logHash)
        XCTAssertEqual(resolver.result?.inputLog.choices.count, count)
        XCTAssertEqual(resolver.logs, logs)
        XCTAssertEqual(resolver.processedRoundSeq, 1)
        try resolver.consume(journal: room.journal)
        let report = try resolver.terminalReport()
        XCTAssertEqual(report, room.result)
        try resolver.consume(journal: room.journal)
        XCTAssertEqual(try resolver.terminalReport(), report)
    }

    @MainActor func testGapTruncationAndChangedPrefixRequireFreshReplay() throws {
        let room = try fixtures()[0].battle
        let first = room.journal[0]
        let badJournals = [Array(room.journal.dropFirst()), [],
                           [OnlineBattlePair(roundSeq: 1, p1: .timeout, p2: first.p2, releasedAt: first.releasedAt)],
                           [OnlineBattlePair(roundSeq: 1, p1: first.p1, p2: first.p2, releasedAt: first.releasedAt + 1)]]
        for bad in badJournals {
            let resolver = try OnlineBattleResolver(battle: room, localTrainerID: "trainer-one", engine: engine())
            try resolver.consume(journal: [first])
            XCTAssertThrowsError(try resolver.consume(journal: bad)) { XCTAssertEqual($0 as? OnlineBattleResolver.Failure, .needsRefetch) }
            XCTAssertThrowsError(try resolver.terminalReport())
            XCTAssertThrowsError(try resolver.consume(journal: room.journal))
        }
        let gap = try OnlineBattleResolver(battle: room, localTrainerID: "trainer-one", engine: engine())
        XCTAssertThrowsError(try gap.consume(journal: [room.journal[1]])) { XCTAssertEqual($0 as? OnlineBattleResolver.Failure, .needsRefetch) }
        let fresh = try OnlineBattleResolver(battle: room, localTrainerID: "trainer-one", engine: engine())
        defer { fresh.close() }
        try fresh.consume(journal: room.journal)
        XCTAssertEqual(try fresh.terminalReport(), room.result)
    }

    @MainActor func testClosedRelayTokensRejectInvalidSlotsModesAndPostTerminalRounds() throws {
        let room = try fixtures()[0].battle
        for pair in [OnlineBattlePair(roundSeq: 1, p1: .move(0), p2: .move(1), releasedAt: 0),
                     OnlineBattlePair(roundSeq: 1, p1: .move(5), p2: .move(1), releasedAt: 0),
                     OnlineBattlePair(roundSeq: 1, p1: .policy, p2: .move(1), releasedAt: 0)] {
            let resolver = try OnlineBattleResolver(battle: room, localTrainerID: "trainer-one", engine: engine())
            XCTAssertThrowsError(try resolver.consume(journal: [pair])) { XCTAssertEqual($0 as? OnlineBattleResolver.Failure, .invalidJournal) }
        }
        let auto = try XCTUnwrap(fixtures().first { $0.name == "auto" }).battle
        let resolver = try OnlineBattleResolver(battle: auto, localTrainerID: "trainer-one", engine: engine())
        XCTAssertThrowsError(try resolver.consume(journal: [.init(roundSeq: 1, p1: .timeout, p2: .policy, releasedAt: 0)]))
        let ended = try OnlineBattleResolver(battle: room, localTrainerID: "trainer-one", engine: engine())
        XCTAssertThrowsError(try ended.consume(journal: room.journal + [.init(roundSeq: room.journal.count + 1, p1: .timeout, p2: .timeout, releasedAt: 0)]))
        let oversized = try OnlineBattleResolver(battle: room, localTrainerID: "trainer-one", engine: engine())
        XCTAssertThrowsError(try oversized.consume(journal: (1...201).map { .init(roundSeq: $0, p1: .timeout, p2: .timeout, releasedAt: 0) }))
        for raw in [#"{"kind":"move","slot":5}"#, #"{"kind":">eval"}"#, #"{"kind":"move","slot":"1"}"#] {
            XCTAssertThrowsError(try BattleJSON.decode(raw) as OnlineBattleRelayToken)
        }
    }

    private func changed(_ room: OnlineBattleView, _ edit: (inout [String: Any]) -> Void) throws -> OnlineBattleView {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: BattleJSON.encoder().encode(room)) as? [String: Any])
        edit(&object)
        return try JSONDecoder().decode(OnlineBattleView.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @MainActor func testFrozenMetadataSnapshotsAndIdentityMustMatchTheEngine() throws {
        let room = try fixtures()[0].battle
        let mutations: [(String, (inout [String: Any]) -> Void)] = [
            ("engine hash", { $0["engineHash"] = String(repeating: "0", count: 64) }),
            ("rules", { $0["rulesVersion"] = "future" }), ("policy version", { $0["policyVersion"] = "auto-v1" }),
            ("relay", { $0["relayVersion"] = "future" }), ("seed count", { $0["seed"] = [1, 2, 3] }),
            ("seed bound", { $0["seed"] = [1, 2, 3, 65536] }), ("ready token", { $0["readyToken"] = "" }),
            ("HP", { var p = $0["p1"] as! [String: Any]; p["hp"] = 0; $0["p1"] = p }),
            ("name", { var p = $0["p1"] as! [String: Any]; p["name"] = "trainer"; $0["p1"] = p }),
            ("policy", { var p = $0["p2"] as! [String: Any]; p["policy"] = "tactical"; $0["p2"] = p })
        ]
        for (name, mutate) in mutations {
            let bad = try changed(room) { var config = $0["config"] as! [String: Any]; mutate(&config); $0["config"] = config }
            XCTAssertThrowsError(try OnlineBattleResolver(battle: bad, localTrainerID: "trainer-one", engine: engine()), name)
        }
        for property in ["species", "stats"] {
            let bad = try changed(room) {
                var p = $0["p2"] as! [String: Any], snapshot = p["snapshot"] as! [String: Any]
                var info = snapshot["public"] as! [String: Any]
                if property == "species" { info[property] = "Wrong" }
                else { var stats = info["stats"] as! [String: Any]; stats["hp"] = 999; info["stats"] = stats }
                snapshot["public"] = info; p["snapshot"] = snapshot; $0["p2"] = p
            }
            XCTAssertThrowsError(try OnlineBattleResolver(battle: bad, localTrainerID: "trainer-one", engine: engine()))
        }
        // HP agrees across snapshot/config but exceeds the real engine maximum.
        let tooHealthy = try changed(room) {
            var c = $0["config"] as! [String: Any], cp = c["p1"] as! [String: Any]
            var p = $0["p1"] as! [String: Any], s = p["snapshot"] as! [String: Any]
            cp["hp"] = 999; s["hp"] = 999; c["p1"] = cp; p["snapshot"] = s; $0["config"] = c; $0["p1"] = p
        }
        XCTAssertThrowsError(try OnlineBattleResolver(battle: tooHealthy, localTrainerID: "trainer-one", engine: engine()))
        XCTAssertThrowsError(try OnlineBattleResolver(battle: room, localTrainerID: "outsider", engine: engine()))
        let sameTrainer = try changed(room) { var p = $0["p2"] as! [String: Any]; p["trainerId"] = "trainer-one"; $0["p2"] = p }
        XCTAssertThrowsError(try OnlineBattleResolver(battle: sameTrainer, localTrainerID: "trainer-one", engine: engine()))
    }

    @MainActor func testCompletionRequiresEveryLocalReportFieldAndFrozenIdentity() throws {
        let room = try fixtures()[0].battle
        let resolver = try OnlineBattleResolver(battle: room, localTrainerID: "trainer-one", engine: engine())
        defer { resolver.close() }
        try resolver.consume(journal: room.journal)
        let wrongValues: [String: Any] = ["readyToken": "other", "engineHash": String(repeating: "a", count: 64), "terminalSeq": 1,
                                        "winner": "draw", "logHash": String(repeating: "b", count: 64),
                                        "journalHash": String(repeating: "c", count: 64), "finalHp": ["p1": 0, "p2": 1]]
        for (key, value) in wrongValues {
            let bad = try changed(room) { var r = $0["result"] as! [String: Any]; r[key] = value; $0["result"] = r }
            XCTAssertThrowsError(try resolver.verifyCompleted(bad), key) { XCTAssertEqual($0 as? OnlineBattleResolver.Failure, .resultMismatch) }
        }
        for (key, value) in ["state": "REPORTED", "battleId": "other"] {
            XCTAssertThrowsError(try resolver.verifyCompleted(changed(room) { $0[key] = value }))
        }
        XCTAssertThrowsError(try resolver.verifyCompleted(changed(room) { $0["roundSeq"] = 1 }))
        XCTAssertThrowsError(try resolver.verifyCompleted(changed(room) { $0["result"] = NSNull() }))
        let changedConfig = try changed(room) { var c = $0["config"] as! [String: Any]; c["policySeed"] = 43; $0["config"] = c }
        XCTAssertThrowsError(try resolver.verifyCompleted(changedConfig))
        XCTAssertNoThrow(try resolver.verifyCompleted(room))
        resolver.close()
        XCTAssertThrowsError(try resolver.terminalReport())
    }

    @MainActor func testForcedRechargePPHiddenImprisonAndExactTurnCapAreExercised() throws {
        let fixtures = try fixtures()
        for name in ["recharge", "pp"] {
            let fixture = try XCTUnwrap(fixtures.first { $0.name == name })
            XCTAssertGreaterThan(fixture.forcedCount, 0)
            let resolver = try OnlineBattleResolver(battle: fixture.battle, localTrainerID: "trainer-two", engine: engine())
            defer { resolver.close() }
            try resolver.consume(journal: Array(fixture.battle.journal.prefix(name == "recharge" ? 1 : 8)))
            XCTAssertEqual(resolver.request.kind, name == "recharge" ? "move" : "forced")
            XCTAssertNoThrow(try resolver.consume(journal: fixture.battle.journal))
            XCTAssertEqual(try resolver.terminalReport(), fixture.battle.result)
        }
        let imprisoned = try XCTUnwrap(fixtures.first { $0.name == "imprison" })
        XCTAssertGreaterThan(imprisoned.rejectionCount, 0)
        XCTAssertTrue(imprisoned.inputLog.choices.contains { $0.side == "p2" && $0.choice.slot == 2 })
        let draw = try XCTUnwrap(fixtures.first { $0.name == "draw" })
        XCTAssertEqual(draw.battle.journal.count, 200)
        XCTAssertEqual(draw.battle.result?.winner, .draw)
        let resolver = try OnlineBattleResolver(battle: draw.battle, localTrainerID: "trainer-two", engine: engine())
        defer { resolver.close() }
        try resolver.consume(journal: draw.battle.journal)
        XCTAssertEqual(resolver.result?.turns, 200)
        XCTAssertEqual(try resolver.terminalReport(), draw.battle.result)
    }
}
