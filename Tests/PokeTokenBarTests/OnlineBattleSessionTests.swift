import XCTest
import CryptoKit
@testable import PokeTokenBar

private actor SessionCredentials: OnlineBattleCredentialStoring {
    var key: String? = "test-key"
    var loads = 0, saves = 0
    var fails = false
    func setFailure(_ value: Bool) { fails = value }
    func setKey(_ value: String?) { key = value }
    func load(scope: OnlineBattleCredentialScope) -> String? { loads += 1; return key }
    func save(_ accessKey: String, scope: OnlineBattleCredentialScope) throws {
        saves += 1
        if fails { throw OnlineBattleFailure.credentialsUnavailable }
        key = accessKey
    }
    func remove(scope: OnlineBattleCredentialScope) { key = nil }
}
private actor SessionHTTP: OnlineBattleHTTPTransport {
    var requests: [URLRequest] = []
    var routes: [String: OnlineBattleHTTPResponse] = [:]
    var queues: [String: [OnlineBattleHTTPResponse]] = [:]
    var suspendPath: String?
    var suspended: CheckedContinuation<OnlineBattleHTTPResponse, Never>?
    var blockedWaiter: CheckedContinuation<Void, Never>?
    func suspendNext(_ path: String) { suspendPath = path }
    func waitUntilBlocked() async {
        if suspended != nil { return }
        await withCheckedContinuation { blockedWaiter = $0 }
    }
    func resume(_ response: OnlineBattleHTTPResponse) { suspended?.resume(returning: response); suspended = nil }
    func queue(_ path: String, _ values: [OnlineBattleHTTPResponse]) { queues[path] = values }
    func bodies(_ path: String) -> [Data] { requests.filter { $0.url?.path == path }.compactMap(\.httpBody) }
    func route(_ path: String, _ data: Data, status: Int = 200) { routes[path] = .init(status: status, body: data) }
    func send(_ request: URLRequest) async throws -> OnlineBattleHTTPResponse {
        requests.append(request)
        let path = request.url!.path
        if path == suspendPath {
            suspendPath = nil
            return await withCheckedContinuation { suspended = $0; blockedWaiter?.resume(); blockedWaiter = nil }
        }
        if var queue = queues[path], !queue.isEmpty {
            let value = queue.removeFirst(); queues[path] = queue; return value
        }
        guard let response = routes[request.url!.path] else { throw OnlineBattleFailure.transport }
        return response
    }
    func count(_ path: String) -> Int { requests.filter { $0.url?.path == path }.count }
}
private actor SessionConnection: OnlineBattleConnecting {
    var configurationCount = 0
    func configure(origin: OnlineBattleOrigin?, accessKey: String?) { configurationCount += 1 }
    func setPopoverOpen(_ open: Bool) {}
    func snapshot() -> OnlineBattleConnectionSnapshot { .init(state: .connected, generation: 1, connectionId: "connection", trainerId: "trainer-one", groupId: "group") }
    func authenticationFailed(generation: UInt64) {}
    func stop() {}
}
@MainActor
private final class SessionEffects: OnlineBattleEffects {
    var state = CompanionState()
    var applications = 0
    func healthShare(of instanceID: String) -> Double { state.battleHealth[instanceID] ?? 1 }
    func setHealthShare(_ share: Double, of instanceID: String) { state.battleHealth[instanceID] = share }
    func grantBattleXP(_ xp: Int) -> Bool { false }
    func setInBattle(_ instanceID: String?) {}
    func companionState() -> (state: CompanionState, activeName: String?)? { (state, nil) }
    func isHeldForBattle(instanceID: String) -> Bool { state.onlineBattleHolds.contains { $0.instanceID == instanceID } }
    func holdOnlineBattle(key: OnlineBattleReceiptKey, instanceID: String) throws {
        if !state.onlineBattleHolds.contains(where: { $0.key == key }) { state.onlineBattleHolds.append(.init(key: key, instanceID: instanceID)) }
    }
    func releaseOnlineBattle(key: OnlineBattleReceiptKey) { state.onlineBattleHolds.removeAll { $0.key == key } }
    func applyVerifiedOnlineBattleEffect(_ effect: VerifiedOnlineBattleEffect) throws -> OnlineBattleEffectReceipt {
        if let old = state.onlineBattleReceipts.first(where: { $0.key == effect.key }) { return old }
        applications += 1
        let result = OnlineBattleLedger.commit(effect, to: state, on: Date(timeIntervalSince1970: 0))
        state = result.state; return result.receipt
    }
}
@MainActor
final class OnlineBattleSessionTests: XCTestCase {
    private let account = OnlineBattleAccount(trainer: .init(trainerId: "trainer-one", displayEmail: "synthetic@example.invalid", role: .member, status: .active), group: .init(groupId: "group", name: "Test", hostTrainerId: "trainer-two"))
    private var engineURL: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("engine/dist/battle-engine.js") }
    private struct Fixture: Decodable { let battle: OnlineBattleView }
    private func battle(_ index: Int = 0) throws -> OnlineBattleView {
        let fixture = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "golden", withExtension: "json", subdirectory: "OnlineBattle"))))[index].battle
        // Resolver fixtures intentionally have arbitrary IDs; HTTP requires the server's bt_ namespace.
        let id = "bt_" + fixture.battleId.replacingOccurrences(of: "-", with: "_")
        let bytes = try OnlineBattleResolver.journalBytes(battleID: id, readyToken: fixture.config!.readyToken, journal: fixture.journal)
        let hash = SHA256.hash(data: Data(bytes.utf8)).map { String(format: "%02x", $0) }.joined()
        var result = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture.result)) as! [String: Any]
        result["journalHash"] = hash
        return try changed(fixture, ["battleId": id, "result": result])
    }
    private func roster(_ battle: OnlineBattleView) -> [PracticeCandidate] {
        [battle.p1.snapshot!, battle.p2.snapshot!].map { value in
            .init(id: value.instanceId, name: value.publicInfo.species, snapshot: .init(schemaVersion: 1, instanceID: value.instanceId, engineHash: BattleEngineManifest.sha256, rulesVersion: BattleSnapshot.rules, policyVersion: BattleSnapshot.policy, set: value.set, publicInfo: value.publicInfo), blockedReason: nil)
        }
    }
    private func setup(_ battles: [OnlineBattleView] = [], credential: SessionCredentials = .init(), effects: SessionEffects = .init(), trainer: String = "trainer-one", rosterOverride: [PracticeCandidate]? = nil, clock: OnlineBattleConnectionClock = .init()) async throws -> (OnlineBattleSession, SessionHTTP, SessionCredentials, SessionEffects) {
        let http = SessionHTTP(), connection = SessionConnection(), room = try battle()
        let localAccount = OnlineBattleAccount(trainer: .init(trainerId: trainer, displayEmail: account.trainer.displayEmail, role: .member, status: .active), group: account.group)
        await http.route("/v1/me", try JSONEncoder().encode(localAccount))
        await http.route("/v1/group", try JSONEncoder().encode(OnlineBattleGroupMembers(group: account.group, members: [])))
        await http.route("/v1/battles", try JSONEncoder().encode(OnlineBattlePage(battles: battles, before: nil)))
        let session = OnlineBattleSession(settings: .init(profileID: UUID().uuidString, serverURL: "https://battle.example.invalid"), credentials: credential, transport: http, effects: effects, engineFactory: { try BattleEngine(url: self.engineURL) }, connectionFactory: { _ in connection }, rosterProvider: { rosterOverride ?? self.roster(room) }, clock: clock, automaticTicks: false)
        return (session, http, credential, effects)
    }
    func testBootstrapLoadsCredentialsOnceAndRefreshesAccount() async throws {
        let (session, http, credentials, _) = try await setup()
        await session.bootstrap(); await session.bootstrap(); await session.refresh()
        XCTAssertEqual(session.presentation.account, account)
        let loads = await credentials.loads; XCTAssertEqual(loads, 1)
        let count = await http.count("/v1/me"); XCTAssertEqual(count, 2)
    }
    func testSaveFailureRetriesSameGrantWithoutIssuingAnotherJoin() async throws {
        let credentials = SessionCredentials(); await credentials.setKey(nil); await credentials.setFailure(true)
        let (session, http, _, _) = try await setup(credential: credentials)
        let body = try JSONSerialization.data(withJSONObject: ["trainer": JSONSerialization.jsonObject(with: JSONEncoder().encode(account.trainer)), "group": JSONSerialization.jsonObject(with: JSONEncoder().encode(account.group)), "accessKey": "issued-key", "recoveryCode": "one-time-code"])
        await http.route("/v1/join", body)
        await session.bootstrap(); await session.join(inviteCode: "invite", email: "synthetic@example.invalid")
        XCTAssertNil(session.presentation.account)
        XCTAssertNotNil(session.presentation.notice)
        await credentials.setFailure(false); await session.retryCredentialSave()
        XCTAssertEqual(session.presentation.account, account)
        XCTAssertEqual(session.presentation.recoveryCode, "one-time-code")
        let joins = await http.count("/v1/join"); XCTAssertEqual(joins, 1)
        let saves = await credentials.saves; XCTAssertEqual(saves, 2)
    }
    func testCompletedJournalIsVerifiedBeforeApplyingAndDuplicateRefreshDoesNotPayAgain() async throws {
        let room = try battle()
        let (session, _, _, effects) = try await setup([room])
        await session.bootstrap(); await session.refresh()
        XCTAssertEqual(effects.applications, 1)
        XCTAssertEqual(effects.state.onlineBattleReceipts.first?.localInstanceID, "instance-one")
        XCTAssertEqual(session.presentation.result?.xpAwarded, 0, "no current growth recipient")
    }
    func testUnverifiedCompletedNeverWritesEffects() async throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(battle())) as? [String: Any])
        var result = object["result"] as! [String: Any]; result["logHash"] = "tampered"; object["result"] = result
        let room = try JSONDecoder().decode(OnlineBattleView.self, from: JSONSerialization.data(withJSONObject: object))
        let (session, _, _, effects) = try await setup([room]); await session.bootstrap()
        XCTAssertEqual(effects.applications, 0)
        XCTAssertNotNil(session.presentation.notice)
    }
    private func changed(_ room: OnlineBattleView, _ updates: [String: Any]) throws -> OnlineBattleView {
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(room)) as? [String: Any])
        for (key, update) in updates { value[key] = update }
        return try JSONDecoder().decode(OnlineBattleView.self, from: JSONSerialization.data(withJSONObject: value))
    }
    private func response(_ room: OnlineBattleView) throws -> OnlineBattleHTTPResponse { .init(status: 200, body: try JSONEncoder().encode(room)) }
    func testOldUnauthorizedResponseCannotClearNewServerAccount() async throws {
        let (session, http, _, _) = try await setup()
        await http.suspendNext("/v1/me")
        let old = Task { await session.bootstrap() }
        await http.waitUntilBlocked()
        await session.configureServer("https://new.example.invalid")
        await http.resume(.init(status: 401, body: Data()))
        await old.value
        XCTAssertEqual(session.presentation.account, account)
        XCTAssertEqual(session.presentation.serverAddress, "https://new.example.invalid")
        XCTAssertNil(session.presentation.notice)
    }
    func testConcurrentRefreshSharesOneRead() async throws {
        let (session, http, _, _) = try await setup(); await session.bootstrap()
        await http.suspendNext("/v1/me")
        let first = Task { await session.refresh() }
        await http.waitUntilBlocked()
        let second = Task { await session.refresh() }
        await Task.yield()
        await http.resume(.init(status: 200, body: try JSONEncoder().encode(account)))
        await first.value; await second.value
        let reads = await http.count("/v1/me"); XCTAssertEqual(reads, 2)
    }
    func testAutomaticBattleAdvancesWhileHiddenReportsAndAppliesP2Result() async throws {
        let final = try battle(1)
        let first = try changed(final, ["state": "RUNNING", "result": NSNull(), "roundSeq": 1, "journal": JSONSerialization.jsonObject(with: JSONEncoder().encode(Array(final.journal.prefix(1))))])
        let (session, http, _, effects) = try await setup([first], trainer: "trainer-two", rosterOverride: roster(final))
        let steps = try (2...final.journal.count).map { count in try response(changed(final, ["state": "RUNNING", "result": NSNull(), "roundSeq": count, "journal": JSONSerialization.jsonObject(with: JSONEncoder().encode(Array(final.journal.prefix(count))))])) }
        await http.queue("/v1/battles/\(final.battleId)/advance", steps)
        await http.route("/v1/battles/\(final.battleId)/report", try JSONEncoder().encode(final))
        await session.perform(.setPopoverVisible(false)); await session.bootstrap()
        XCTAssertEqual(effects.applications, 1)
        XCTAssertEqual(effects.state.onlineBattleReceipts.first?.localInstanceID, "instance-two")
        let reports = await http.bodies("/v1/battles/\(final.battleId)/report")
        XCTAssertEqual(reports.count, 1)
        if let body = reports.first { XCTAssertEqual(try JSONDecoder().decode(OnlineBattleReport.self, from: body), final.result) }
    }
    func testManualChoiceUsesServerRoundAndTerminalReportRetriesIdentically() async throws {
        let final = try battle()
        let running = try changed(final, ["state": "RUNNING", "result": NSNull(), "roundSeq": 1, "deadline": 30000, "journal": []])
        let terminal = try changed(final, ["state": "RUNNING", "result": NSNull()])
        let (session, http, _, effects) = try await setup([running])
        await http.route("/v1/battles/\(final.battleId)/choices", try JSONEncoder().encode(terminal))
        await http.route("/v1/battles/\(final.battleId)/report", try JSONEncoder().encode(final))
        await http.queue("/v1/battles/\(final.battleId)/report", [.init(status: 503, body: Data())])
        await session.bootstrap(); await session.perform(.openBattle(final.battleId)); await session.perform(.chooseMove(1))
        XCTAssertEqual(effects.applications, 0)
        await http.route("/v1/battles", try JSONEncoder().encode(OnlineBattlePage(battles: [terminal], before: nil)))
        await session.refresh()
        let reports = await http.bodies("/v1/battles/\(final.battleId)/report")
        XCTAssertEqual(reports.count, 2)
        if reports.count == 2 { XCTAssertEqual(try JSONDecoder().decode(OnlineBattleReport.self, from: reports[0]), try JSONDecoder().decode(OnlineBattleReport.self, from: reports[1])) }
        XCTAssertEqual(effects.applications, 1)
        let choices = await http.bodies("/v1/battles/\(final.battleId)/choices")
        XCTAssertEqual(choices.count, 1)
        if let body = choices.first { let object = try JSONSerialization.jsonObject(with: body) as! [String: Any]; XCTAssertEqual(object["roundSeq"] as? Int, 1); XCTAssertEqual(object["choice"] as? String, "move 1") }
    }
    func testVoidReleasesPersistedHoldWithoutEffect() async throws {
        let final = try battle(), effects = SessionEffects()
        let scope = OnlineBattleScope(originHash: try OnlineBattleOrigin("https://battle.example.invalid").hash, groupID: "group", trainerID: "trainer-one")
        try effects.holdOnlineBattle(key: .init(scope: scope, battleID: final.battleId), instanceID: "instance-one")
        let room = try changed(final, ["state": "VOID", "result": NSNull()])
        let (session, _, _, _) = try await setup([room], effects: effects); await session.bootstrap()
        XCTAssertTrue(effects.state.onlineBattleHolds.isEmpty)
        XCTAssertEqual(effects.applications, 0)
        XCTAssertTrue(session.presentation.result?.isVoid == true)
    }
    func testCompletedCannotBeDowngradedByDelayedRunningView() async throws {
        let final = try battle(), running = try changed(battle(), ["state": "RUNNING", "result": NSNull(), "roundSeq": 1, "journal": []])
        let (session, http, _, effects) = try await setup([final]); await session.bootstrap()
        await http.route("/v1/battles", try JSONEncoder().encode(OnlineBattlePage(battles: [running], before: nil)))
        await session.refresh()
        XCTAssertEqual(session.presentation.battles.first?.state, .completed)
        XCTAssertEqual(effects.applications, 1)
        XCTAssertTrue(effects.state.onlineBattleHolds.isEmpty)
    }
    func testChallengeRetryRetainsRequestIDAndHoldsOriginalIndividual() async throws {
        let final = try battle(), pending = try changed(battle(), ["state": "PENDING", "config": NSNull(), "result": NSNull(), "roundSeq": 0, "journal": []])
        let (session, http, _, effects) = try await setup()
        await session.bootstrap()
        await http.queue("/v1/battles", [.init(status: 503, body: Data()), try response(pending)])
        session.presentation.selectedEntryID = final.p1.snapshot!.instanceId
        session.presentation.selectedOpponentID = "trainer-two"
        await session.perform(.challenge); await session.perform(.challenge)
        let bodies = await http.bodies("/v1/battles")
        XCTAssertEqual(bodies.count, 2)
        if bodies.count == 2 { XCTAssertEqual(try JSONSerialization.jsonObject(with: bodies[0]) as? NSDictionary, try JSONSerialization.jsonObject(with: bodies[1]) as? NSDictionary) }
        XCTAssertEqual(effects.state.onlineBattleHolds.first?.instanceID, "instance-one")
    }
    func testPrepareValidatesBothSetsAndUsesCurrentConnectionOnly() async throws {
        let final = try battle(), ready = try changed(battle(), ["state": "READY", "result": NSNull(), "roundSeq": 0, "journal": []])
        let running = try changed(final, ["state": "RUNNING", "result": NSNull(), "roundSeq": 1, "journal": []])
        let (session, http, _, _) = try await setup([ready])
        await http.route("/v1/battles/\(final.battleId)/start", try JSONEncoder().encode(running))
        await session.bootstrap(); await session.perform(.openBattle(final.battleId)); await session.perform(.prepareBattle)
        let starts = await http.bodies("/v1/battles/\(final.battleId)/start")
        XCTAssertEqual(starts.count, 1)
        if let body = starts.first { let data = try JSONSerialization.jsonObject(with: body) as! [String: Any]; XCTAssertEqual(data["connectionId"] as? String, "connection") }
    }
    func testUnknownLocalIndividualNeverCreatesHPEntry() async throws {
        let final = try battle()
        let (session, _, _, effects) = try await setup([final], rosterOverride: [])
        await session.bootstrap()
        XCTAssertEqual(effects.applications, 0); XCTAssertTrue(effects.state.battleHealth.isEmpty)
        XCTAssertNotNil(session.presentation.notice)
    }

    func testOnlineHoldPreventsPracticeEntryButReleaseAllowsIt() throws {
        let effects = SessionEffects()
        effects.state.dex = ["a", "b"].map { id in
            var profile = PokemonProfile.generate(seed: 42, instanceID: id)
            profile.level = 50; profile.gender = .male; profile.abilityName = "pressure"
            profile.moves = [.init(name: "tackle", learnedAtLevel: 1)]
            return DexEntry(baseID: 242, finalID: 242, chainOrder: [242], rarity: .common, caughtAt: nil, nature: .hardy, profile: profile)
        }
        let key = OnlineBattleReceiptKey(scope: .init(originHash: "origin", groupID: "group", trainerID: "trainer"), battleID: "bt_test")
        try effects.holdOnlineBattle(key: key, instanceID: "a")
        let practice = PracticeSession(engineURL: engineURL, drivesAutomatically: false, effects: effects)
        practice.prepare(state: effects.state, activeName: nil)
        XCTAssertNotNil(practice.startBlock)
        practice.start(); XCTAssertNil(practice.battle)
        effects.releaseOnlineBattle(key: key)
        XCTAssertNil(practice.startBlock)
        practice.start(); XCTAssertEqual(practice.battle?.phase, .running)
    }

    func testRecoveryAndReconnectUseExplicitGrantRequests() async throws {
        for action in [OnlineBattleUIAction.recover(code: "recovery"), .reconnect(code: "reconnect")] {
            let credentials = SessionCredentials(); await credentials.setKey(nil)
            let (session, http, _, _) = try await setup(credential: credentials)
            let body = try JSONSerialization.data(withJSONObject: ["trainer": JSONSerialization.jsonObject(with: JSONEncoder().encode(account.trainer)), "group": JSONSerialization.jsonObject(with: JSONEncoder().encode(account.group)), "accessKey": "rotated-key", "recoveryCode": "new-code"])
            await http.route("/v1/recover", body); await http.route("/v1/reconnect", body)
            await session.bootstrap(); await session.perform(action)
            XCTAssertEqual(session.presentation.account, account)
            XCTAssertEqual(session.presentation.recoveryCode, "new-code")
            await session.perform(.acknowledgeRecoveryCode); XCTAssertNil(session.presentation.recoveryCode)
        }
    }
    func testAcceptConfirmDeclineCancelSendExpectedRevision() async throws {
        let final = try battle()
        for (action, name, trainer, state) in [(OnlineBattleUIAction.accept, "accept", "trainer-two", "PENDING"), (.confirm, "confirm", "trainer-one", "ACCEPTED"), (.decline, "decline", "trainer-two", "PENDING"), (.cancel, "cancel", "trainer-one", "PENDING")] {
            let room = try changed(final, ["state": state, "config": NSNull(), "result": NSNull(), "confirmed": false, "roundSeq": 0, "journal": []])
            let (session, http, _, _) = try await setup([room], trainer: trainer)
            let updated = try changed(room, ["state": name == "decline" ? "DECLINED" : name == "cancel" ? "CANCELLED" : "ACCEPTED", "confirmed": name == "confirm"])
            await http.route("/v1/battles/\(room.battleId)/\(name)", try JSONEncoder().encode(updated))
            await session.bootstrap(); session.presentation.selectedEntryID = trainer == "trainer-two" ? "instance-two" : "instance-one"
            await session.perform(.openBattle(room.battleId)); await session.perform(action)
            let bodies = await http.bodies("/v1/battles/\(room.battleId)/\(name)")
            XCTAssertEqual(bodies.count, 1, name)
            if let body = bodies.first { let object = try JSONSerialization.jsonObject(with: body) as! [String: Any]; XCTAssertEqual(object["revision"] as? Int, room.revision) }
        }
    }
    func testDeadlineRefreshContinuesWithClosedPopover() async throws {
        let final = try battle(), running = try changed(battle(), ["state": "RUNNING", "result": NSNull(), "roundSeq": 1, "deadline": 30000, "journal": []])
        let (session, http, _, _) = try await setup([running], clock: .init(now: { 31 }, sleep: { _ in }))
        await session.bootstrap(); await session.perform(.setPopoverVisible(false)); await session.tick()
        let count = await http.count("/v1/me"); XCTAssertEqual(count, 2)
        XCTAssertEqual(session.presentation.room?.battleId, final.battleId)
        XCTAssertEqual(session.presentation.deadline, Date(timeIntervalSince1970: 30))
    }

}
