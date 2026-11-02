import XCTest
import CryptoKit
import Observation
@testable import PokeTokenBar

private final class SessionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double = 31
    func now() -> Double { lock.withLock { value } }
    func advance(_ seconds: Double) { lock.withLock { value += seconds } }
}

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
        if path == suspendPath || (request.httpMethod ?? "GET") + " " + path == suspendPath {
            suspendPath = nil
            return await withCheckedContinuation { suspended = $0; blockedWaiter?.resume(); blockedWaiter = nil }
        }
        let queueKey = (request.httpMethod ?? "GET") + " " + path
        if var queue = queues[queueKey] ?? queues[path], !queue.isEmpty {
            let value = queue.removeFirst(); queues[queues[queueKey] == nil ? path : queueKey] = queue; return value
        }
        guard let response = routes[request.url!.path] else { throw OnlineBattleFailure.transport }
        return response
    }
    func count(_ path: String) -> Int { requests.filter { $0.url?.path == path }.count }
}
private actor SessionConnection: OnlineBattleConnecting {
    var configurationCount = 0
    var stops = 0
    var state: OnlineBattleConnectionState = .connected
    func setState(_ value: OnlineBattleConnectionState) { state = value }
    func configure(origin: OnlineBattleOrigin?, accessKey: String?) { configurationCount += 1 }
    func setPopoverOpen(_ open: Bool) {}
    func snapshot() -> OnlineBattleConnectionSnapshot { .init(state: state, generation: 1, connectionId: "connection", trainerId: "trainer-one", groupId: "group") }
    func authenticationFailed(generation: UInt64) {}
    private var pauseStop = false
    private var stoppedWaiter: CheckedContinuation<Void, Never>?
    private var stopWaiter: CheckedContinuation<Void, Never>?
    func suspendStop() { pauseStop = true }
    func waitUntilStopping() async {
        if stopWaiter != nil { return }
        await withCheckedContinuation { stoppedWaiter = $0 }
    }
    func resumeStop() { stopWaiter?.resume(); stopWaiter = nil }
    func stop() async {
        stops += 1
        if pauseStop {
            pauseStop = false
            await withCheckedContinuation { stopWaiter = $0; stoppedWaiter?.resume(); stoppedWaiter = nil }
        }
    }
}
@MainActor
@Observable
private final class SessionAccess { var allowed = true }

@MainActor
private final class SessionObserver { var callback: OnlineBattleConnection.Observer? }

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
    private func setup(_ battles: [OnlineBattleView] = [], credential: SessionCredentials = .init(), effects: SessionEffects = .init(), trainer: String = "trainer-one", rosterOverride: [PracticeCandidate]? = nil, connection: SessionConnection = .init(), observer: SessionObserver? = nil, access: SessionAccess? = nil, enabled: Bool = true, clock: OnlineBattleConnectionClock = .init()) async throws -> (OnlineBattleSession, SessionHTTP, SessionCredentials, SessionEffects) {
        let http = SessionHTTP(), room = try battle()
        let localAccount = OnlineBattleAccount(trainer: .init(trainerId: trainer, displayEmail: account.trainer.displayEmail, role: .member, status: .active), group: account.group)
        await http.route("/v1/me", try JSONEncoder().encode(localAccount))
        await http.route("/v1/group", try JSONEncoder().encode(OnlineBattleGroupMembers(group: account.group, members: [])))
        await http.route("/v1/battles", try JSONEncoder().encode(OnlineBattlePage(battles: battles, before: nil)))
        let session = OnlineBattleSession(settings: .init(profileID: UUID().uuidString, serverURL: "https://battle.example.invalid"), credentials: credential, transport: http, effects: effects, engineFactory: { try BattleEngine(url: self.engineURL) }, connectionFactory: { callback in observer?.callback = callback; return connection }, rosterProvider: { rosterOverride ?? self.roster(room) }, clock: clock, automaticTicks: false, enabled: enabled, accessAllowed: { access?.allowed ?? true })
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
        await http.queue("POST /v1/battles", [.init(status: 503, body: Data()), try response(pending)])
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

    func testOnePrepareGestureStartsAfterOtherPlayerBecomesReady() async throws {
        let final = try battle()
        let accepted = try changed(final, ["state": "ACCEPTED", "config": NSNull(), "result": NSNull(), "confirmed": true, "roundSeq": 0, "journal": []])
        let ready = try changed(final, ["state": "READY", "result": NSNull(), "roundSeq": 0, "journal": []])
        let running = try changed(final, ["state": "RUNNING", "result": NSNull(), "roundSeq": 1, "journal": []])
        let (session, http, _, _) = try await setup([accepted])
        await http.route("/v1/battles/\(final.battleId)/ready", try JSONEncoder().encode(accepted))
        await http.route("/v1/battles/\(final.battleId)/start", try JSONEncoder().encode(running))
        await session.bootstrap(); await session.perform(.prepareBattle)
        await http.route("/v1/battles", try JSONEncoder().encode(OnlineBattlePage(battles: [ready], before: nil)))
        await session.refresh()
        let starts = await http.count("/v1/battles/\(final.battleId)/start"); XCTAssertEqual(starts, 1)
        XCTAssertEqual(session.presentation.room?.state, .running)
    }
    func testOldFailureDoesNotDisableNewServerActions() async throws {
        let (session, http, _, _) = try await setup()
        await http.suspendNext("/v1/me")
        let old = Task { await session.bootstrap() }; await http.waitUntilBlocked()
        await session.configureServer("https://new.example.invalid")
        await http.resume(.init(status: 401, body: Data())); await old.value
        let pending = try changed(battle(), ["state": "PENDING", "config": NSNull(), "result": NSNull(), "roundSeq": 0, "journal": []])
        await http.queue("POST /v1/battles", [try response(pending)])
        session.presentation.selectedEntryID = "instance-one"; session.presentation.selectedOpponentID = "trainer-two"
        await session.perform(.challenge)
        let bodies = await http.bodies("/v1/battles"); XCTAssertEqual(bodies.count, 1)
    }
    func testPollingNeverAcknowledgesReadyOrStart() async throws {
        let final = try battle(), connection = SessionConnection(); await connection.setState(.polling)
        let ready = try changed(final, ["state": "READY", "result": NSNull(), "roundSeq": 0, "journal": []])
        let (session, http, _, _) = try await setup([ready], connection: connection)
        await session.bootstrap(); await session.perform(.prepareBattle)
        let starts = await http.count("/v1/battles/\(final.battleId)/start"); XCTAssertEqual(starts, 0)
        XCTAssertFalse(session.presentation.canStart)
    }
    func testPersistedHoldMissingFromListIsFetchedAndReleasedOnlyWithEvidence() async throws {
        let room = try changed(battle(), ["state": "EXPIRED", "result": NSNull()]), effects = SessionEffects()
        let key = OnlineBattleReceiptKey(scope: .init(originHash: try OnlineBattleOrigin("https://battle.example.invalid").hash, groupID: "group", trainerID: "trainer-one"), battleID: room.battleId)
        try effects.holdOnlineBattle(key: key, instanceID: "instance-one")
        let (session, http, _, _) = try await setup([], effects: effects)
        await http.route("/v1/battles/\(room.battleId)", try JSONEncoder().encode(room))
        await session.bootstrap()
        XCTAssertTrue(effects.state.onlineBattleHolds.isEmpty)
        let reads = await http.count("/v1/battles/\(room.battleId)"); XCTAssertEqual(reads, 1)
    }
    func testLocalHealthChangeDuringChallengeCancelsInsteadOfHoldingOldSnapshot() async throws {
        let pending = try changed(battle(), ["state": "PENDING", "config": NSNull(), "result": NSNull(), "roundSeq": 0, "journal": []])
        let cancelled = try changed(pending, ["state": "CANCELLED"])
        let (session, http, _, effects) = try await setup(); await session.bootstrap()
        session.presentation.selectedEntryID = "instance-one"; session.presentation.selectedOpponentID = "trainer-two"
        await http.route("/v1/battles/\(pending.battleId)/cancel", try JSONEncoder().encode(cancelled))
        await http.suspendNext("POST /v1/battles")
        let challenge = Task { await session.perform(.challenge) }; await http.waitUntilBlocked()
        effects.setHealthShare(0.5, of: "instance-one")
        await http.resume(try response(pending)); await challenge.value
        XCTAssertTrue(effects.state.onlineBattleHolds.isEmpty)
        let cancels = await http.count("/v1/battles/\(pending.battleId)/cancel"); XCTAssertEqual(cancels, 1)
        XCTAssertNotNil(session.presentation.notice)
    }

    func testReadyResumesFrozenBattleAfterLocalGrowthChangesInputs() async throws {
        let final = try battle()
        let ready = try changed(final, ["state": "READY", "result": NSNull(), "roundSeq": 0, "journal": []])
        let running = try changed(final, ["state": "RUNNING", "result": NSNull(), "roundSeq": 1, "journal": []])
        var entries = roster(final)
        let original = entries[0].snapshot!, value = original.set
        let grown = BattleSet(speciesNum: value.speciesNum, form: value.form, level: value.level + 1, gender: value.gender, nature: value.nature, ability: value.ability, moves: value.moves, ivs: value.ivs, shiny: value.shiny)
        let engine = try BattleEngine(url: engineURL)
        let info: BattlePublicInfo = try BattleJSON.decode(engine.call(.describeSet, arguments: [BattleJSON.encode(grown)]))
        entries[0] = .init(id: original.instanceID, name: info.species, snapshot: .init(schemaVersion: 1, instanceID: original.instanceID, engineHash: original.engineHash, rulesVersion: original.rulesVersion, policyVersion: original.policyVersion, set: grown, publicInfo: info), blockedReason: nil)
        let (session, http, _, _) = try await setup([ready], rosterOverride: entries)
        await http.route("/v1/battles/\(final.battleId)/start", try JSONEncoder().encode(running))
        await session.bootstrap(); await session.perform(.prepareBattle)
        let starts = await http.count("/v1/battles/\(final.battleId)/start"); XCTAssertEqual(starts, 1)
    }

    func testRevocationInvalidatesAlreadyRunningRefreshBeforeItCanSettle() async throws {
        let observer = SessionObserver(), connection = SessionConnection()
        let (session, http, _, effects) = try await setup(connection: connection, observer: observer)
        await session.bootstrap()
        await http.route("/v1/battles", try JSONEncoder().encode(OnlineBattlePage(battles: [battle()], before: nil)))
        await http.suspendNext("/v1/me")
        let pending = Task { await session.refresh() }; await http.waitUntilBlocked()
        await connection.setState(.revoked)
        await observer.callback?(.changed(await connection.snapshot()))
        await http.resume(.init(status: 200, body: try JSONEncoder().encode(account))); await pending.value
        XCTAssertEqual(effects.applications, 0)
        XCTAssertNil(session.presentation.account)
        let before = await http.count("/v1/me"); await session.refresh()
        let after = await http.count("/v1/me"); XCTAssertEqual(after, before)
    }
    func testOldConnectionEventCannotRevokeChangedServer() async throws {
        let observer = SessionObserver(), connection = SessionConnection()
        let (session, _, _, _) = try await setup(connection: connection, observer: observer)
        await session.bootstrap(); let old = observer.callback
        await session.configureServer("https://new.example.invalid")
        await connection.setState(.revoked)
        await old?(.changed(await connection.snapshot()))
        XCTAssertEqual(session.presentation.account, account)
    }

    func testDisabledStartupDoesNotReadCredentialsOrUseNetworkAndEnableResumes() async throws {
        let (session, http, credentials, _) = try await setup(enabled: false)
        await session.bootstrap()
        let loads = await credentials.loads, requests = await http.requests.count
        XCTAssertEqual(loads, 0); XCTAssertEqual(requests, 0)
        await session.setEnabled(true)
        XCTAssertEqual(session.presentation.account, account)
        let after = await credentials.loads; XCTAssertEqual(after, 1)
    }
    func testFreshAccessGateBlocksEffectsBeforeObservationCallbackAndStopsConnection() async throws {
        let access = SessionAccess(), connection = SessionConnection()
        let (session, http, credentials, effects) = try await setup(connection: connection, access: access)
        await session.bootstrap()
        await http.route("/v1/battles", try JSONEncoder().encode(OnlineBattlePage(battles: [battle()], before: nil)))
        await http.suspendNext("/v1/me")
        let pending = Task { await session.refresh() }; await http.waitUntilBlocked()
        access.allowed = false
        await http.resume(.init(status: 200, body: try JSONEncoder().encode(account))); await pending.value
        XCTAssertEqual(effects.applications, 0)
        await session.setEnabled(false)
        XCTAssertNil(session.presentation.account)
        let stops = await connection.stops; XCTAssertEqual(stops, 1)
        let key = await credentials.key; XCTAssertEqual(key, "test-key", "disabling never deletes saved access keys")
        let count = await http.requests.count; await session.refresh(); await session.perform(.join(inviteCode: "x", email: "x@example.invalid"))
        let after = await http.requests.count; XCTAssertEqual(after, count)
    }
    func testDisableWhileJoinResponseIsInFlightNeverSavesOrDisplaysGrant() async throws {
        let access = SessionAccess(), credentials = SessionCredentials(); await credentials.setKey(nil)
        let (session, http, _, _) = try await setup(credential: credentials, access: access)
        await session.bootstrap(); await http.suspendNext("/v1/join")
        let join = Task { await session.join(inviteCode: "invite", email: "synthetic@example.invalid") }; await http.waitUntilBlocked()
        access.allowed = false; await session.setEnabled(false)
        let body = try JSONSerialization.data(withJSONObject: ["trainer": JSONSerialization.jsonObject(with: JSONEncoder().encode(account.trainer)), "group": JSONSerialization.jsonObject(with: JSONEncoder().encode(account.group)), "accessKey": "discarded-key", "recoveryCode": "discarded-code"])
        await http.resume(.init(status: 200, body: body)); await join.value
        let saves = await credentials.saves; XCTAssertEqual(saves, 0)
        XCTAssertNil(session.presentation.recoveryCode); XCTAssertNil(session.presentation.account)
        XCTAssertFalse(session.presentation.canRetryCredentialSave)
    }

    func testChallengeRefreshesOldCompletionBeforeAdmittingAnotherBattle() async throws {
        let final = try battle(1)
        let (session, http, _, effects) = try await setup([], rosterOverride: roster(final)); await session.bootstrap()
        session.presentation.selectedEntryID = "instance-one"; session.presentation.selectedOpponentID = "trainer-two"
        await http.route("/v1/battles", try JSONEncoder().encode(OnlineBattlePage(battles: [final], before: nil)))
        await session.perform(.challenge)
        XCTAssertEqual(effects.applications, 1)
        XCTAssertEqual(effects.healthShare(of: "instance-one"), 0)
        let creates = await http.bodies("/v1/battles"); XCTAssertEqual(creates.count, 0)
    }

    func testNotificationHoldingCreatedBattleBeforePOSTResponseDoesNotCancelIt() async throws {
        let pending = try changed(battle(), ["state": "PENDING", "config": NSNull(), "result": NSNull(), "roundSeq": 0, "journal": []])
        let (session, http, _, effects) = try await setup(); await session.bootstrap()
        session.presentation.selectedEntryID = "instance-one"; session.presentation.selectedOpponentID = "trainer-two"
        await http.suspendNext("POST /v1/battles")
        let challenge = Task { await session.perform(.challenge) }; await http.waitUntilBlocked()
        await http.route("/v1/battles", try JSONEncoder().encode(OnlineBattlePage(battles: [pending], before: nil)))
        await session.refresh()
        XCTAssertEqual(effects.state.onlineBattleHolds.first?.key.battleID, pending.battleId)
        await http.route("/v1/battles/\(pending.battleId)/cancel", try JSONEncoder().encode(changed(pending, ["state": "CANCELLED"])))
        await http.resume(try response(pending)); await challenge.value
        let cancels = await http.count("/v1/battles/\(pending.battleId)/cancel"); XCTAssertEqual(cancels, 0)
        XCTAssertEqual(effects.state.onlineBattleHolds.count, 1)
        XCTAssertEqual(session.presentation.room?.state, .pending)
    }

    func testPaidCompletedHistoryDoesNotRequireReleasedEntrantOrBlockNewAdmission() async throws {
        let final = try battle(), effects = SessionEffects()
        let (first, _, _, _) = try await setup([final], effects: effects); await first.bootstrap()
        XCTAssertEqual(effects.applications, 1)
        let remainingRoster = Array(roster(final).dropFirst())
        let (session, http, _, _) = try await setup([final], effects: effects, rosterOverride: remainingRoster)
        await session.bootstrap()
        XCTAssertNil(session.presentation.notice)
        XCTAssertEqual(effects.applications, 1)
        session.presentation.selectedEntryID = "instance-two"; session.presentation.selectedOpponentID = "trainer-two"
        var p1 = try JSONSerialization.jsonObject(with: JSONEncoder().encode(final.p1)) as! [String: Any]
        p1["snapshot"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(final.p2.snapshot))
        let pending = try changed(final, ["battleId": "bt_new", "state": "PENDING", "p1": p1, "config": NSNull(), "result": NSNull(), "roundSeq": 0, "journal": []])
        await http.queue("POST /v1/battles", [try response(pending)])
        await session.perform(.challenge)
        let creates = await http.bodies("/v1/battles"); XCTAssertEqual(creates.count, 1)
    }
    func testNotificationDuringReportForcesOneFollowupReadToCompleted() async throws {
        let final = try battle(), terminal = try changed(battle(), ["state": "RUNNING", "result": NSNull()])
        let reported = try changed(final, ["state": "REPORTED", "result": NSNull()])
        let (session, http, _, effects) = try await setup([terminal])
        await http.suspendNext("/v1/battles/\(final.battleId)/report")
        let bootstrap = Task { await session.bootstrap() }; await http.waitUntilBlocked()
        await http.route("/v1/battles", try JSONEncoder().encode(OnlineBattlePage(battles: [final], before: nil)))
        session.requestRefresh(); session.requestRefresh()
        await http.resume(try response(reported)); await bootstrap.value
        XCTAssertEqual(effects.applications, 1)
        XCTAssertEqual(session.presentation.room?.state, .completed)
        let reads = await http.count("/v1/me"); XCTAssertEqual(reads, 2, "two notifications share one followup")
    }

    func testMissedDeadlineReadRetriesAfterTransientFailureWhileHidden() async throws {
        let clock = SessionClock()
        let running = try changed(battle(), ["state": "RUNNING", "result": NSNull(), "roundSeq": 1, "deadline": 30000, "journal": []])
        let (session, http, _, _) = try await setup([running], clock: .init(now: { clock.now() }, sleep: { _ in }))
        await session.bootstrap(); await session.perform(.setPopoverVisible(false))
        await http.queue("/v1/me", [.init(status: 503, body: Data())])
        await session.tick(); clock.advance(5); await session.tick()
        let reads = await http.count("/v1/me"); XCTAssertEqual(reads, 3)
    }

    func testSelectingCompletedRoomsShowsEachRoomsOwnResult() async throws {
        let win = try battle(), loss = try battle(1)
        let (session, _, _, _) = try await setup([win, loss]); await session.bootstrap()
        await session.perform(.openBattle(win.battleId)); XCTAssertEqual(session.presentation.result?.title, "승리")
        await session.perform(.openBattle(loss.battleId)); XCTAssertEqual(session.presentation.result?.title, "패배")
    }
    func testDismissedResultStaysInLobbyAfterRefresh() async throws {
        let (session, _, _, _) = try await setup([battle()]); await session.bootstrap()
        await session.perform(.dismissResult); await session.refresh()
        XCTAssertEqual(session.presentation.phase, .lobby)
        XCTAssertNil(session.presentation.room)
        XCTAssertNil(session.presentation.result)
    }

    func testSameOriginGrantSeparatesPendingRefreshAndStopsPreviousConnection() async throws {
        for (action, path, status) in [(OnlineBattleUIAction.recover(code: "recovery"), "/v1/recover", 503), (.reconnect(code: "reconnect"), "/v1/reconnect", 401)] {
            let connection = SessionConnection(), observer = SessionObserver()
            let (session, http, credentials, _) = try await setup(connection: connection, observer: observer)
            await session.bootstrap()
            let oldObserver = try XCTUnwrap(observer.callback)
            await http.suspendNext("/v1/me")
            let oldRead = Task { await session.refresh() }; await http.waitUntilBlocked()
            let grant = try JSONSerialization.data(withJSONObject: ["trainer": JSONSerialization.jsonObject(with: JSONEncoder().encode(account.trainer)), "group": JSONSerialization.jsonObject(with: JSONEncoder().encode(account.group)), "accessKey": "new-key", "recoveryCode": "new-code"])
            await http.route(path, grant)
            await credentials.setFailure(true)
            await session.perform(action)
            let stops = await connection.stops; XCTAssertEqual(stops, 1, "accepting a same-origin grant must retire the previous connection even if saving fails")
            XCTAssertTrue(session.presentation.canRetryCredentialSave)
            await credentials.setFailure(false)
            let retry = Task { await session.perform(.retryCredentialSave) }
            for _ in 0..<300 { if await http.count("/v1/me") == 3 { break }; await Task.yield() }
            let freshReads = await http.count("/v1/me"); XCTAssertEqual(freshReads, 3, "new credentials must not join the suspended old refresh")
            await http.resume(.init(status: status, body: Data()))
            await oldRead.value; await retry.value
            await connection.setState(.revoked)
            await oldObserver(.changed(await connection.snapshot()))
            XCTAssertEqual(session.presentation.account, account, "old HTTP failures and connection events must not revoke new credentials")
            XCTAssertNil(session.presentation.notice)
            XCTAssertFalse(session.presentation.isBusy)
            await session.perform(.selectOpponent("trainer-two"))
            await session.perform(.challenge)
            let attempts = await http.bodies("/v1/battles")
            XCTAssertEqual(attempts.count, 1, "stale catch must not clear new reconciliation")
            let grants = await http.count(path); XCTAssertEqual(grants, 1)
        }
    }

    func testBackToLobbyWhileBusyKeepsSettlementRunningAndAllowsSelectingAnotherRoom() async throws {
        let final = try battle()
        let running = try changed(final, ["state": "RUNNING", "result": NSNull(), "roundSeq": 1, "journal": []])
        let terminal = try changed(final, ["state": "RUNNING", "result": NSNull()])
        let (session, http, _, effects) = try await setup([running])
        await http.route("/v1/battles/\(final.battleId)/choices", try JSONEncoder().encode(terminal))
        await http.suspendNext("/v1/battles/\(final.battleId)/report")
        await session.bootstrap()
        let choice = Task { await session.perform(.chooseMove(1)) }; await http.waitUntilBlocked()
        XCTAssertTrue(session.presentation.isBusy)
        await session.perform(.backToLobby)
        XCTAssertEqual(session.presentation.phase, .lobby)
        XCTAssertNil(session.presentation.room)
        XCTAssertNil(session.presentation.arena)
        XCTAssertNil(session.presentation.deadline)
        await http.resume(try response(final)); await choice.value
        XCTAssertEqual(effects.applications, 1, "navigation must not pause replay/report/settlement")
        XCTAssertTrue(effects.state.onlineBattleHolds.isEmpty)
        XCTAssertEqual(session.presentation.phase, .lobby, "in-flight action cannot undo explicit navigation")
        let incoming = try changed(battle(1), ["state": "PENDING", "config": NSNull(), "result": NSNull(), "roundSeq": 0, "journal": []])
        await http.route("/v1/battles", try JSONEncoder().encode(OnlineBattlePage(battles: [final, incoming], before: nil)))
        await session.refresh()
        XCTAssertEqual(session.presentation.phase, .lobby)
        await session.perform(.openBattle(incoming.battleId))
        XCTAssertEqual(session.presentation.room?.battleId, incoming.battleId)
        XCTAssertEqual(session.presentation.phase, .room)
        XCTAssertNil(session.presentation.result)
    }
    func testLateReportedHTTPResponseCannotDowngradeCompletedOrReacquireHold() async throws {
        let final = try battle()
        let running = try changed(final, ["state": "RUNNING", "result": NSNull(), "roundSeq": 1, "journal": []])
        let terminal = try changed(final, ["state": "RUNNING", "result": NSNull()])
        let reported = try changed(final, ["state": "REPORTED", "result": NSNull()])
        let (session, http, _, effects) = try await setup([running])
        await http.route("/v1/battles/\(final.battleId)/choices", try JSONEncoder().encode(terminal))
        await http.suspendNext("/v1/battles/\(final.battleId)/report")
        await session.bootstrap()
        let choice = Task { await session.perform(.chooseMove(1)) }; await http.waitUntilBlocked()
        await http.route("/v1/battles", try JSONEncoder().encode(OnlineBattlePage(battles: [final], before: nil)))
        await session.refresh()
        XCTAssertEqual(effects.applications, 1)
        await http.resume(try response(reported)); await choice.value
        XCTAssertEqual(session.presentation.room?.state, .completed)
        XCTAssertEqual(session.presentation.result?.title, "승리")
        XCTAssertEqual(effects.applications, 1)
        XCTAssertTrue(effects.state.onlineBattleHolds.isEmpty)
    }
    func testChangedJournalRefetchesOnceWithFreshResolverAndSettlesVerifiedResult() async throws {
        let final = try battle()
        let initial = try changed(final, ["state": "RUNNING", "result": NSNull(), "roundSeq": 2, "journal": JSONSerialization.jsonObject(with: JSONEncoder().encode(Array(final.journal.prefix(1))))])
        let (session, http, _, effects) = try await setup([initial]); await session.bootstrap()
        var altered = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Array(final.journal.prefix(1)))) as! [[String: Any]]
        altered[0]["p1"] = ["kind": "move", "slot": 1]
        let mismatch = try changed(initial, ["journal": altered])
        let terminal = try changed(final, ["state": "RUNNING", "result": NSNull()])
        await http.route("/v1/battles", try JSONEncoder().encode(OnlineBattlePage(battles: [mismatch], before: nil)))
        await http.route("/v1/battles/\(final.battleId)", try JSONEncoder().encode(terminal))
        await http.route("/v1/battles/\(final.battleId)/report", try JSONEncoder().encode(final))
        await session.refresh()
        let reads = await http.count("/v1/battles/\(final.battleId)"); XCTAssertEqual(reads, 1)
        XCTAssertEqual(effects.applications, 1)
        XCTAssertEqual(session.presentation.room?.state, .completed)
        XCTAssertNil(session.presentation.notice)
    }
    func testJournalGapStillInvalidAfterOneRefetchFailsClosedWithoutLoopOrEffects() async throws {
        let final = try battle()
        let gap = try changed(final, ["state": "RUNNING", "result": NSNull(), "journal": JSONSerialization.jsonObject(with: JSONEncoder().encode(Array(final.journal.dropFirst())))])
        let (session, http, _, effects) = try await setup([gap])
        await http.route("/v1/battles/\(final.battleId)", try JSONEncoder().encode(gap))
        await session.bootstrap()
        let reads = await http.count("/v1/battles/\(final.battleId)"); XCTAssertEqual(reads, 1)
        let reports = await http.count("/v1/battles/\(final.battleId)/report"); XCTAssertEqual(reports, 0)
        XCTAssertEqual(effects.applications, 0)
        XCTAssertNil(session.presentation.result)
        XCTAssertNotNil(session.presentation.notice)
    }

    func testAccessObservationReceivesDisableWhileEnableIsWaitingForHTTP() async throws {
        let access = SessionAccess(); access.allowed = false
        let connection = SessionConnection()
        let (session, http, _, _) = try await setup(connection: connection, access: access, enabled: false)
        let observation = OnlineBattleAccessObservation(read: { access.allowed }, changed: { await session.setEnabled($0) })
        observation.start()
        await http.suspendNext("/v1/me")
        access.allowed = true
        await http.waitUntilBlocked()
        access.allowed = false
        for _ in 0..<300 { if await connection.stops == 1 { break }; await Task.yield() }
        let stops = await connection.stops; XCTAssertEqual(stops, 1, "OFF must be observed while ON bootstrap awaits a response")
        await http.resume(.init(status: 200, body: try JSONEncoder().encode(account)))
        for _ in 0..<100 { await Task.yield() }
        XCTAssertNil(session.presentation.account)
        access.allowed = true
        for _ in 0..<300 { if session.presentation.account != nil { break }; await Task.yield() }
        XCTAssertEqual(session.presentation.account, account, "later ON must bootstrap after the interrupted enable")
    }
    func testDelayedDisableStopCannotClearNewlyEnabledAPIKey() async throws {
        let connection = SessionConnection()
        let (session, http, _, _) = try await setup(connection: connection)
        await session.bootstrap(); await connection.suspendStop()
        let disable = Task { await session.setEnabled(false) }
        await connection.waitUntilStopping()
        await session.setEnabled(true)
        XCTAssertEqual(session.presentation.account, account)
        await connection.resumeStop(); await disable.value
        await session.refresh()
        XCTAssertEqual(session.presentation.account, account)
        let reads = await http.count("/v1/me"); XCTAssertEqual(reads, 3, "late disable cleanup must not remove the new API credential")
    }

}
