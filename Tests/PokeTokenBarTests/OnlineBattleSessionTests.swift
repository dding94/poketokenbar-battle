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
    var trainer = "trainer-one"
    var connectionID: String? = "connection"
    func setTrainer(_ value: String) { trainer = value }
    func setState(_ value: OnlineBattleConnectionState) { state = value }
    /// What a real reconnect does: the old id disappears with the socket, hello brings a new one.
    func setConnection(_ value: OnlineBattleConnectionState, id: String?) { state = value; connectionID = id }
    func configure(origin: OnlineBattleOrigin?, accessKey: String?) { configurationCount += 1 }
    func setPopoverOpen(_ open: Bool) {}
    func snapshot() -> OnlineBattleConnectionSnapshot { .init(state: state, generation: 1, connectionId: connectionID, trainerId: trainer, groupId: "group") }
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
    var effectCalls = 0
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
        effectCalls += 1
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
    private func battle(_ index: Int = 0, idOverride: String? = nil) throws -> OnlineBattleView {
        let fixture = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "golden", withExtension: "json", subdirectory: "OnlineBattle"))))[index].battle
        // Resolver fixtures intentionally have arbitrary IDs; HTTP requires the server's bt_ namespace.
        let id = idOverride ?? "bt_" + fixture.battleId.replacingOccurrences(of: "-", with: "_")
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
    private func setup(_ battles: [OnlineBattleView] = [], credential: SessionCredentials = .init(), effects: SessionEffects = .init(), trainer: String = "trainer-one", rosterOverride: [PracticeCandidate]? = nil, connection: SessionConnection = .init(), observer: SessionObserver? = nil, access: SessionAccess? = nil, enabled: Bool = true, clock: OnlineBattleConnectionClock = .init(), automaticTicks: Bool = false, embeddedServer: String? = nil) async throws -> (OnlineBattleSession, SessionHTTP, SessionCredentials, SessionEffects) {
        let http = SessionHTTP(), room = try battle()
        await connection.setTrainer(trainer)
        let localAccount = OnlineBattleAccount(trainer: .init(trainerId: trainer, displayEmail: account.trainer.displayEmail, role: .member, status: .active), group: account.group)
        await http.route("/v1/me", try JSONEncoder().encode(localAccount))
        await http.route("/v1/group", try JSONEncoder().encode(OnlineBattleGroupMembers(group: account.group, members: [])))
        await http.route("/v1/battles", try JSONEncoder().encode(OnlineBattlePage(battles: battles, before: nil)))
        let session = OnlineBattleSession(settings: .init(profileID: UUID().uuidString, serverURL: "https://battle.example.invalid", embeddedServerURL: embeddedServer), credentials: credential, transport: http, effects: effects, engineFactory: { try BattleEngine(url: self.engineURL) }, connectionFactory: { callback in observer?.callback = callback; return connection }, rosterProvider: { rosterOverride ?? self.roster(room) }, clock: clock, automaticTicks: automaticTicks, enabled: enabled, accessAllowed: { access?.allowed ?? true })
        return (session, http, credential, effects)
    }
    func testStandingsOpenIsReadOnlyAndFailureStaysInsideOverlay() async throws {
        let (session, http, _, effects) = try await setup()
        await session.bootstrap()
        await session.perform(.setPopoverVisible(true))
        await http.route("/v1/standings", Data(#"{"groupId":"group","championTrainerId":null,"rows":[]}"#.utf8))
        let reads = await http.count("/v1/battles")
        await session.perform(.showStandings)
        XCTAssertTrue(session.presentation.showsStandings)
        XCTAssertEqual(session.presentation.standings?.groupId, "group")
        XCTAssertEqual(effects.effectCalls, 0)
        let after = await http.count("/v1/battles"); XCTAssertEqual(after, reads)
        await http.route("/v1/standings", Data(#"{"error":{"code":"not_found"}}"#.utf8), status: 404)
        await session.perform(.refreshStandings)
        XCTAssertNotNil(session.presentation.standingsError)
        XCTAssertNil(session.presentation.notice)
        XCTAssertNotNil(session.presentation.account)
        await session.perform(.backToLobby)
        XCTAssertFalse(session.presentation.showsStandings)
    }

    func testRematchPreparationLocksOpponentAndModeWithoutSubmitting() async throws {
        let room = try battle()
        let (session, http, _, effects) = try await setup([room])
        try await activeOpponent(http)
        await session.bootstrap()
        await session.perform(.openReplay(room.battleId))
        let calls = effects.effectCalls
        await session.perform(.prepareRematch(room.battleId))
        XCTAssertEqual(session.presentation.rematchSourceID, room.battleId)
        XCTAssertEqual(session.presentation.rematchOpponent?.trainerId, "trainer-two")
        XCTAssertEqual(session.presentation.rematchMode, room.mode)
        XCTAssertFalse(session.presentation.showsHistory)
        await session.perform(.selectOpponent("someone-else"))
        await session.perform(.setMode(room.mode == .manual ? .auto : .manual))
        XCTAssertEqual(session.presentation.selectedOpponentID, "trainer-two")
        XCTAssertEqual(session.presentation.mode, room.mode)
        let posts = await http.count("/v1/battles/\(room.battleId)/rematch")
        XCTAssertEqual(posts, 0); XCTAssertEqual(effects.effectCalls, calls)
        await session.perform(.cancelRematch)
        XCTAssertNil(session.presentation.rematchSourceID)
        XCTAssertTrue(session.presentation.showsHistory)
        XCTAssertEqual(session.presentation.selectedHistoryBattle?.battleId, room.battleId)
    }

    private func rematchPending(_ source: OnlineBattleView) throws -> OnlineBattleView {
        var player = try JSONSerialization.jsonObject(with: JSONEncoder().encode(source.p1)) as! [String: Any]
        var snapshot = player["snapshot"] as! [String: Any]
        let maxHP = source.p1.snapshot!.publicInfo.stats["hp"]!
        snapshot["hp"] = max(1, Int((Double(source.result!.finalHp.p1) / Double(maxHP) * Double(maxHP)).rounded(.down)))
        player["snapshot"] = snapshot
        return try changed(source, ["battleId": "bt_rematch", "state": "PENDING", "rematchOf": source.battleId,
                                    "p1": player, "confirmed": false, "config": NSNull(), "result": NSNull(), "roundSeq": 0, "journal": []])
    }

    private func activeOpponent(_ http: SessionHTTP, status: OnlineBattleTrainer.Status = .active) async throws {
        let member = OnlineBattleMember(trainerId: "trainer-two", displayEmail: "opponent@example.invalid", role: .member, status: status, joinedAt: 0, online: false)
        await http.route("/v1/group", try JSONEncoder().encode(OnlineBattleGroupMembers(group: account.group, members: [member])))
    }

    func testStandingsNotificationsCoalesceAndNeverReadWhileClosed() async throws {
        let observer = SessionObserver()
        let (session, http, _, _) = try await setup(observer: observer)
        await session.bootstrap()
        let payload = Data(#"{"groupId":"group","championTrainerId":null,"rows":[]}"#.utf8)
        await http.route("/v1/standings", payload)
        await observer.callback?(.standingsRefreshRequested)
        var count = await http.count("/v1/standings"); XCTAssertEqual(count, 0)
        await session.perform(.setPopoverVisible(true))
        await http.suspendNext("/v1/standings")
        let opening = Task { await session.perform(.showStandings) }
        await http.waitUntilBlocked()
        let battleReads = await http.count("/v1/battles")
        for _ in 0..<20 { await observer.callback?(.standingsRefreshRequested) }
        await http.resume(.init(status: 200, body: payload)); await opening.value
        count = await http.count("/v1/standings"); XCTAssertEqual(count, 2)
        let after = await http.count("/v1/battles"); XCTAssertEqual(after, battleReads)
        await session.perform(.setPopoverVisible(false))
        await observer.callback?(.standingsRefreshRequested)
        await session.perform(.refreshStandings)
        await session.refresh()
        count = await http.count("/v1/standings"); XCTAssertEqual(count, 2)
        await session.perform(.setPopoverVisible(true))
        await session.perform(.refreshStandings)
        count = await http.count("/v1/standings"); XCTAssertGreaterThanOrEqual(count, 3)
        await session.perform(.backToLobby)
        let closedCount = await http.count("/v1/standings")
        await observer.callback?(.standingsRefreshRequested)
        await session.refresh()
        count = await http.count("/v1/standings"); XCTAssertEqual(count, closedCount)
    }

    func testCoalescedGroupEventRefreshesStandingsAfterEarlierBoardReadFinished() async throws {
        let observer = SessionObserver()
        let (session, http, _, _) = try await setup(observer: observer)
        await session.bootstrap(); await session.perform(.setPopoverVisible(true))
        await http.route("/v1/standings", Data(#"{"groupId":"group","championTrainerId":null,"rows":[]}"#.utf8))
        await session.perform(.showStandings)
        await http.suspendNext("/v1/group")
        let refresh = Task { await session.refresh() }
        await http.waitUntilBlocked()
        await session.perform(.refreshStandings) // Ensure the previous board read has finished.
        let before = await http.count("/v1/standings")
        await observer.callback?(.refreshRequested) // Membership changed while the live read was blocked.
        await http.resume(.init(status: 200, body: try JSONEncoder().encode(OnlineBattleGroupMembers(group: account.group, members: []))))
        await refresh.value
        let after = await http.count("/v1/standings")
        XCTAssertGreaterThan(after, before)
    }

    func testStandingsUnauthorizedRevokesAccountInsteadOfLeavingPrivateBoard() async throws {
        let (session, http, _, _) = try await setup()
        await session.bootstrap(); await session.perform(.setPopoverVisible(true))
        await http.route("/v1/standings", Data(), status: 401)
        await session.perform(.showStandings)
        XCTAssertNil(session.presentation.account)
        XCTAssertNil(session.presentation.standings)
        XCTAssertFalse(session.presentation.showsStandings)
        XCTAssertFalse(session.presentation.standingsLoading)
        XCTAssertEqual(session.presentation.phase, .setup)
    }

    func testRematchSecondParticipantTargetsOriginalFirstParticipant() async throws {
        let source = try battle()
        let (session, http, _, _) = try await setup([source], trainer: "trainer-two")
        let member = OnlineBattleMember(trainerId: "trainer-one", displayEmail: "opponent@example.invalid", role: .member, status: .active, joinedAt: 0, online: false)
        await http.route("/v1/group", try JSONEncoder().encode(OnlineBattleGroupMembers(group: account.group, members: [member])))
        await session.bootstrap(); await session.perform(.openBattle(source.battleId)); await session.perform(.prepareRematch(source.battleId))
        XCTAssertEqual(session.presentation.rematchOpponent?.trainerId, "trainer-one")
        XCTAssertEqual(session.presentation.rematchMode, source.mode)
        XCTAssertTrue(session.presentation.canSubmitRematch)
    }

    func testRematchBackgroundReadDoesNotResolveDifferentSourceIntent() async throws {
        let source = try battle(), pending = try changed(rematchPending(battle()), ["rematchOf": "bt_other_source"])
        let (session, http, _, _) = try await setup([source])
        try await activeOpponent(http)
        await session.bootstrap(); await session.perform(.openBattle(source.battleId)); await session.perform(.prepareRematch(source.battleId))
        session.presentation.selectedEntryID = "instance-one"
        await session.perform(.submitRematch)
        await http.route("/v1/battles", try JSONEncoder().encode(OnlineBattlePage(battles: [source, pending], before: nil)))
        await session.refresh()
        XCTAssertEqual(session.presentation.rematchSourceID, source.battleId)
        XCTAssertFalse(session.presentation.canSubmitRematch)
        let posts = await http.count("/v1/battles/\(source.battleId)/rematch")
        XCTAssertEqual(posts, 1)
    }

    func testStandingsLateResponseCannotSurviveCloseDisableOrRevocation() async throws {
        for reset in 0..<6 {
            let observer = SessionObserver(), connection = SessionConnection()
            let (session, http, _, _) = try await setup(connection: connection, observer: observer)
            await session.bootstrap(); await session.perform(.setPopoverVisible(true))
            await http.suspendNext("/v1/standings")
            let opening = Task { await session.perform(.showStandings) }
            await http.waitUntilBlocked()
            switch reset {
            case 0: await session.perform(.backToLobby)
            case 1: await session.setEnabled(false)
            case 2:
                await connection.setState(.revoked)
                await observer.callback?(.changed(await connection.snapshot()))
            case 3: await session.perform(.setPopoverVisible(false))
            case 4:
                let grant = try JSONSerialization.data(withJSONObject: ["trainer": JSONSerialization.jsonObject(with: JSONEncoder().encode(account.trainer)), "group": JSONSerialization.jsonObject(with: JSONEncoder().encode(account.group)), "accessKey": "new-synthetic-key", "recoveryCode": "new-synthetic-code"])
                await http.route("/v1/join", grant)
                await session.perform(.join(inviteCode: "SYNTHETIC", email: "synthetic@example.invalid"))
            default: await session.configureServer("https://new-battle.example.invalid")
            }
            await http.resume(.init(status: 200, body: Data(#"{"groupId":"group","championTrainerId":null,"rows":[]}"#.utf8)))
            await opening.value
            XCTAssertNil(session.presentation.standings)
            XCTAssertFalse(session.presentation.standingsLoading)
            XCTAssertNil(session.presentation.standingsError)
            if reset != 3 { XCTAssertFalse(session.presentation.showsStandings) }
        }
    }

    func testStandingsRejectsMalformedRowsAndForeignGroupLocally() async throws {
        let (session, http, _, _) = try await setup()
        await session.bootstrap(); await session.perform(.setPopoverVisible(true))
        let row: [String: Any] = ["trainerId": "other", "displayName": "Synthetic", "wins": 5, "losses": 0, "draws": 0, "streak": 2, "bestStreak": 3, "winRate": 1.0]
        var invalidRows = [[row, row]]
        for (field, value): (String, Any) in [("wins", -1), ("winRate", 1.5), ("streak", 4), ("bestStreak", 6)] {
            var invalid = row; invalid[field] = value; invalidRows.append([invalid])
        }
        var payloads: [[String: Any]] = invalidRows.map { ["groupId": "group", "championTrainerId": NSNull(), "rows": $0] }
        payloads.append(["groupId": "another-group", "championTrainerId": NSNull(), "rows": [row]])
        payloads.append(["groupId": "group", "championTrainerId": "missing", "rows": [row]])
        for payload in payloads {
            await http.route("/v1/standings", try JSONSerialization.data(withJSONObject: payload))
            await session.perform(.showStandings)
            XCTAssertNil(session.presentation.standings)
            XCTAssertNotNil(session.presentation.standingsError)
            XCTAssertNil(session.presentation.notice)
            XCTAssertEqual(session.presentation.phase, .lobby)
        }
    }

    func testRematchRetryKeepsIntentAndRequiresFreshConsentForNewPendingRoom() async throws {
        let source = try battle()
        let pending = try rematchPending(source)
        let (session, http, _, effects) = try await setup([source])
        try await activeOpponent(http)
        await session.bootstrap(); await session.perform(.openBattle(source.battleId)); await session.perform(.prepareRematch(source.battleId))
        session.presentation.selectedEntryID = "instance-one"
        let path = "/v1/battles/\(source.battleId)/rematch"
        await http.queue(path, [.init(status: 503, body: Data()), try response(pending)])
        await session.perform(.submitRematch)
        XCTAssertNotNil(session.presentation.rematchSourceID)
        await session.perform(.selectEntry("instance-one"))
        await session.perform(.submitRematch)
        let bodies = await http.bodies(path)
        XCTAssertEqual(bodies.count, 2)
        if bodies.count == 2 { XCTAssertEqual(try JSONSerialization.jsonObject(with: bodies[0]) as? NSDictionary, try JSONSerialization.jsonObject(with: bodies[1]) as? NSDictionary) }
        XCTAssertEqual(session.presentation.room?.state, .pending)
        XCTAssertEqual(session.presentation.room?.confirmed, false)
        XCTAssertNil(session.presentation.rematchSourceID)
        XCTAssertEqual(effects.state.onlineBattleHolds.first?.key.battleID, "bt_rematch")
        let starts = await http.count("/v1/battles/bt_rematch/start"); XCTAssertEqual(starts, 0)
    }

    func testRematchFindsLostResponseBySourceAndDoesNotCreateDuplicate() async throws {
        let source = try battle()
        let pending = try rematchPending(source)
        let (session, http, _, effects) = try await setup([source])
        try await activeOpponent(http)
        await session.bootstrap(); await session.perform(.openBattle(source.battleId)); await session.perform(.prepareRematch(source.battleId))
        session.presentation.selectedEntryID = "instance-one"
        await session.perform(.submitRematch) // Lost response; the server created the room.
        await http.route("/v1/battles", try JSONEncoder().encode(OnlineBattlePage(battles: [source, pending], before: nil)))
        await session.perform(.submitRematch)
        let posts = await http.count("/v1/battles/\(source.battleId)/rematch"); XCTAssertEqual(posts, 1)
        XCTAssertEqual(session.presentation.room?.battleId, pending.battleId)
        XCTAssertNil(session.presentation.rematchSourceID)
        XCTAssertEqual(effects.state.onlineBattleHolds.count, 1)
    }

    func testRematchBackgroundReadResolvesLostResponseWithoutLeavingHeldRetry() async throws {
        let source = try battle(), pending = try rematchPending(battle())
        let (session, http, _, effects) = try await setup([source])
        try await activeOpponent(http)
        await session.bootstrap(); await session.perform(.openBattle(source.battleId)); await session.perform(.prepareRematch(source.battleId))
        session.presentation.selectedEntryID = "instance-one"
        await session.perform(.submitRematch)
        await http.route("/v1/battles", try JSONEncoder().encode(OnlineBattlePage(battles: [source, pending], before: nil)))
        await session.refresh()
        XCTAssertNil(session.presentation.rematchSourceID)
        XCTAssertEqual(session.presentation.room?.battleId, pending.battleId)
        XCTAssertEqual(session.presentation.phase, .room)
        XCTAssertEqual(effects.state.onlineBattleHolds.count, 1)
        let posts = await http.count("/v1/battles/\(source.battleId)/rematch")
        XCTAssertEqual(posts, 1)
    }

    func testRematchLostResponseThenLocalHealCancelsStalePendingConsent() async throws {
        for explicitRetry in [false, true] {
            let source = try battle(), pending = try rematchPending(battle())
            let (session, http, _, effects) = try await setup([source])
            try await activeOpponent(http)
            await session.bootstrap(); await session.perform(.openBattle(source.battleId)); await session.perform(.prepareRematch(source.battleId))
            session.presentation.selectedEntryID = "instance-one"
            await session.perform(.submitRematch)
            effects.setHealthShare(0.5, of: "instance-one")
            await http.route("/v1/battles", try JSONEncoder().encode(OnlineBattlePage(battles: [source, pending], before: nil)))
            await http.route("/v1/battles/bt_rematch/cancel", try JSONEncoder().encode(changed(pending, ["state": "CANCELLED"])))
            if explicitRetry { await session.perform(.submitRematch) } else { await session.refresh() }
            let cancels = await http.count("/v1/battles/bt_rematch/cancel")
            XCTAssertEqual(cancels, 1)
            XCTAssertTrue(effects.state.onlineBattleHolds.isEmpty)
            XCTAssertEqual(session.presentation.rematchSourceID, source.battleId)
            XCTAssertTrue(session.presentation.canSubmitRematch)
        }
    }

    func testRematchNotificationBeforeLostResponseStillExposesCreatedRoom() async throws {
        let source = try battle(), pending = try rematchPending(battle())
        let (session, http, _, _) = try await setup([source])
        try await activeOpponent(http)
        await session.bootstrap(); await session.perform(.openBattle(source.battleId)); await session.perform(.prepareRematch(source.battleId))
        session.presentation.selectedEntryID = "instance-one"
        await http.suspendNext("/v1/battles/\(source.battleId)/rematch")
        let submit = Task { await session.perform(.submitRematch) }
        await http.waitUntilBlocked()
        await http.route("/v1/battles", try JSONEncoder().encode(OnlineBattlePage(battles: [source, pending], before: nil)))
        await session.refresh()
        await http.resume(.init(status: 503, body: Data())); await submit.value
        XCTAssertNil(session.presentation.rematchSourceID)
        XCTAssertEqual(session.presentation.room?.battleId, pending.battleId)
        XCTAssertNil(session.presentation.notice)
    }

    func testRematchChangedSnapshotAndSourceGetNewIntent() async throws {
        let source = try battle(), other = try battle(idOverride: "bt_other")
        let (session, http, _, effects) = try await setup([source, other])
        try await activeOpponent(http)
        await session.bootstrap(); await session.perform(.openReplay(source.battleId)); await session.perform(.prepareRematch(source.battleId))
        session.presentation.selectedEntryID = "instance-one"
        await session.perform(.submitRematch)
        effects.setHealthShare(0.5, of: "instance-one")
        await session.perform(.submitRematch)
        let bodies = await http.bodies("/v1/battles/\(source.battleId)/rematch")
        XCTAssertEqual(bodies.count, 2)
        if bodies.count == 2 {
            let first = try JSONSerialization.jsonObject(with: bodies[0]) as! [String: Any]
            let second = try JSONSerialization.jsonObject(with: bodies[1]) as! [String: Any]
            XCTAssertNotEqual(first["requestId"] as? String, second["requestId"] as? String)
            XCTAssertNotEqual((first["snapshot"] as? NSDictionary)?["hp"] as? Int, (second["snapshot"] as? NSDictionary)?["hp"] as? Int)
        }
        await session.perform(.cancelRematch)
        await session.perform(.openReplay(other.battleId))
        await session.perform(.prepareRematch(other.battleId))
        XCTAssertEqual(session.presentation.rematchSourceID, other.battleId)
        await session.perform(.submitRematch)
        let otherBodies = await http.bodies("/v1/battles/\(other.battleId)/rematch")
        XCTAssertEqual(otherBodies.count, 1)
        if let previous = bodies.last, let current = otherBodies.first {
            let old = try JSONSerialization.jsonObject(with: previous) as! [String: Any]
            let new = try JSONSerialization.jsonObject(with: current) as! [String: Any]
            XCTAssertNotEqual(old["requestId"] as? String, new["requestId"] as? String)
        }
    }

    func testRematchRejectsDepartedOpponentFaintedHeldAndNonCompletedSources() async throws {
        let source = try battle()
        let (session, http, _, effects) = try await setup([source])
        try await activeOpponent(http)
        await session.bootstrap(); await session.perform(.openBattle(source.battleId))
        XCTAssertTrue(session.presentation.canRematch(source))
        for candidate in session.presentation.roster { effects.setHealthShare(0, of: candidate.id) }
        await session.perform(.prepareRematch(source.battleId))
        XCTAssertNil(session.presentation.rematchSourceID)
        for candidate in session.presentation.roster { effects.setHealthShare(1, of: candidate.id) }
        try await activeOpponent(http, status: .left); await session.refresh()
        await session.perform(.prepareRematch(source.battleId))
        XCTAssertNil(session.presentation.rematchSourceID)
        try await activeOpponent(http); await session.refresh()
        for candidate in session.presentation.roster {
            try effects.holdOnlineBattle(key: .init(scope: .init(originHash: "other", groupID: "other", trainerID: "other"), battleID: candidate.id), instanceID: candidate.id)
        }
        await session.perform(.prepareRematch(source.battleId))
        XCTAssertNil(session.presentation.rematchSourceID)
        for state in ["VOID", "CANCELLED", "PENDING"] {
            XCTAssertFalse(session.presentation.canRematch(try changed(source, ["state": state])))
        }
        let posts = await http.count("/v1/battles/\(source.battleId)/rematch"); XCTAssertEqual(posts, 0)
    }

    func testRematchHealthChangeDuringSubmissionCancelsNewConsent() async throws {
        let source = try battle()
        let pending = try rematchPending(source)
        let (session, http, _, effects) = try await setup([source])
        try await activeOpponent(http)
        await session.bootstrap(); await session.perform(.openBattle(source.battleId)); await session.perform(.prepareRematch(source.battleId))
        session.presentation.selectedEntryID = "instance-one"
        let cancelled = try changed(pending, ["state": "CANCELLED"])
        await http.route("/v1/battles/bt_rematch/cancel", try JSONEncoder().encode(cancelled))
        await http.suspendNext("/v1/battles/\(source.battleId)/rematch")
        let submit = Task { await session.perform(.submitRematch) }
        await http.waitUntilBlocked()
        effects.setHealthShare(0.5, of: "instance-one")
        await http.resume(try response(pending)); await submit.value
        let cancels = await http.count("/v1/battles/bt_rematch/cancel"); XCTAssertEqual(cancels, 1)
        XCTAssertTrue(effects.state.onlineBattleHolds.isEmpty)
        XCTAssertNotNil(session.presentation.notice)
    }

    func testHistoryRevocationDoesNotRepublishCachedRowsAfterLateFinalRead() async throws {
        let room = try battle(), observer = SessionObserver(), connection = SessionConnection()
        let (session, http, _, effects) = try await setup([room], connection: connection, observer: observer)
        await session.bootstrap()
        await session.perform(.showHistory)
        await session.perform(.openReplay(room.battleId))
        XCTAssertNotNil(session.presentation.replay)
        await http.suspendNext("/v1/battles")
        let pending = Task { await session.refresh() }
        await http.waitUntilBlocked()
        await connection.setState(.revoked)
        await observer.callback?(.changed(await connection.snapshot()))
        await http.resume(.init(status: 200, body: try JSONEncoder().encode(OnlineBattlePage(battles: [room], before: nil))))
        await pending.value
        XCTAssertNil(session.presentation.account)
        XCTAssertNil(session.presentation.replay)
        XCTAssertTrue(session.presentation.battles.isEmpty)
        XCTAssertFalse(session.presentation.showsHistory)
        XCTAssertEqual(effects.applications, 1)
    }

    func testHistoryReportsMissingAndCorruptDataWithoutEffects() async throws {
        let valid = try battle()
        var report = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(valid.result)) as? [String: Any])
        report["logHash"] = "tampered"
        for room in [try changed(valid, ["config": NSNull()]), try changed(valid, ["result": report])] {
            let (session, _, _, effects) = try await setup([room])
            await session.bootstrap()
            await session.perform(.openReplay(room.battleId))
            XCTAssertEqual(session.presentation.selectedHistoryBattle?.battleId, room.battleId)
            XCTAssertNil(session.presentation.replay)
            XCTAssertNotNil(session.presentation.historyError)
            XCTAssertEqual(effects.effectCalls, 0)
        }
    }

    func testHistoryKeepsUnavailableUnpaidSummaryWithoutUnlockingNewChallenges() async throws {
        let valid = try battle()
        var config = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(valid.config)) as? [String: Any])
        config["engineHash"] = String(repeating: "a", count: 64)
        let unavailable = try changed(valid, ["config": config])
        let later = try battle(1)
        let (session, http, _, effects) = try await setup([unavailable, later])
        await session.bootstrap()
        XCTAssertEqual(effects.applications, 0)
        XCTAssertNotNil(session.presentation.notice)
        XCTAssertEqual(Set(session.presentation.battles.map(\.battleId)), Set([unavailable.battleId, later.battleId]))
        await session.perform(.showHistory)
        await session.perform(.openReplay(unavailable.battleId))
        XCTAssertEqual(session.presentation.selectedHistoryBattle?.battleId, unavailable.battleId)
        XCTAssertNil(session.presentation.replay)
        XCTAssertNotNil(session.presentation.historyError)
        await session.perform(.openReplay(later.battleId))
        XCTAssertNotNil(session.presentation.replay)
        XCTAssertEqual(effects.effectCalls, 0)
        await session.perform(.backToLobby)
        await session.perform(.challenge)
        let creations = await http.bodies("/v1/battles")
        XCTAssertTrue(creations.isEmpty)
        XCTAssertEqual(effects.effectCalls, 0)
    }

    func testHistoryReplayNavigationMakesNoRequestsOrEffectCalls() async throws {
        let room = try battle()
        let (session, http, _, effects) = try await setup([room])
        await session.bootstrap()
        let requests = await http.requests.count, calls = effects.effectCalls
        let state = try JSONEncoder().encode(effects.state)
        await session.perform(.showHistory)
        XCTAssertTrue(session.presentation.showsHistory)
        await session.perform(.openReplay(room.battleId))
        let replay = try XCTUnwrap(session.presentation.replay)
        XCTAssertEqual(replay.frames.count, room.journal.count + 1)
        XCTAssertEqual(session.presentation.replayFrameIndex, 0)
        await session.perform(.seekReplay(replay.frames.count - 1))
        XCTAssertEqual(session.presentation.replayFrameIndex, replay.frames.count - 1)
        await session.perform(.seekReplay(-1))
        XCTAssertEqual(session.presentation.replayFrameIndex, replay.frames.count - 1)
        await session.perform(.closeReplay)
        XCTAssertNil(session.presentation.replay)
        XCTAssertTrue(session.presentation.showsHistory)
        let after = await http.requests.count
        XCTAssertEqual(after, requests)
        XCTAssertEqual(effects.effectCalls, calls)
        // Encode sorted JSON to compare unchanged semantic state, irrespective of dictionary order.
        XCTAssertEqual(try JSONSerialization.jsonObject(with: state) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: JSONEncoder().encode(effects.state)) as? NSDictionary)
    }
    func testHistoryFrameSurvivesLiveRefreshAndLobbyClosesOverlay() async throws {
        let room = try battle()
        let (session, _, _, effects) = try await setup([room])
        await session.bootstrap()
        await session.perform(.showHistory)
        await session.perform(.openReplay(room.battleId))
        await session.perform(.seekReplay(1))
        await session.refresh()
        XCTAssertTrue(session.presentation.showsHistory)
        XCTAssertEqual(session.presentation.replay?.battleID, room.battleId)
        XCTAssertEqual(session.presentation.replayFrameIndex, 1)
        XCTAssertEqual(effects.applications, 1)
        await session.perform(.backToLobby)
        XCTAssertFalse(session.presentation.showsHistory)
        XCTAssertNil(session.presentation.replay)
        XCTAssertNil(session.presentation.selectedHistoryBattle)
    }
    func testHistoryIsClearedByKeyGateAndServerChange() async throws {
        let room = try battle()
        let (session, _, _, _) = try await setup([room])
        await session.bootstrap()
        await session.perform(.openReplay(room.battleId))
        XCTAssertNotNil(session.presentation.replay)
        await session.setEnabled(false)
        XCTAssertNil(session.presentation.replay)
        XCTAssertFalse(session.presentation.showsHistory)
        await session.perform(.showHistory)
        await session.perform(.openReplay(room.battleId))
        XCTAssertNil(session.presentation.replay)
        XCTAssertFalse(session.presentation.showsHistory)
        await session.setEnabled(true)
        await session.perform(.openReplay(room.battleId))
        XCTAssertNotNil(session.presentation.replay)
        await session.configureServer("https://new.example.invalid")
        XCTAssertNil(session.presentation.replay)
        XCTAssertNil(session.presentation.selectedHistoryBattle)
        XCTAssertFalse(session.presentation.showsHistory)
    }
    func testHistoryCancelledDeclinedAndExpiredRoomsHaveSummaryWithoutReplay() async throws {
        for state in ["CANCELLED", "DECLINED", "EXPIRED"] {
            let room = try changed(battle(), ["state": state, "config": NSNull(), "result": NSNull(), "journal": [], "roundSeq": 0])
            let (session, _, _, effects) = try await setup([room])
            await session.bootstrap()
            await session.perform(.openReplay(room.battleId))
            XCTAssertEqual(session.presentation.selectedHistoryBattle?.battleId, room.battleId)
            XCTAssertNil(session.presentation.replay)
            XCTAssertTrue(session.presentation.historyError?.contains("시작 전에 종료") == true)
            XCTAssertEqual(effects.effectCalls, 0)
        }
    }
    func testHistoryVoidKeepsSummaryWithoutReplayingAndUnknownIDCannotSelect() async throws {
        let room = try changed(battle(), ["state": "VOID", "result": NSNull()])
        let (session, http, _, effects) = try await setup([room])
        await session.bootstrap()
        let requests = await http.requests.count
        await session.perform(.showHistory)
        await session.perform(.openReplay(room.battleId))
        XCTAssertEqual(session.presentation.selectedHistoryBattle?.state, .void)
        XCTAssertNil(session.presentation.replay)
        XCTAssertNotNil(session.presentation.historyError)
        await session.perform(.closeReplay)
        await session.perform(.openReplay("bt_unknown"))
        XCTAssertNil(session.presentation.selectedHistoryBattle)
        let after = await http.requests.count
        XCTAssertEqual(after, requests)
        XCTAssertEqual(effects.effectCalls, 0)
    }
    // T05: a newer request must not hide the match that is still being played or verified after a relaunch.
    func testRelaunchShowsTheRunningMatchEvenWhenANewerChallengeIsPending() async throws {
        let running = try changed(battle(), ["state": "RUNNING", "result": NSNull(), "roundSeq": 1, "journal": []])
        let newer = try changed(battle(idOverride: "bt_newer"), ["state": "PENDING", "result": NSNull(), "journal": [], "createdAt": running.createdAt + 60_000])
        let (session, _, _, _) = try await setup([newer, running])
        await session.bootstrap()
        XCTAssertEqual(session.presentation.room?.battleId, running.battleId)
        XCTAssertEqual(session.presentation.phase, .arena)
    }
    func testRelaunchShowsTheVerifyingMatchEvenWhenANewerChallengeIsPending() async throws {
        let reported = try changed(battle(), ["state": "REPORTED"])
        let newer = try changed(battle(idOverride: "bt_newer"), ["state": "PENDING", "result": NSNull(), "journal": [], "createdAt": reported.createdAt + 60_000])
        let (session, http, _, _) = try await setup([newer, reported])
        // The relaunched app re-sends its identical report; the server answers that it is already REPORTED.
        await http.route("/v1/battles/\(reported.battleId)/report", try JSONEncoder().encode(reported))
        await session.bootstrap()
        XCTAssertEqual(Set(session.presentation.battles.map(\.battleId)), [reported.battleId, newer.battleId], "both rooms were processed")
        XCTAssertEqual(session.presentation.room?.battleId, reported.battleId)
        XCTAssertEqual(session.presentation.phase, .verifying)
    }
    func testRelaunchStillShowsTheNewestPendingChallengeWhenNothingIsRunning() async throws {
        let older = try changed(battle(), ["state": "PENDING", "result": NSNull(), "journal": []])
        let newer = try changed(battle(idOverride: "bt_newer"), ["state": "PENDING", "result": NSNull(), "journal": [], "createdAt": older.createdAt + 60_000])
        let (session, _, _, _) = try await setup([older, newer])
        await session.bootstrap()
        XCTAssertEqual(session.presentation.room?.battleId, newer.battleId)
        XCTAssertEqual(session.presentation.phase, .room)
    }
    func testHistoryOverlayBlocksHiddenLiveManualChoiceAtSessionBoundary() async throws {
        let room = try changed(battle(), ["state": "RUNNING", "result": NSNull(), "roundSeq": 1, "journal": []])
        let (session, http, _, _) = try await setup([room])
        await session.bootstrap()
        XCTAssertEqual(session.presentation.phase, .arena)
        XCTAssertEqual(session.presentation.request?.kind, "move")
        await session.perform(.showHistory)
        let requests = await http.requests.count
        await session.perform(.chooseMove(1))
        let after = await http.requests.count
        XCTAssertEqual(after, requests)
    }

    func testOnlineBattleSetupDraftSeedsSavedServerOnceAndKeepsFailedGrantUntilSaveSucceeds() async throws {
        let credentials = SessionCredentials(); await credentials.setKey(nil)
        let (session, http, _, _) = try await setup(credential: credentials)
        XCTAssertEqual(session.presentation.setupInput.server, "https://battle.example.invalid")
        session.presentation.setupInput = .init(server: "https://draft.example.invalid", invite: "ABCD-EFGH-JKMN", nickname: "나래", recovery: "recovery", reconnect: "reconnect")
        await session.bootstrap()
        XCTAssertEqual(session.presentation.setupInput.server, "https://draft.example.invalid")
        let original = session.presentation.setupInput
        await http.route("/v1/join", Data(#"{"error":{"code":"invalid_invite"}}"#.utf8), status: 404)
        await session.join(inviteCode: original.invite, email: original.nickname)
        XCTAssertEqual(session.presentation.setupInput, original)
        let body = try JSONSerialization.data(withJSONObject: ["trainer": JSONSerialization.jsonObject(with: JSONEncoder().encode(account.trainer)), "group": JSONSerialization.jsonObject(with: JSONEncoder().encode(account.group)), "accessKey": "issued-key", "recoveryCode": "one-time-code"])
        await http.route("/v1/join", body); await credentials.setFailure(true)
        await session.join(inviteCode: original.invite, email: original.nickname)
        XCTAssertEqual(session.presentation.setupInput, original)
        await credentials.setFailure(false); await session.retryCredentialSave()
        XCTAssertEqual(session.presentation.setupInput, .init(server: original.server))
        XCTAssertEqual(session.presentation.recoveryCode, "one-time-code")
        let joins = await http.count("/v1/join"); XCTAssertEqual(joins, 2)
    }
    func testOnlineBattleExistingKeyClearsDraftCodesOnlyAfterValidatedAccount() async throws {
        for failure in ["transport", "group", "unauthorized", "none"] {
            let (session, http, _, _) = try await setup()
            session.presentation.setupInput = .init(server: "https://battle.example.invalid", invite: "invite", nickname: "나래", recovery: "recovery", reconnect: "reconnect")
            if failure == "transport" { await http.route("/v1/me", Data(), status: 503) }
            if failure == "unauthorized" { await http.route("/v1/me", Data(), status: 401) }
            if failure == "group" {
                let group = OnlineBattleGroup(groupId: "wrong", name: "Wrong", hostTrainerId: "other")
                await http.route("/v1/group", try JSONEncoder().encode(OnlineBattleGroupMembers(group: group, members: [])))
            }
            await session.bootstrap()
            XCTAssertEqual(session.presentation.setupInput.invite.isEmpty, failure == "none" || failure == "unauthorized")
            XCTAssertEqual(session.presentation.setupInput.recovery.isEmpty, failure == "none" || failure == "unauthorized")
            XCTAssertEqual(session.presentation.setupInput.reconnect.isEmpty, failure == "none" || failure == "unauthorized")
            XCTAssertEqual(session.presentation.setupInput.nickname, "나래")
        }
        let credentials = SessionCredentials(); await credentials.setKey(nil)
        let (session, http, _, _) = try await setup(credential: credentials)
        await session.bootstrap()
        session.presentation.setupInput.recovery = "retry-recovery"
        await http.route("/v1/recover", Data(), status: 401)
        await session.perform(.recover(code: "retry-recovery"))
        XCTAssertEqual(session.presentation.setupInput.recovery, "retry-recovery")
    }
    func testOnlineBattleSetupIdentityBoundariesClearSecretsButInitialApplyKeepsInvitation() async throws {
        let (session, _, credentials, _) = try await setup()
        await credentials.setKey(nil)
        session.presentation.setupInput = .init(server: "https://next.example.invalid", invite: "ABCD-EFGH-JKMN", nickname: "나래", recovery: "old-recovery", reconnect: "old-reconnect")
        await session.configureServer("https://next.example.invalid")
        XCTAssertEqual(session.presentation.setupInput.invite, "ABCD-EFGH-JKMN")
        XCTAssertEqual(session.presentation.setupInput.nickname, "나래")
        XCTAssertEqual(session.presentation.setupInput.recovery, "")
        XCTAssertEqual(session.presentation.setupInput.reconnect, "")
        session.presentation.setupInput.recovery = "recovery"; session.presentation.setupInput.reconnect = "reconnect"
        await session.setEnabled(false)
        XCTAssertEqual(session.presentation.setupInput, .init(server: "https://next.example.invalid", nickname: "나래"))
    }
    private func grantBody() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["trainer": JSONSerialization.jsonObject(with: JSONEncoder().encode(account.trainer)), "group": JSONSerialization.jsonObject(with: JSONEncoder().encode(account.group)), "accessKey": "issued-key", "recoveryCode": "one-time-code"])
    }
    func testApplyingServerSavesTheTypedAddressThenJoinsAgainstIt() async throws {
        let credentials = SessionCredentials(); await credentials.setKey(nil)
        let (session, http, _, _) = try await setup(credential: credentials)
        await http.route("/v1/join", try grantBody())
        await session.perform(.applyingServer("https://new.example.invalid", .join(inviteCode: "invite", email: "synthetic@example.invalid")))
        XCTAssertEqual(session.presentation.serverAddress, "https://new.example.invalid")
        XCTAssertEqual(session.presentation.account, account)
        let hosts = await http.requests.filter { $0.url?.path == "/v1/join" }.compactMap { $0.url?.host }
        XCTAssertEqual(hosts, ["new.example.invalid"], "the join must go to the address the user typed, not the previous one")
    }
    func testApplyingServerWorksForRecoveryToo() async throws {
        let credentials = SessionCredentials(); await credentials.setKey(nil)
        let (session, http, _, _) = try await setup(credential: credentials)
        await http.route("/v1/recover", try grantBody())
        await session.perform(.applyingServer("https://new.example.invalid", .recover(code: "recovery")))
        XCTAssertEqual(session.presentation.serverAddress, "https://new.example.invalid")
        XCTAssertEqual(session.presentation.account, account)
        let hosts = await http.requests.filter { $0.url?.path == "/v1/recover" }.compactMap { $0.url?.host }
        XCTAssertEqual(hosts, ["new.example.invalid"])
    }
    func testApplyingServerOnAnEmbeddedBuildChangesNothingAndNeverJoins() async throws {
        let credentials = SessionCredentials(); await credentials.setKey(nil)
        let (session, http, _, _) = try await setup(credential: credentials, embeddedServer: "https://embedded.example.invalid")
        await http.route("/v1/join", try grantBody())
        await session.bootstrap() // A started session is exactly where an unguarded inner join would reach the network.
        await session.perform(.applyingServer("https://other.example.invalid", .join(inviteCode: "invite", email: "synthetic@example.invalid")))
        XCTAssertEqual(session.presentation.serverAddress, "https://embedded.example.invalid")
        XCTAssertNil(session.presentation.account)
        let joins = await http.count("/v1/join"); XCTAssertEqual(joins, 0)
    }
    func testEmbeddedBuildJoinsAndRecoversAgainstItsFixedAddressWithoutAnyApplyStep() async throws {
        for path in ["/v1/join", "/v1/recover"] {
            let credentials = SessionCredentials(); await credentials.setKey(nil)
            let (session, http, _, _) = try await setup(credential: credentials, embeddedServer: "https://embedded.example.invalid")
            await http.route(path, try grantBody())
            await session.bootstrap()
            await session.perform(path == "/v1/join" ? .join(inviteCode: "invite", email: "synthetic@example.invalid") : .recover(code: "recovery"))
            XCTAssertEqual(session.presentation.account, account, path)
            let hosts = await http.requests.filter { $0.url?.path == path }.compactMap { $0.url?.host }
            XCTAssertEqual(hosts, ["embedded.example.invalid"], path)
        }
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
        await session.bootstrap(); await session.refresh(); await session.perform(.openBattle(room.battleId))
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
    private func notify(_ observer: SessionObserver, _ connection: SessionConnection, room: OnlineBattleView,
                        fields: [String: Any]) async throws {
        var object = fields; object["v"] = 1; object["battleId"] = room.battleId
        await observer.callback?(.battleNotification(await connection.snapshot(), battleID: room.battleId,
            payload: try JSONSerialization.data(withJSONObject: object)))
    }
    private func pairNotice(_ room: OnlineBattleView, seq: Int = 1) throws -> [String: Any] {
        ["type": "battle_round", "pair": try JSONSerialization.jsonObject(with: JSONEncoder().encode(room.journal[seq - 1]))]
    }
    func testPublicPairBeforeChoiceResponseDoesNotRollBackOpenRoundOrReadAccount() async throws {
        let final = try battle(), observer = SessionObserver(), connection = SessionConnection(), clock = SessionClock()
        let initial = try changed(final, ["state": "RUNNING", "result": NSNull(), "roundSeq": 1, "deadline": 60000, "journal": []])
        let opened = try changed(initial, ["roundSeq": 2, "deadline": 61000,
            "journal": JSONSerialization.jsonObject(with: JSONEncoder().encode(Array(final.journal.prefix(1))))])
        let (session, http, _, _) = try await setup([initial], connection: connection, observer: observer, clock: .init(now: { clock.now() }))
        let advance = "/v1/battles/\(final.battleId)/advance"
        await http.route(advance, try JSONEncoder().encode(opened)); await session.bootstrap()
        await http.suspendNext("/v1/battles/\(final.battleId)/choices")
        let choosing = Task { await session.perform(.chooseMove(1)) }; await http.waitUntilBlocked()
        try await notify(observer, connection, room: final, fields: pairNotice(final))
        XCTAssertEqual(session.presentation.room?.roundSeq, 2)
        await http.resume(try response(changed(initial, ["ownChoice": "move 1"])))
        await choosing.value
        try await notify(observer, connection, room: final, fields: pairNotice(final))
        try await notify(observer, connection, room: final, fields: ["type": "battle_changed", "state": "RUNNING", "revision": initial.revision, "roundSeq": 1, "deadline": NSNull()])
        XCTAssertEqual(session.presentation.room?.journal.count, 1)
        XCTAssertEqual(session.presentation.room?.deadline, 61000)
        XCTAssertNil(session.presentation.room?.ownChoice)
        let advances = await http.count(advance), reads = await http.count("/v1/me"), roomReads = await http.count("/v1/battles/\(final.battleId)")
        XCTAssertEqual(advances, 1); XCTAssertEqual(reads, 1); XCTAssertEqual(roomReads, 0)
    }
    func testAdvanceLocksBeforeAwaitAcrossNotificationAndRefresh() async throws {
        let final = try battle(), observer = SessionObserver(), connection = SessionConnection()
        let initial = try changed(final, ["state": "RUNNING", "result": NSNull(), "roundSeq": 1, "deadline": 60000, "journal": []])
        let released = try changed(initial, ["deadline": NSNull(), "journal": JSONSerialization.jsonObject(with: JSONEncoder().encode(Array(final.journal.prefix(1))))])
        let opened = try changed(released, ["roundSeq": 2, "deadline": 61000])
        let (session, http, _, _) = try await setup([initial], connection: connection, observer: observer)
        await session.bootstrap()
        let path = "/v1/battles/\(final.battleId)/advance"
        await http.suspendNext(path)
        let incoming = Task { try await self.notify(observer, connection, room: final, fields: self.pairNotice(final)) }
        await http.waitUntilBlocked()
        await http.route("/v1/battles", try JSONEncoder().encode(OnlineBattlePage(battles: [released], before: nil)))
        await session.refresh()
        let count = await http.count(path); XCTAssertEqual(count, 1)
        await http.resume(try response(opened)); try await incoming.value
        XCTAssertEqual(session.presentation.room?.roundSeq, 2)
    }
    func testSecondPlayerConsumesOpenNotificationAndCancelsFallback() async throws {
        let final = try battle(), observer = SessionObserver(), connection = SessionConnection(), clock = SessionClock()
        let initial = try changed(final, ["state": "RUNNING", "result": NSNull(), "roundSeq": 1, "deadline": 60000, "journal": []])
        let (session, http, _, _) = try await setup([initial], trainer: "trainer-two", connection: connection, observer: observer, clock: .init(now: { clock.now() }))
        await session.bootstrap()
        try await notify(observer, connection, room: final, fields: pairNotice(final))
        try await notify(observer, connection, room: final, fields: ["type": "battle_changed", "state": "RUNNING", "revision": initial.revision, "roundSeq": 2, "deadline": 61000])
        clock.advance(2); await session.tick()
        XCTAssertEqual(session.presentation.room?.roundSeq, 2); XCTAssertEqual(session.presentation.room?.deadline, 61000)
        let advances = await http.count("/v1/battles/\(final.battleId)/advance"), reads = await http.count("/v1/battles/\(final.battleId)")
        XCTAssertEqual(advances, 0); XCTAssertEqual(reads, 0)
    }
    // D7: the server's first-choice signal is a battle_changed with the same revision, round and deadline plus one flag.
    private func signal(_ room: OnlineBattleView, seq: Int = 1, deadline: Double = 60000, flag: Any? = true) -> [String: Any] {
        var fields: [String: Any] = ["type": "battle_changed", "state": "RUNNING", "revision": room.revision, "roundSeq": seq, "deadline": deadline]
        if let flag { fields["opponentSubmitted"] = flag }
        return fields
    }
    func testFirstChoiceSignalMarksTheOpponentWithoutAnyReadAndResetsNextRound() async throws {
        let final = try battle(), observer = SessionObserver(), connection = SessionConnection()
        let initial = try changed(final, ["state": "RUNNING", "result": NSNull(), "roundSeq": 1, "deadline": 60000, "journal": []])
        let (session, http, _, _) = try await setup([initial], trainer: "trainer-two", connection: connection, observer: observer)
        await session.bootstrap()
        let before = await http.count("/v1/battles/\(final.battleId)"), meBefore = await http.count("/v1/me")
        XCTAssertNotEqual(session.presentation.room?.opponentSubmitted, true)
        try await notify(observer, connection, room: final, fields: signal(initial))
        XCTAssertEqual(session.presentation.room?.opponentSubmitted, true)
        XCTAssertEqual(session.presentation.room?.roundSeq, 1); XCTAssertEqual(session.presentation.room?.deadline, 60000)
        try await notify(observer, connection, room: final, fields: signal(initial)) // a duplicate changes nothing
        XCTAssertEqual(session.presentation.room?.opponentSubmitted, true)
        // The pair for that round and the next round's open notice clear it.
        try await notify(observer, connection, room: final, fields: pairNotice(final))
        XCTAssertNotEqual(session.presentation.room?.opponentSubmitted, true)
        try await notify(observer, connection, room: final, fields: ["type": "battle_changed", "state": "RUNNING", "revision": initial.revision, "roundSeq": 2, "deadline": 61000])
        XCTAssertEqual(session.presentation.room?.roundSeq, 2); XCTAssertNotEqual(session.presentation.room?.opponentSubmitted, true)
        try await notify(observer, connection, room: final, fields: signal(initial, seq: 2, deadline: 61000))
        XCTAssertEqual(session.presentation.room?.opponentSubmitted, true); XCTAssertEqual(session.presentation.room?.roundSeq, 2)
        let reads = await http.count("/v1/battles/\(final.battleId)"), me = await http.count("/v1/me"), advances = await http.count("/v1/battles/\(final.battleId)/advance")
        XCTAssertEqual(reads, before); XCTAssertEqual(me, meBefore); XCTAssertEqual(advances, 0)
    }
    func testFirstChoiceSignalIsIgnoredWhenOldMissingFalseOrForAnotherDeadline() async throws {
        let final = try battle(), observer = SessionObserver(), connection = SessionConnection()
        let initial = try changed(final, ["state": "RUNNING", "result": NSNull(), "roundSeq": 1, "deadline": 60000, "journal": []])
        let (session, http, _, _) = try await setup([initial], trainer: "trainer-two", connection: connection, observer: observer)
        await http.route("/v1/battles/\(final.battleId)", try JSONEncoder().encode(initial)); await session.bootstrap()
        // An older notice without the field, and a field that is not true, leave the view and the HTTP count alone.
        for flag: Any? in [nil, false, NSNull(), "yes"] {
            try await notify(observer, connection, room: final, fields: signal(initial, flag: flag))
            XCTAssertNotEqual(session.presentation.room?.opponentSubmitted, true)
        }
        var reads = await http.count("/v1/battles/\(final.battleId)"); XCTAssertEqual(reads, 0)
        // A different deadline is not provably the same round: the old rule applies and one authoritative read follows.
        try await notify(observer, connection, room: final, fields: signal(initial, seq: 1, deadline: 99000))
        reads = await http.count("/v1/battles/\(final.battleId)"); XCTAssertEqual(reads, 1)
        XCTAssertNotEqual(session.presentation.room?.opponentSubmitted, true)
        // A signal for a round already released is late and dropped without another read.
        try await notify(observer, connection, room: final, fields: pairNotice(final))
        try await notify(observer, connection, room: final, fields: signal(initial))
        XCTAssertNotEqual(session.presentation.room?.opponentSubmitted, true)
        reads = await http.count("/v1/battles/\(final.battleId)"); XCTAssertEqual(reads, 1)
    }
    func testFirstChoiceSignalForAFinishedRoomIsIgnored() async throws {
        let final = try battle(), observer = SessionObserver(), connection = SessionConnection()
        let (session, http, _, _) = try await setup([final], trainer: "trainer-two", connection: connection, observer: observer)
        await session.bootstrap()
        let before = await http.count("/v1/battles/\(final.battleId)")
        try await notify(observer, connection, room: final, fields: signal(final, seq: 1, deadline: 60000))
        let reads = await http.count("/v1/battles/\(final.battleId)")
        XCTAssertEqual(reads, before); XCTAssertNotEqual(session.presentation.room?.opponentSubmitted, true)
    }
    func testFirstChoiceSignalThatArrivesInsteadOfAMissedOpenNoticeStillMarksTheNewRound() async throws {
        let final = try battle(), observer = SessionObserver(), connection = SessionConnection()
        let initial = try changed(final, ["state": "RUNNING", "result": NSNull(), "roundSeq": 1,
            "journal": JSONSerialization.jsonObject(with: JSONEncoder().encode(Array(final.journal.prefix(1))))])
        let deadline = final.journal[0].releasedAt + 30_000
        let (session, http, _, _) = try await setup([initial], trainer: "trainer-two", connection: connection, observer: observer)
        await session.bootstrap()
        try await notify(observer, connection, room: final, fields: signal(initial, seq: 2, deadline: deadline))
        let reads = await http.count("/v1/battles/\(final.battleId)")
        XCTAssertEqual(reads, 0); XCTAssertEqual(session.presentation.room?.roundSeq, 2)
        XCTAssertEqual(session.presentation.room?.opponentSubmitted, true)
    }
    func testMissingPairLegacyMetadataAndInvalidTokensRecoverOnlyThatBattle() async throws {
        let final = try battle(), observer = SessionObserver(), connection = SessionConnection(), clock = SessionClock()
        let initial = try changed(final, ["state": "RUNNING", "result": NSNull(), "roundSeq": 1, "deadline": 60000, "journal": []])
        let (session, http, _, _) = try await setup([initial], trainer: "trainer-two", connection: connection, observer: observer, clock: .init(now: { clock.now() }))
        await http.route("/v1/battles/\(final.battleId)", try JSONEncoder().encode(initial)); await session.bootstrap()
        let bad: [String: Any] = ["type": "battle_round", "pair": ["roundSeq": 1, "p1": ["kind": "move", "slot": 1, "source": ">eval 1"], "p2": ["kind": "timeout"], "releasedAt": 1]]
        for fields in [
            ["type": "battle_changed", "state": "RUNNING", "revision": initial.revision],
            ["type": "battle_changed", "state": "RUNNING", "revision": initial.revision, "roundSeq": 1],
            ["type": "battle_changed", "state": "RUNNING", "revision": initial.revision, "roundSeq": 2, "deadline": 61000],
            try pairNotice(final, seq: 2), bad,
            ["type": "battle_round", "pair": ["roundSeq": 1, "p1": ["kind": "policy"], "p2": ["kind": "policy"], "releasedAt": 1]]
        ] { try await notify(observer, connection, room: final, fields: fields) }
        let reads = await http.count("/v1/battles/\(final.battleId)"), all = await http.count("/v1/me")
        XCTAssertEqual(reads, 6); XCTAssertEqual(all, 1); XCTAssertEqual(session.presentation.room?.journal.count, 0)
    }
    func testTerminalNoticeNeedsHTTPBeforeReleasingHoldAndOldGenerationIsIgnored() async throws {
        let final = try battle(), observer = SessionObserver(), connection = SessionConnection()
        let initial = try changed(final, ["state": "RUNNING", "result": NSNull(), "roundSeq": 1, "deadline": 60000, "journal": []])
        let (session, http, _, effects) = try await setup([initial], connection: connection, observer: observer)
        await session.bootstrap()
        let payload = try JSONSerialization.data(withJSONObject: ["type": "battle_changed", "state": "VOID", "revision": initial.revision])
        await observer.callback?(.battleNotification(.init(state: .connected, generation: 0, connectionId: "old", trainerId: "trainer-one", groupId: "group"), battleID: final.battleId, payload: payload))
        var reads = await http.count("/v1/battles/\(final.battleId)"); XCTAssertEqual(reads, 0)
        await http.suspendNext("/v1/battles/\(final.battleId)")
        let incoming = Task { await observer.callback?(.battleNotification(await connection.snapshot(), battleID: final.battleId, payload: payload)) }
        await http.waitUntilBlocked()
        XCTAssertEqual(effects.state.onlineBattleHolds.count, 1); XCTAssertEqual(effects.applications, 0)
        await http.resume(try response(changed(initial, ["state": "VOID", "reason": "report_timeout"])))
        await incoming.value
        XCTAssertTrue(effects.state.onlineBattleHolds.isEmpty); XCTAssertEqual(effects.applications, 0)
        reads = await http.count("/v1/battles/\(final.battleId)"); XCTAssertEqual(reads, 1)
    }
    func testBackToLobbyPreservesPendingSecondPlayerFallback() async throws {
        let final = try battle(), clock = SessionClock()
        let first = try changed(final, ["state": "RUNNING", "result": NSNull(), "roundSeq": 1,
            "journal": JSONSerialization.jsonObject(with: JSONEncoder().encode(Array(final.journal.prefix(1))))])
        let (session, http, _, _) = try await setup([first], trainer: "trainer-two", clock: .init(now: { clock.now() }))
        let opened = try changed(first, ["roundSeq": 2, "deadline": 63000]), path = "/v1/battles/\(final.battleId)/advance"
        await http.route(path, try JSONEncoder().encode(opened)); await session.bootstrap()
        await session.perform(.backToLobby); clock.advance(2); await session.tick()
        let count = await http.count(path); XCTAssertEqual(count, 1)
        await session.perform(.openBattle(first.battleId)); XCTAssertEqual(session.presentation.room?.roundSeq, 2)
    }
    func testBackToLobbyPreservesInFlightAdvanceLock() async throws {
        let final = try battle(), observer = SessionObserver(), connection = SessionConnection()
        let initial = try changed(final, ["state": "RUNNING", "result": NSNull(), "roundSeq": 1, "deadline": 60000, "journal": []])
        let released = try changed(initial, ["deadline": NSNull(), "journal": JSONSerialization.jsonObject(with: JSONEncoder().encode(Array(final.journal.prefix(1))))])
        let (session, http, _, _) = try await setup([initial], connection: connection, observer: observer)
        let path = "/v1/battles/\(final.battleId)/advance"
        await session.bootstrap(); await http.suspendNext(path)
        let incoming = Task { try await self.notify(observer, connection, room: final, fields: self.pairNotice(final)) }
        await http.waitUntilBlocked(); await session.perform(.backToLobby)
        await http.route("/v1/battles", try JSONEncoder().encode(OnlineBattlePage(battles: [released], before: nil)))
        await session.refresh()
        let count = await http.count(path); XCTAssertEqual(count, 1)
        await http.resume(try response(changed(released, ["roundSeq": 2, "deadline": 61000]))); try await incoming.value
    }
    func testOpenNotificationUsesServerDeadlineDespiteClientClockSkew() async throws {
        for localTime in [1.0, 100_000.0] {
            let final = try battle(), observer = SessionObserver(), connection = SessionConnection()
            let initial = try changed(final, ["state": "RUNNING", "result": NSNull(), "roundSeq": 1,
                "journal": JSONSerialization.jsonObject(with: JSONEncoder().encode(Array(final.journal.prefix(1))))])
            let deadline = final.journal[0].releasedAt + 30_000
            let (session, http, _, _) = try await setup([initial], trainer: "trainer-two", connection: connection, observer: observer, clock: .init(now: { localTime }))
            await session.bootstrap()
            try await notify(observer, connection, room: final, fields: ["type": "battle_changed", "state": "RUNNING", "revision": initial.revision, "roundSeq": 2, "deadline": deadline])
            let reads = await http.count("/v1/battles/\(final.battleId)"); XCTAssertEqual(reads, 0)
            XCTAssertEqual(session.presentation.room?.roundSeq, 2); XCTAssertEqual(session.presentation.room?.deadline, deadline)
        }
    }
    func testTimeoutAndAutomaticPairsUseClosedTokensWithoutRoundReads() async throws {
        for index in [2, 6] {
            let final = try battle(index), observer = SessionObserver(), connection = SessionConnection()
            let initial = try changed(final, ["state": "RUNNING", "result": NSNull(), "roundSeq": 1, "deadline": NSNull(), "journal": []])
            let (session, http, _, _) = try await setup([initial], trainer: "trainer-two", rosterOverride: roster(final), connection: connection, observer: observer)
            await session.bootstrap()
            try await notify(observer, connection, room: final, fields: pairNotice(final))
            if index == 6 { try await notify(observer, connection, room: final, fields: pairNotice(final, seq: 2)) }
            XCTAssertEqual(session.presentation.room?.journal.count, index == 6 ? 2 : 1)
            let reads = await http.count("/v1/battles/\(final.battleId)")
            XCTAssertEqual(reads, 0)
            await session.setEnabled(false)
        }
    }
    func testGroupMismatchForOtherParticipantsDoesNotQueryAnUnrelatedBattle() async throws {
        let observer = SessionObserver(), connection = SessionConnection(), unrelated = try battle()
        let (session, http, _, effects) = try await setup(connection: connection, observer: observer)
        await session.bootstrap()
        try await notify(observer, connection, room: unrelated, fields: ["type": "battle_void", "reason": "result_mismatch"])
        let reads = await http.count("/v1/battles/\(unrelated.battleId)")
        XCTAssertEqual(reads, 0); XCTAssertNil(session.presentation.notice); XCTAssertEqual(effects.applications, 0)
    }
    func testSecondPlayerAutomaticTimerFallsBackWithoutExplicitTick() async throws {
        let final = try battle()
        let first = try changed(final, ["state": "RUNNING", "result": NSNull(), "roundSeq": 1,
            "journal": JSONSerialization.jsonObject(with: JSONEncoder().encode(Array(final.journal.prefix(1))))])
        let opened = try changed(first, ["roundSeq": 2, "deadline": Date().timeIntervalSince1970 * 1000 + 30000])
        let (session, http, _, _) = try await setup([first], trainer: "trainer-two", automaticTicks: true)
        let path = "/v1/battles/\(final.battleId)/advance"
        await http.suspendNext(path); await session.bootstrap()
        await http.waitUntilBlocked()
        let count = await http.count(path); XCTAssertEqual(count, 1)
        await http.resume(try response(opened))
        for _ in 0..<50 where session.presentation.room?.roundSeq != 2 { await Task.yield() }
        XCTAssertEqual(session.presentation.room?.roundSeq, 2)
        await session.setEnabled(false)
    }
    func testFallbackResponseLossRecoversOpenedDeadlineAtFiveSecondsWithoutFullRefresh() async throws {
        let final = try battle(), clock = SessionClock()
        let first = try changed(final, ["state": "RUNNING", "result": NSNull(), "roundSeq": 1,
            "journal": JSONSerialization.jsonObject(with: JSONEncoder().encode(Array(final.journal.prefix(1))))])
        let opened = try changed(first, ["roundSeq": 2, "deadline": 63000])
        let (session, http, _, _) = try await setup([first], trainer: "trainer-two", clock: .init(now: { clock.now() }))
        let path = "/v1/battles/\(final.battleId)"
        await http.route(path + "/advance", Data(), status: 503)
        await http.route(path, try JSONEncoder().encode(opened))
        await session.bootstrap(); clock.advance(2); await session.tick()
        var count = await http.count(path); XCTAssertEqual(count, 0)
        clock.advance(4.99); await session.tick(); count = await http.count(path); XCTAssertEqual(count, 0)
        clock.advance(0.01); await session.tick()
        count = await http.count(path); XCTAssertEqual(count, 1)
        let advances = await http.count(path + "/advance"), all = await http.count("/v1/me")
        XCTAssertEqual(advances, 1); XCTAssertEqual(all, 1)
        XCTAssertEqual(session.presentation.room?.deadline, 63000)
    }
    func testChangedDuplicateAndTerminalNotificationDuringBattleReadRequireFollowupProof() async throws {
        let final = try battle(), observer = SessionObserver(), connection = SessionConnection(), clock = SessionClock()
        let first = try changed(final, ["state": "RUNNING", "result": NSNull(), "roundSeq": 1,
            "journal": JSONSerialization.jsonObject(with: JSONEncoder().encode(Array(final.journal.prefix(1))))])
        let (session, http, _, effects) = try await setup([first], trainer: "trainer-two", connection: connection, observer: observer, clock: .init(now: { clock.now() }))
        await session.bootstrap()
        let path = "/v1/battles/\(final.battleId)"
        await http.route(path, try JSONEncoder().encode(changed(first, ["state": "VOID"])))
        await http.suspendNext(path)
        var altered = final.journal[0]
        altered = .init(roundSeq: 1, p1: altered.p1, p2: altered.p2, releasedAt: altered.releasedAt + 1)
        let incoming = Task { try await self.notify(observer, connection, room: final, fields: ["type": "battle_round", "pair": JSONSerialization.jsonObject(with: JSONEncoder().encode(altered))]) }
        await http.waitUntilBlocked()
        try await notify(observer, connection, room: final, fields: ["type": "battle_changed", "state": "VOID", "revision": first.revision])
        XCTAssertEqual(effects.state.onlineBattleHolds.count, 1)
        await http.resume(try response(first)); try await incoming.value
        let reads = await http.count(path); XCTAssertEqual(reads, 2)
        XCTAssertEqual(session.presentation.room?.state, .void)
        XCTAssertTrue(effects.state.onlineBattleHolds.isEmpty); XCTAssertEqual(effects.applications, 0)
    }
    func testSecondPlayerWaitsTwoSecondsBeforeFallbackAdvance() async throws {
        let final = try battle(), clock = SessionClock()
        let first = try changed(final, ["state": "RUNNING", "result": NSNull(), "roundSeq": 1,
            "journal": JSONSerialization.jsonObject(with: JSONEncoder().encode(Array(final.journal.prefix(1))))])
        let opened = try changed(first, ["roundSeq": 2, "deadline": 63000])
        let (session, http, _, _) = try await setup([first], trainer: "trainer-two",
            clock: .init(now: { clock.now() }))
        let path = "/v1/battles/\(final.battleId)/advance"
        await http.route(path, try JSONEncoder().encode(opened))
        await session.bootstrap()
        var count = await http.count(path); XCTAssertEqual(count, 0)
        clock.advance(1.99); await session.tick()
        count = await http.count(path); XCTAssertEqual(count, 0)
        clock.advance(0.01); await session.tick()
        count = await http.count(path); XCTAssertEqual(count, 1)
        XCTAssertEqual(session.presentation.room?.roundSeq, 2)
        await session.tick(); count = await http.count(path); XCTAssertEqual(count, 1)
    }
    func testAutomaticBattleAdvancesWhileHiddenReportsAndAppliesP2Result() async throws {
        let final = try battle(1), clock = SessionClock()
        let first = try changed(final, ["state": "RUNNING", "result": NSNull(), "roundSeq": 1, "journal": JSONSerialization.jsonObject(with: JSONEncoder().encode(Array(final.journal.prefix(1))))])
        let (session, http, _, effects) = try await setup([first], trainer: "trainer-two", rosterOverride: roster(final), clock: .init(now: { clock.now() }))
        let steps = try (2...final.journal.count).map { count in try response(changed(final, ["state": "RUNNING", "result": NSNull(), "roundSeq": count, "journal": JSONSerialization.jsonObject(with: JSONEncoder().encode(Array(final.journal.prefix(count))))])) }
        await http.queue("/v1/battles/\(final.battleId)/advance", steps)
        await http.route("/v1/battles/\(final.battleId)/report", try JSONEncoder().encode(final))
        await session.perform(.setPopoverVisible(false)); await session.bootstrap()
        for _ in 1..<final.journal.count { clock.advance(2); await session.tick() }
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
        XCTAssertNil(session.presentation.result, "It ended while the app was off, so it waits in the history")
        await session.perform(.openBattle(room.battleId))
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
        await session.bootstrap(); await session.perform(.openBattle(final.battleId)); await session.perform(.prepareBattle(final.battleId))
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
        for (action, name, trainer, state) in [(OnlineBattleUIAction.accept(final.battleId), "accept", "trainer-two", "PENDING"), (.confirm(final.battleId), "confirm", "trainer-one", "ACCEPTED"), (.decline(final.battleId), "decline", "trainer-two", "PENDING"), (.cancel(final.battleId), "cancel", "trainer-one", "PENDING")] {
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
        let count = await http.count("/v1/battles/\(final.battleId)"); XCTAssertEqual(count, 1)
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
        await session.bootstrap(); await session.perform(.prepareBattle(final.battleId))
        await http.route("/v1/battles", try JSONEncoder().encode(OnlineBattlePage(battles: [ready], before: nil)))
        await session.refresh()
        let starts = await http.count("/v1/battles/\(final.battleId)/start"); XCTAssertEqual(starts, 1)
        XCTAssertEqual(session.presentation.room?.state, .running)
    }
    func testPreparedBattleIDsFollowTheReadyGestureAndTheRevision() async throws {
        let final = try battle()
        let accepted = try changed(final, ["state": "ACCEPTED", "config": NSNull(), "result": NSNull(), "confirmed": true, "roundSeq": 0, "journal": []])
        let (session, http, _, _) = try await setup([accepted])
        await http.route("/v1/battles/\(final.battleId)/ready", try JSONEncoder().encode(accepted))
        await session.bootstrap()
        XCTAssertEqual(session.preparedBattleIDs(), [], "Nothing is ready before the gesture")
        await session.perform(.prepareBattle(final.battleId))
        XCTAssertEqual(session.preparedBattleIDs(), [final.battleId], "Ready for the revision on screen")
        let bumped = try changed(final, ["state": "ACCEPTED", "config": NSNull(), "result": NSNull(), "confirmed": true, "roundSeq": 0, "journal": [],
                                         "revision": accepted.revision + 5])
        await http.route("/v1/battles", try JSONEncoder().encode(OnlineBattlePage(battles: [bumped], before: nil)))
        await session.refresh()
        XCTAssertEqual(session.preparedBattleIDs(), [], "A newer revision has to be readied again")
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
        await session.bootstrap(); await session.perform(.prepareBattle(final.battleId))
        let starts = await http.count("/v1/battles/\(final.battleId)/start"); XCTAssertEqual(starts, 0)
        XCTAssertFalse(session.presentation.canStart)
    }
    func testLocalReadyIsExposedOnlyAfterTheServerAcceptedMyReadyCall() async throws {
        let final = try battle()
        let accepted = try changed(final, ["state": "ACCEPTED", "config": NSNull(), "result": NSNull(), "confirmed": true, "roundSeq": 0, "journal": []])
        let (session, http, _, _) = try await setup([accepted])
        let path = "/v1/battles/\(final.battleId)/ready"
        await http.route(path, Data(), status: 500)
        await session.bootstrap()
        XCTAssertFalse(session.presentation.localReady)
        await session.perform(.prepareBattle(final.battleId))
        XCTAssertFalse(session.presentation.localReady, "A failed ready call must not read as received")
        XCTAssertTrue(session.presentation.canPrepare, "The button must stay usable so the person can retry")
        await http.route(path, try JSONEncoder().encode(accepted))
        await session.perform(.prepareBattle(final.battleId))
        XCTAssertTrue(session.presentation.localReady)
        XCTAssertFalse(session.presentation.canPrepare)
        XCTAssertEqual(session.presentation.roomProgress?.turn, .theirs)
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
        await session.bootstrap(); await session.perform(.prepareBattle(final.battleId))
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
        await http.queue("/v1/battles/\(running.battleId)", [.init(status: 503, body: Data())])
        await session.tick(); clock.advance(5); await session.tick()
        let reads = await http.count("/v1/battles/\(running.battleId)"); XCTAssertEqual(reads, 2)
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

    func testSecondJournalMismatchAfterFreshReplayCannotRefetchAgain() async throws {
        let final = try battle()
        let gap = try changed(final, ["state": "RUNNING", "result": NSNull(), "roundSeq": 1, "journal": JSONSerialization.jsonObject(with: JSONEncoder().encode([final.journal[1]]))])
        let fresh = try changed(final, ["state": "RUNNING", "result": NSNull(), "roundSeq": 1, "journal": JSONSerialization.jsonObject(with: JSONEncoder().encode(Array(final.journal.prefix(1))))])
        var altered = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fresh.journal)) as! [[String: Any]]
        altered[0]["p1"] = ["kind": "move", "slot": 1]
        let mismatch = try changed(fresh, ["journal": altered, "roundSeq": final.roundSeq])
        let (session, http, _, effects) = try await setup([gap])
        await http.queue("/v1/battles/\(final.battleId)", [try response(fresh), .init(status: 503, body: Data())])
        await http.route("/v1/battles/\(final.battleId)/advance", try JSONEncoder().encode(mismatch))
        await session.bootstrap()
        let reads = await http.count("/v1/battles/\(final.battleId)"); XCTAssertEqual(reads, 1)
        let advances = await http.count("/v1/battles/\(final.battleId)/advance"); XCTAssertEqual(advances, 1)
        XCTAssertEqual(effects.applications, 0)
        XCTAssertNil(session.presentation.result)
        XCTAssertNotNil(session.presentation.notice)
    }

    func testAuthoritativeShorterValidJournalReplacesRejectedGapAndContinues() async throws {
        let final = try battle()
        let gap = try changed(final, ["state": "RUNNING", "result": NSNull(), "journal": JSONSerialization.jsonObject(with: JSONEncoder().encode(Array(final.journal.dropFirst())))])
        let fresh = try changed(final, ["state": "RUNNING", "result": NSNull(), "roundSeq": 1, "journal": JSONSerialization.jsonObject(with: JSONEncoder().encode(Array(final.journal.prefix(1))))])
        let terminal = try changed(final, ["state": "RUNNING", "result": NSNull()])
        let (session, http, _, effects) = try await setup([gap])
        await http.route("/v1/battles/\(final.battleId)", try JSONEncoder().encode(fresh))
        await http.route("/v1/battles/\(final.battleId)/advance", try JSONEncoder().encode(terminal))
        await http.route("/v1/battles/\(final.battleId)/report", try JSONEncoder().encode(final))
        await session.bootstrap()
        XCTAssertEqual(session.presentation.room?.state, .completed)
        XCTAssertEqual(effects.applications, 1)
        XCTAssertNil(session.presentation.notice)
        let reads = await http.count("/v1/battles/\(final.battleId)"); XCTAssertEqual(reads, 1)
    }

    func testAuthoritativeRefetchCannotReplaceConcurrentCompletedResult() async throws {
        let final = try battle()
        let running = try changed(final, ["state": "RUNNING", "result": NSNull(), "roundSeq": 1, "journal": []])
        let gap = try changed(final, ["state": "RUNNING", "result": NSNull(), "journal": JSONSerialization.jsonObject(with: JSONEncoder().encode(Array(final.journal.dropFirst())))])
        let (session, http, _, effects) = try await setup([running])
        await http.route("/v1/battles/\(final.battleId)/choices", try JSONEncoder().encode(gap))
        await http.suspendNext("/v1/battles/\(final.battleId)")
        await session.bootstrap()
        let choice = Task { await session.perform(.chooseMove(1)) }; await http.waitUntilBlocked()
        await http.route("/v1/battles", try JSONEncoder().encode(OnlineBattlePage(battles: [final], before: nil)))
        await session.refresh()
        await http.resume(try response(running)); await choice.value
        XCTAssertEqual(session.presentation.room?.state, .completed)
        XCTAssertEqual(session.presentation.result?.title, "승리")
        XCTAssertEqual(effects.applications, 1)
        XCTAssertTrue(effects.state.onlineBattleHolds.isEmpty)
        XCTAssertNil(session.presentation.notice)
    }

    func testGrantSurvivesServerRevokingOldWebSocketBeforeReturningNewCredentials() async throws {
        for (action, path) in [(OnlineBattleUIAction.recover(code: "recovery"), "/v1/recover"), (.reconnect(code: "reconnect"), "/v1/reconnect")] {
            let connection = SessionConnection(), observer = SessionObserver()
            let (session, http, credentials, _) = try await setup(connection: connection, observer: observer)
            await http.queue("/v1/me", [.init(status: 503, body: Data())])
            await session.bootstrap()
            XCTAssertEqual(session.presentation.phase, .setup)
            XCTAssertFalse(session.presentation.isBusy, "failed initial read leaves the live-WS recovery UI available")
            let oldObserver = try XCTUnwrap(observer.callback)
            await http.suspendNext(path)
            let recovery = Task { await session.perform(action) }; await http.waitUntilBlocked()
            await connection.setState(.revoked)
            await oldObserver(.changed(await connection.snapshot()))
            await connection.setState(.connected)
            let grant = try JSONSerialization.data(withJSONObject: ["trainer": JSONSerialization.jsonObject(with: JSONEncoder().encode(account.trainer)), "group": JSONSerialization.jsonObject(with: JSONEncoder().encode(account.group)), "accessKey": "rotated-key", "recoveryCode": "rotated-code"])
            await http.resume(.init(status: 200, body: grant)); await recovery.value
            XCTAssertEqual(session.presentation.account, account)
            XCTAssertEqual(session.presentation.recoveryCode, "rotated-code")
            XCTAssertNil(session.presentation.notice)
            let saved = await credentials.key; XCTAssertEqual(saved, "rotated-key")
            let requests = await http.count(path); XCTAssertEqual(requests, 1, "one-use recovery must never be replayed")
        }
    }

    func testBackToLobbyBeforeChoiceResponseCannotBeOverriddenByLateActionSelection() async throws {
        let final = try battle()
        let running = try changed(final, ["state": "RUNNING", "result": NSNull(), "roundSeq": 1, "journal": []])
        let terminal = try changed(final, ["state": "RUNNING", "result": NSNull()])
        let (session, http, _, effects) = try await setup([running])
        await http.suspendNext("/v1/battles/\(final.battleId)/choices")
        await http.route("/v1/battles/\(final.battleId)/report", try JSONEncoder().encode(final))
        await session.bootstrap()
        let choice = Task { await session.perform(.chooseMove(1)) }; await http.waitUntilBlocked()
        await session.perform(.backToLobby)
        await http.resume(try response(terminal)); await choice.value
        XCTAssertEqual(effects.applications, 1)
        XCTAssertEqual(session.presentation.phase, .lobby)
        XCTAssertNil(session.presentation.room)
        XCTAssertNil(session.presentation.result)
    }

    // MARK: Server error notices (T01)
    private func errorBody(_ code: String) -> Data { Data("{\"error\":{\"code\":\"\(code)\"}}".utf8) }
    private func joinNotice(code: String, status: Int, retryAfter: Int? = nil) async throws -> String {
        let credentials = SessionCredentials(); await credentials.setKey(nil)
        let (session, http, _, _) = try await setup(credential: credentials)
        await http.queue("/v1/join", [.init(status: status, body: errorBody(code), retryAfter: retryAfter)])
        await session.bootstrap(); await session.perform(.join(inviteCode: "invite", email: "synthetic"))
        return try XCTUnwrap(session.presentation.notice, code)
    }
    func testJoinFailuresShowDistinctCauseSpecificNotices() async throws {
        let generic = try await joinNotice(code: "internal", status: 500)
        var notices: [String: String] = [:]
        for (code, status) in [("invite_revoked", 410), ("invite_expired", 410), ("invite_used_up", 410), ("display_email_taken", 409)] {
            notices[code] = try await joinNotice(code: code, status: status)
        }
        notices["too_many_attempts"] = try await joinNotice(code: "too_many_attempts", status: 429, retryAfter: 30)
        XCTAssertEqual(Set(notices.values).count, 5, "each cause needs its own sentence: \(notices)")
        for (code, notice) in notices { XCTAssertNotEqual(notice, generic, code) }
        XCTAssertTrue(notices["too_many_attempts"]?.contains("30") == true)
        // version_mismatch is a confirmed server code, but the plan keeps it on the generic sentence.
        let version = try await joinNotice(code: "version_mismatch", status: 409)
        XCTAssertEqual(version, generic)
    }
    func testNextActionClearsPreviousErrorNoticeBeforeItsRequestFinishes() async throws {
        let credentials = SessionCredentials(); await credentials.setKey(nil)
        let (session, http, _, _) = try await setup(credential: credentials)
        await http.queue("/v1/join", [.init(status: 410, body: errorBody("invite_expired"))])
        await session.bootstrap(); await session.perform(.join(inviteCode: "invite", email: "synthetic"))
        XCTAssertNotNil(session.presentation.notice)
        await http.suspendNext("POST /v1/join")
        let second = Task { await session.perform(.join(inviteCode: "invite", email: "synthetic")) }
        await http.waitUntilBlocked()
        XCTAssertNil(session.presentation.notice)
        await http.resume(.init(status: 410, body: errorBody("invite_revoked")))
        await second.value
        XCTAssertNotNil(session.presentation.notice)
    }
    func testAcceptOnRoomThePeerAlreadyCancelledOrLetExpireExplainsWhy() async throws {
        let pending = try changed(battle(), ["state": "PENDING", "config": NSNull(), "result": NSNull(), "roundSeq": 0, "journal": []])
        var notices: [String: String] = [:]
        for state in ["CANCELLED", "EXPIRED"] {
            let (session, http, _, _) = try await setup([pending], trainer: "trainer-two")
            await session.bootstrap()
            XCTAssertEqual(session.presentation.room?.state, .pending)
            let gone = try changed(pending, ["state": state])
            await http.route("/v1/battles", try JSONEncoder().encode(OnlineBattlePage(battles: [gone], before: nil)))
            await session.perform(.accept(pending.battleId))
            let accepts = await http.count("/v1/battles/\(pending.battleId)/accept")
            XCTAssertEqual(accepts, 0, state)
            notices[state] = session.presentation.notice ?? "<nil>"
        }
        XCTAssertNotEqual(notices["CANCELLED"], notices["EXPIRED"])
        XCTAssertTrue(notices["CANCELLED"]?.contains("취소") == true, "\(notices)")
        XCTAssertTrue(notices["EXPIRED"]?.contains("시간이 지났") == true, "\(notices)")
        for value in notices.values { XCTAssertFalse(value.contains("출전 정보가 바뀌")) }
    }
    func testAcceptRejectedByServerAfterPeerCancelledRereadsAndExplains() async throws {
        let pending = try changed(battle(), ["state": "PENDING", "config": NSNull(), "result": NSNull(), "roundSeq": 0, "journal": []])
        let gone = try changed(pending, ["state": "CANCELLED"])
        let (session, http, _, _) = try await setup([pending], trainer: "trainer-two")
        await session.bootstrap()
        let page = { (room: OnlineBattleView) throws -> OnlineBattleHTTPResponse in .init(status: 200, body: try JSONEncoder().encode(OnlineBattlePage(battles: [room], before: nil))) }
        // perform(.accept) first refreshes (still pending), the accept POST is refused, the re-read shows cancelled.
        await http.queue("/v1/battles", [try page(pending), try page(gone)])
        await http.queue("POST /v1/battles/\(pending.battleId)/accept", [.init(status: 409, body: errorBody("invalid_state"))])
        await session.perform(.accept(pending.battleId))
        let accepts = await http.count("/v1/battles/\(pending.battleId)/accept")
        XCTAssertEqual(accepts, 1)
        XCTAssertTrue(session.presentation.notice?.contains("취소") == true, session.presentation.notice ?? "<nil>")
    }
    // MARK: T07 ended-challenge notices
    private func namedOpponent(_ http: SessionHTTP, trainer: String) async throws {
        let other = trainer == "trainer-one" ? "trainer-two" : "trainer-one"
        let member = OnlineBattleMember(trainerId: other, displayEmail: "하늘", role: .member, status: .active, joinedAt: 0, online: true)
        await http.route("/v1/group", try JSONEncoder().encode(OnlineBattleGroupMembers(group: account.group, members: [member])))
    }
    private func pendingRoom() throws -> OnlineBattleView {
        try changed(battle(), ["state": "PENDING", "config": NSNull(), "result": NSNull(), "confirmed": false, "roundSeq": 0, "journal": []])
    }
    func testPeerDeclineCancelAndExpiryEachShowADistinctNamedNoticeAndReturnToTheLobby() async throws {
        var notices: [String: String] = [:]
        for (state, trainer, part) in [("DECLINED", "trainer-one", "거절"), ("CANCELLED", "trainer-one", "취소"), ("CANCELLED", "trainer-two", "취소"), ("EXPIRED", "trainer-one", "시간이 지났"), ("EXPIRED", "trainer-two", "시간이 지났")] {
            let pending = try pendingRoom()
            let (session, http, _, _) = try await setup([pending], trainer: trainer)
            try await namedOpponent(http, trainer: trainer)
            await session.bootstrap()
            XCTAssertEqual(session.presentation.phase, .room, state)
            XCTAssertNil(session.presentation.notice)
            await http.route("/v1/battles", try JSONEncoder().encode(OnlineBattlePage(battles: [try changed(pending, ["state": state, "revision": pending.revision + 1])], before: nil)))
            await session.refresh()
            XCTAssertEqual(session.presentation.phase, .lobby, "\(state) \(trainer)")
            let notice = try XCTUnwrap(session.presentation.notice, "\(state) \(trainer)")
            XCTAssertTrue(notice.contains("하늘") && notice.contains(part), notice)
            notices[state + trainer] = notice
        }
        XCTAssertEqual(Set(notices.values).count, 3, "\(notices)")
    }
    func testLeavingTheGroupCancelsWithAReasonThatIsNotThePeerCancelling() async throws {
        let pending = try pendingRoom()
        let (session, http, _, _) = try await setup([pending]); try await namedOpponent(http, trainer: "trainer-one")
        await session.bootstrap()
        await http.route("/v1/battles", try JSONEncoder().encode(OnlineBattlePage(battles: [try changed(pending, ["state": "CANCELLED", "revision": pending.revision + 1, "reason": "participant_left"])], before: nil)))
        await session.refresh()
        let notice = try XCTUnwrap(session.presentation.notice)
        XCTAssertTrue(notice.contains("하늘") && notice.contains("떠나"), notice)
    }
    func testMyOwnCancelAndDeclineDoNotAnnounceThemselvesBack() async throws {
        for (action, name, trainer, state) in [(OnlineBattleUIAction.cancel(try pendingRoom().battleId), "cancel", "trainer-one", "CANCELLED"), (.decline(try pendingRoom().battleId), "decline", "trainer-two", "DECLINED")] {
            let pending = try pendingRoom()
            let (session, http, _, _) = try await setup([pending], trainer: trainer); try await namedOpponent(http, trainer: trainer)
            await http.route("/v1/battles/\(pending.battleId)/\(name)", try JSONEncoder().encode(try changed(pending, ["state": state, "revision": pending.revision + 1])))
            await session.bootstrap(); await session.perform(.openBattle(pending.battleId)); await session.perform(action)
            XCTAssertEqual(session.presentation.phase, .lobby, name)
            XCTAssertNil(session.presentation.notice, name)
            // The same ending arriving again through a refresh is still not news.
            await http.route("/v1/battles", try JSONEncoder().encode(OnlineBattlePage(battles: [try changed(pending, ["state": state, "revision": pending.revision + 1])], before: nil)))
            await session.refresh()
            XCTAssertNil(session.presentation.notice, name)
        }
    }
    func testEndedNoticeSurvivesRefreshesUntilClosedAndIsNotRepeated() async throws {
        let pending = try pendingRoom()
        let (session, http, _, _) = try await setup([pending]); try await namedOpponent(http, trainer: "trainer-one")
        await session.bootstrap()
        await http.route("/v1/battles", try JSONEncoder().encode(OnlineBattlePage(battles: [try changed(pending, ["state": "DECLINED", "revision": pending.revision + 1])], before: nil)))
        await session.refresh()
        let first = try XCTUnwrap(session.presentation.notice)
        await session.refresh(); await session.refresh()
        XCTAssertEqual(session.presentation.notice, first, "A background refresh must not wipe an unread notice")
        session.presentation.send(.dismissNotice)
        XCTAssertNil(session.presentation.notice)
        await session.refresh()
        XCTAssertNil(session.presentation.notice, "Announced once")
    }
    func testAcceptRaceAgainstAPeerCancelKeepsTheNamedNoticeThroughARefresh() async throws {
        let pending = try pendingRoom()
        let gone = try changed(pending, ["state": "CANCELLED", "revision": pending.revision + 1])
        let (session, http, _, _) = try await setup([pending], trainer: "trainer-two"); try await namedOpponent(http, trainer: "trainer-two")
        await session.bootstrap()
        let page = { (room: OnlineBattleView) throws -> OnlineBattleHTTPResponse in .init(status: 200, body: try JSONEncoder().encode(OnlineBattlePage(battles: [room], before: nil))) }
        await http.queue("/v1/battles", [try page(pending), try page(gone)])
        await http.queue("POST /v1/battles/\(pending.battleId)/accept", [.init(status: 409, body: errorBody("invalid_state"))])
        await session.perform(.accept(pending.battleId))
        let notice = try XCTUnwrap(session.presentation.notice)
        XCTAssertTrue(notice.contains("하늘") && notice.contains("취소"), notice)
        await session.refresh()
        XCTAssertEqual(session.presentation.notice, notice, "The generic fallback must not replace the named notice, and a refresh must not wipe it")
    }
    func testEndingsAlreadyInHistoryAtLaunchDoNotRaiseNotices() async throws {
        let rooms = try ["DECLINED", "CANCELLED", "EXPIRED"].enumerated().map { index, state in
            try changed(battle(), ["state": state, "config": NSNull(), "result": NSNull(), "journal": [], "roundSeq": 0, "battleId": "bt_old\(index)"])
        }
        let (session, http, _, _) = try await setup(rooms); try await namedOpponent(http, trainer: "trainer-one")
        await session.bootstrap()
        XCTAssertNil(session.presentation.notice)
    }
    func testErrorNoticesFollowTheAppLanguage() async throws {
        let credentials = SessionCredentials(); await credentials.setKey(nil)
        let http = SessionHTTP(), room = try battle()
        await http.route("/v1/me", try JSONEncoder().encode(account))
        await http.route("/v1/join", errorBody("invite_expired"), status: 410)
        let session = OnlineBattleSession(settings: .init(profileID: UUID().uuidString, serverURL: "https://battle.example.invalid"), credentials: credentials, transport: http, effects: SessionEffects(), engineFactory: { try BattleEngine(url: self.engineURL) }, connectionFactory: { _ in SessionConnection() }, rosterProvider: { self.roster(room) }, automaticTicks: false, localization: { L(.en) })
        await session.bootstrap(); await session.perform(.join(inviteCode: "invite", email: "synthetic"))
        let notice = try XCTUnwrap(session.presentation.notice)
        XCTAssertTrue(notice.contains("expired"), notice)
        XCTAssertNil(notice.range(of: "[가-힣]", options: .regularExpression), notice)
    }
    // MARK: Review A F1.1: the server binds ready to one connection
    private func confirmedRoom() throws -> OnlineBattleView {
        try changed(battle(), ["state": "ACCEPTED", "config": NSNull(), "result": NSNull(), "confirmed": true, "roundSeq": 0, "journal": []])
    }
    private func sentConnectionIDs(_ http: SessionHTTP, _ id: String, action: String = "ready") async throws -> [String?] {
        try await http.bodies("/v1/battles/\(id)/\(action)").map { body in
            let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            return object?["connectionId"] as? String
        }
    }
    /// The socket drops and comes back with a new id, in the order the real connection reports it.
    private func reconnect(_ connection: SessionConnection, observer: SessionObserver, id: String) async {
        await connection.setConnection(.retryWaiting, id: nil)
        await observer.callback?(.changed(await connection.snapshot()))
        await connection.setConnection(.connected, id: id)
        await observer.callback?(.changed(await connection.snapshot()))
    }
    func testReconnectAfterReadySendsItAgainSoTheRoomCanStillStart() async throws {
        let final = try battle(), accepted = try confirmedRoom()
        let ready = try changed(final, ["state": "READY", "result": NSNull(), "roundSeq": 0, "journal": []])
        let running = try changed(final, ["state": "RUNNING", "result": NSNull(), "roundSeq": 1, "journal": []])
        let connection = SessionConnection(), observer = SessionObserver()
        let (session, http, _, _) = try await setup([accepted], connection: connection, observer: observer)
        await http.route("/v1/battles/\(final.battleId)/ready", try JSONEncoder().encode(accepted))
        await http.route("/v1/battles/\(final.battleId)/start", try JSONEncoder().encode(running))
        await session.bootstrap(); await session.perform(.prepareBattle(final.battleId))
        XCTAssertTrue(session.presentation.localReady)
        await reconnect(connection, observer: observer, id: "connection-b")
        XCTAssertFalse(session.presentation.localReady, "The server no longer holds a ready from the old socket")
        // The opponent readied meanwhile, so the server stays ACCEPTED until this side answers on its new socket.
        await http.route("/v1/battles/\(final.battleId)/ready", try JSONEncoder().encode(ready))
        await session.refresh()
        let readies = try await sentConnectionIDs(http, final.battleId)
        XCTAssertEqual(readies, ["connection", "connection-b"])
        let starts = try await sentConnectionIDs(http, final.battleId, action: "start")
        XCTAssertEqual(starts, ["connection-b"])
        XCTAssertEqual(session.presentation.phase, .arena)
    }
    func testReconnectResendLeavesThePersonReadyOnTheNewConnectionWithoutRepeating() async throws {
        let accepted = try confirmedRoom()
        let connection = SessionConnection(), observer = SessionObserver()
        let (session, http, _, _) = try await setup([accepted], connection: connection, observer: observer)
        await http.route("/v1/battles/\(accepted.battleId)/ready", try JSONEncoder().encode(accepted))
        await session.bootstrap(); await session.perform(.prepareBattle(accepted.battleId))
        await reconnect(connection, observer: observer, id: "connection-b")
        await session.refresh(); await session.refresh()
        let readies = try await sentConnectionIDs(http, accepted.battleId)
        XCTAssertEqual(readies, ["connection", "connection-b"], "One gesture is sent once per connection")
        XCTAssertTrue(session.presentation.localReady)
        XCTAssertFalse(session.presentation.canPrepare)
        XCTAssertEqual(session.preparedBattleIDs(), [accepted.battleId])
    }
    func testResendThatTheServerRefusesGivesTheButtonAndTheMarkBack() async throws {
        let accepted = try confirmedRoom()
        let connection = SessionConnection(), observer = SessionObserver()
        let (session, http, _, _) = try await setup([accepted], connection: connection, observer: observer)
        await http.route("/v1/battles/\(accepted.battleId)/ready", try JSONEncoder().encode(accepted))
        await session.bootstrap(); await session.perform(.prepareBattle(accepted.battleId))
        await reconnect(connection, observer: observer, id: "connection-b")
        await http.route("/v1/battles/\(accepted.battleId)/ready", errorBody("not_ready"), status: 409)
        await session.refresh()
        XCTAssertFalse(session.presentation.localReady)
        XCTAssertTrue(session.presentation.canPrepare, "The person has to be able to press it again")
        XCTAssertEqual(session.preparedBattleIDs(), [], "The mark asks for the press again")
        XCTAssertEqual(session.presentation.phase, .room)
    }
    func testResendSkipsWhenTheEntryChangedAndLeavesTheChoiceToThePerson() async throws {
        let accepted = try confirmedRoom()
        let connection = SessionConnection(), observer = SessionObserver()
        let (session, http, _, effects) = try await setup([accepted], connection: connection, observer: observer)
        await http.route("/v1/battles/\(accepted.battleId)/ready", try JSONEncoder().encode(accepted))
        await session.bootstrap(); await session.perform(.prepareBattle(accepted.battleId))
        effects.setHealthShare(0.5, of: "instance-one")
        await reconnect(connection, observer: observer, id: "connection-b")
        await session.refresh()
        let readies = try await sentConnectionIDs(http, accepted.battleId)
        XCTAssertEqual(readies, ["connection"], "A changed entry must not be readied on the person's behalf")
        XCTAssertFalse(session.presentation.localReady)
        XCTAssertEqual(session.preparedBattleIDs(), [])
    }
    func testReadyPendingOnADroppedSocketStaysQuietOnTheMarkButNotOnTheButton() async throws {
        let accepted = try confirmedRoom()
        let connection = SessionConnection(), observer = SessionObserver()
        let (session, http, _, _) = try await setup([accepted], connection: connection, observer: observer)
        await http.route("/v1/battles/\(accepted.battleId)/ready", try JSONEncoder().encode(accepted))
        await session.bootstrap(); await session.perform(.prepareBattle(accepted.battleId))
        await connection.setConnection(.retryWaiting, id: nil)
        await observer.callback?(.changed(await connection.snapshot()))
        XCTAssertEqual(session.preparedBattleIDs(), [accepted.battleId], "A socket blip is no reason to notify; the press is sent again on hello")
        XCTAssertFalse(session.presentation.localReady)
        XCTAssertEqual(session.presentation.prepareBlock, .connecting)
    }
    func testFailedReadAfterReconnectCannotPromiseTheResendAnyMore() async throws {
        let accepted = try confirmedRoom()
        let connection = SessionConnection(), observer = SessionObserver()
        let (session, http, _, _) = try await setup([accepted], connection: connection, observer: observer)
        await http.route("/v1/battles/\(accepted.battleId)/ready", try JSONEncoder().encode(accepted))
        await session.bootstrap(); await session.perform(.prepareBattle(accepted.battleId))
        await reconnect(connection, observer: observer, id: "connection-b")
        await http.route("/v1/battles", Data(), status: 503)
        await session.refresh()
        XCTAssertEqual(session.preparedBattleIDs(), [], "Nothing will send it now, so the mark asks for the press")
        XCTAssertTrue(session.presentation.canPrepare)
    }
    func testReadyRoomReconnectStartsOnTheNewConnectionAndKeepsTheFlag() async throws {
        let final = try battle(), ready = try changed(final, ["state": "READY", "result": NSNull(), "roundSeq": 0, "journal": []])
        let connection = SessionConnection(), observer = SessionObserver()
        let (session, http, _, _) = try await setup([ready], connection: connection, observer: observer)
        await http.route("/v1/battles/\(final.battleId)/start", try JSONEncoder().encode(ready))
        await session.bootstrap(); await session.perform(.prepareBattle(final.battleId))
        XCTAssertTrue(session.presentation.localReady)
        await reconnect(connection, observer: observer, id: "connection-b")
        await session.refresh()
        let starts = try await sentConnectionIDs(http, final.battleId, action: "start")
        XCTAssertEqual(starts, ["connection", "connection-b"])
        XCTAssertTrue(session.presentation.localReady)
    }
    func testRefusedStartDoesNotReadAsReady() async throws {
        let final = try battle(), ready = try changed(final, ["state": "READY", "result": NSNull(), "roundSeq": 0, "journal": []])
        let (session, http, _, _) = try await setup([ready])
        await http.route("/v1/battles/\(final.battleId)/start", Data(), status: 503)
        await session.bootstrap(); await session.perform(.prepareBattle(final.battleId))
        XCTAssertFalse(session.presentation.localReady, "A failed start must not read as received")
        XCTAssertTrue(session.presentation.canPrepare, "Nothing else would retry it on this screen")
    }
    // MARK: Review A F1.2: a room action belongs to the room on screen
    private func pendingRoom(_ id: String, newerBy: Double = 0) throws -> OnlineBattleView {
        let base = try pendingRoom()
        return try changed(base, ["battleId": id, "createdAt": base.createdAt + newerBy])
    }
    private func list(_ http: SessionHTTP, _ rooms: [OnlineBattleView]) async throws {
        await http.route("/v1/battles", try JSONEncoder().encode(OnlineBattlePage(battles: rooms, before: nil)))
    }
    func testAcceptNeverMovesToTheNextRoomWhenTheOneOnScreenWasCancelled() async throws {
        let older = try pendingRoom("bt_older"), shown = try pendingRoom("bt_shown", newerBy: 60_000)
        let (session, http, _, _) = try await setup([older, shown], trainer: "trainer-two")
        for room in [older, shown] {
            await http.route("/v1/battles/\(room.battleId)/accept", try JSONEncoder().encode(changed(room, ["state": "ACCEPTED"])))
        }
        await session.bootstrap()
        session.presentation.selectedEntryID = "instance-two"
        XCTAssertEqual(session.presentation.room?.battleId, shown.battleId)
        try await list(http, [older, try changed(shown, ["state": "CANCELLED"])])
        await session.perform(.accept(shown.battleId))
        let accepts = await http.requests.filter { $0.url?.path.hasSuffix("/accept") == true }.count
        XCTAssertEqual(accepts, 0, "Agreeing to a match must not reach a room the person was not looking at")
        XCTAssertNotEqual(session.presentation.room?.battleId, older.battleId)
        XCTAssertEqual(session.presentation.phase, .lobby)
        XCTAssertTrue(session.presentation.notice?.contains("취소") == true, session.presentation.notice ?? "<nil>")
    }
    func testNewChallengeDoesNotPushAsideTheRoomOnScreen() async throws {
        let shown = try pendingRoom("bt_shown"), newer = try pendingRoom("bt_newer", newerBy: 60_000)
        let (session, http, _, _) = try await setup([shown], trainer: "trainer-two")
        await session.bootstrap()
        XCTAssertEqual(session.presentation.room?.battleId, shown.battleId)
        try await list(http, [shown, newer])
        await session.refresh()
        XCTAssertEqual(session.presentation.room?.battleId, shown.battleId)
        XCTAssertEqual(Set(session.presentation.battles.map(\.battleId)), [shown.battleId, newer.battleId], "The new one waits in the list")
    }
    func testActionNamingAnotherRoomIsNotSent() async throws {
        let shown = try confirmedRoom()
        let other = try changed(shown, ["battleId": "bt_other"])
        for action in [OnlineBattleUIAction.accept(other.battleId), .confirm(other.battleId), .prepareBattle(other.battleId), .decline(other.battleId), .cancel(other.battleId)] {
            let (session, http, _, _) = try await setup([shown, other])
            await session.bootstrap(); await session.perform(.openBattle(shown.battleId))
            let before = await http.requests.filter { $0.httpMethod == "POST" }.count
            await session.perform(action)
            let after = await http.requests.filter { $0.httpMethod == "POST" }.count
            XCTAssertEqual(after, before, "\(action)")
        }
    }
    func testEndedRoomOnScreenLeavesToTheLobbyInsteadOfOpeningTheNextOne() async throws {
        let older = try pendingRoom("bt_older"), shown = try pendingRoom("bt_shown", newerBy: 60_000)
        let (session, http, _, _) = try await setup([older, shown], trainer: "trainer-two")
        await session.bootstrap()
        try await list(http, [older, try changed(shown, ["state": "CANCELLED"])])
        await session.refresh()
        XCTAssertEqual(session.presentation.phase, .lobby, "The next request must not appear where the last one's buttons were")
        await session.perform(.openBattle(older.battleId))
        XCTAssertEqual(session.presentation.room?.battleId, older.battleId)
        XCTAssertEqual(session.presentation.phase, .room)
    }
    func testMatchInPlayStillTakesTheScreenFromAWaitingRoom() async throws {
        let shown = try pendingRoom("bt_shown")
        let (session, http, _, _) = try await setup([shown], trainer: "trainer-two")
        await session.bootstrap()
        XCTAssertEqual(session.presentation.room?.battleId, shown.battleId)
        let running = try changed(battle(), ["state": "RUNNING", "result": NSNull(), "roundSeq": 1, "journal": []])
        try await list(http, [shown, running])
        await session.refresh()
        XCTAssertEqual(session.presentation.room?.battleId, running.battleId)
        XCTAssertEqual(session.presentation.phase, .arena)
    }
    func testFinishedMatchOnScreenKeepsItsResultWhenAnotherMatchIsInPlay() async throws {
        let final = try battle()
        let shown = try changed(final, ["state": "RUNNING", "result": NSNull(), "roundSeq": 1, "journal": []])
        let (session, http, _, _) = try await setup([shown])
        await session.bootstrap()
        XCTAssertEqual(session.presentation.room?.battleId, final.battleId)
        let other = try changed(shown, ["battleId": "bt_other", "createdAt": shown.createdAt + 60_000])
        try await list(http, [final, other])
        await session.refresh()
        XCTAssertEqual(session.presentation.room?.battleId, final.battleId)
        XCTAssertEqual(session.presentation.phase, .result)
    }
    // MARK: Review A F1.3: only a match watched this run, or one opened on purpose, shows a result by itself
    private func attention(_ session: OnlineBattleSession) -> OnlineAttentionKind? {
        OnlineAttentionCalculator.current(.init(presentation: session.presentation, preparedBattleIDs: session.preparedBattleIDs(),
                                                stagingHeldBattleIDs: session.stagingHeldBattleIDs(), now: Date(timeIntervalSince1970: 1)))?.kind
    }
    func testRelaunchDoesNotRaiseAResultThatEndedBeforeThisRun() async throws {
        let void = try changed(battle(1), ["state": "VOID", "result": NSNull(), "battleId": "bt_void"])
        for rooms in [[try battle()], [void]] {
            let (session, _, _, _) = try await setup(rooms)
            await session.bootstrap()
            XCTAssertNil(session.presentation.room)
            XCTAssertNil(session.presentation.result)
            XCTAssertEqual(session.presentation.phase, .lobby)
            XCTAssertNil(attention(session), "Nothing new happened since the person last looked")
            XCTAssertEqual(session.presentation.historyBattles.map(\.battleId), rooms.map(\.battleId), "It stays reachable from the lobby")
        }
    }
    func testMatchWatchedThisRunEndsOnItsResultWithTheMark() async throws {
        let final = try battle()
        let running = try changed(final, ["state": "RUNNING", "result": NSNull(), "roundSeq": 1, "journal": []])
        let (session, http, _, _) = try await setup([running])
        await session.bootstrap()
        XCTAssertEqual(session.presentation.phase, .arena)
        try await list(http, [final])
        await session.refresh()
        XCTAssertEqual(session.presentation.phase, .result)
        XCTAssertEqual(session.presentation.result?.title, "승리")
        XCTAssertEqual(attention(session), .resultReady)
    }
    func testMatchThatEndsInsideTheFirstReadStillEndsOnItsResult() async throws {
        let final = try battle()
        let reported = try changed(final, ["state": "REPORTED"])
        let (session, http, _, _) = try await setup([reported])
        await http.route("/v1/battles/\(final.battleId)/report", try JSONEncoder().encode(final))
        await session.bootstrap()
        XCTAssertEqual(session.presentation.room?.state, .completed)
        XCTAssertEqual(session.presentation.phase, .result, "It was still being played when this run first read it")
    }
    func testClosedResultDoesNotComeBackOnTheNextRead() async throws {
        let final = try battle()
        let running = try changed(final, ["state": "RUNNING", "result": NSNull(), "roundSeq": 1, "journal": []])
        let (session, http, _, _) = try await setup([running])
        await session.bootstrap()
        try await list(http, [final])
        await session.refresh()
        XCTAssertEqual(session.presentation.phase, .result)
        await session.perform(.dismissResult); await session.refresh()
        XCTAssertEqual(session.presentation.phase, .lobby)
        XCTAssertNil(session.presentation.room)
        XCTAssertNil(attention(session))
    }
    // MARK: Review A F1.4: a failed read is not a changed entry
    private let copy = L(.ko)
    private func roomActionCases() throws -> [(OnlineBattleUIAction, String, String, OnlineBattleView)] {
        let pending = try pendingRoom(), confirmed = try confirmedRoom()
        let unconfirmed = try changed(confirmed, ["confirmed": false])
        return [(.confirm(unconfirmed.battleId), "confirm", "trainer-one", unconfirmed),
                (.prepareBattle(confirmed.battleId), "ready", "trainer-one", confirmed),
                (.decline(pending.battleId), "decline", "trainer-two", pending),
                (.cancel(pending.battleId), "cancel", "trainer-one", pending)]
    }
    func testChallengeAfterAFailedReadSaysConnectionNotEntry() async throws {
        let (session, http, _, _) = try await setup()
        await session.bootstrap()
        session.presentation.selectedEntryID = "instance-one"; session.presentation.selectedOpponentID = "trainer-two"
        await http.route("/v1/battles", Data(), status: 503)
        await session.perform(.challenge)
        XCTAssertEqual(session.presentation.notice, copy.onlineErrorGeneric)
        let posts = await http.requests.filter { $0.httpMethod == "POST" }.count
        XCTAssertEqual(posts, 0)
    }
    func testRoomActionAfterAFailedBackgroundReadReadsAgainAndGoesThrough() async throws {
        for (action, path, trainer, room) in try roomActionCases() {
            let (session, http, _, _) = try await setup([room], trainer: trainer)
            await http.route("/v1/battles/\(room.battleId)/\(path)", try JSONEncoder().encode(room))
            await session.bootstrap()
            let good = OnlineBattleHTTPResponse(status: 200, body: try JSONEncoder().encode(OnlineBattlePage(battles: [room], before: nil)))
            await http.queue("/v1/battles", [.init(status: 503, body: Data()), good])
            await session.refresh()
            XCTAssertEqual(session.presentation.notice, copy.onlineErrorGeneric, path)
            await session.perform(action)
            let sent = await http.count("/v1/battles/\(room.battleId)/\(path)")
            XCTAssertEqual(sent, 1, "One failed background read must not silently block \(path)")
            XCTAssertNil(session.presentation.notice, path)
        }
    }
    func testRoomActionWhoseReadFailsAgainSendsNothingAndSaysConnection() async throws {
        for (action, path, trainer, room) in try roomActionCases() {
            let (session, http, _, _) = try await setup([room], trainer: trainer)
            await http.route("/v1/battles/\(room.battleId)/\(path)", try JSONEncoder().encode(room))
            await session.bootstrap()
            await http.route("/v1/battles", Data(), status: 503)
            await session.refresh(); await session.perform(action)
            let sent = await http.count("/v1/battles/\(room.battleId)/\(path)")
            XCTAssertEqual(sent, 0, path)
            XCTAssertEqual(session.presentation.notice, copy.onlineErrorGeneric, path)
        }
    }
    func testActionAfterAReadThatFailedForAnotherReasonKeepsThatReason() async throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(battle())) as? [String: Any])
        var result = object["result"] as! [String: Any]; result["logHash"] = "tampered"; object["result"] = result
        let tampered = try JSONDecoder().decode(OnlineBattleView.self, from: JSONSerialization.data(withJSONObject: object))
        let (session, _, _, _) = try await setup([tampered])
        await session.bootstrap()
        session.presentation.selectedEntryID = "instance-one"; session.presentation.selectedOpponentID = "trainer-two"
        await session.perform(.challenge)
        XCTAssertEqual(session.presentation.notice, copy.onlineErrorResultUnverified)
    }
    func testAccountRevokedDuringTheReadShowsNoExtraNotice() async throws {
        let room = try pendingRoom()
        let (session, http, _, _) = try await setup([room])
        await session.bootstrap()
        await http.route("/v1/me", Data(), status: 401)
        await session.perform(.accept(room.battleId))
        XCTAssertEqual(session.presentation.phase, .setup)
        XCTAssertNil(session.presentation.notice)
    }
    func testRealEntryChangeStillSaysEntryChanged() async throws {
        let room = try changed(confirmedRoom(), ["confirmed": false])
        let (session, http, _, effects) = try await setup([room])
        await session.bootstrap()
        effects.setHealthShare(0.5, of: "instance-one")
        await session.perform(.confirm(room.battleId))
        XCTAssertEqual(session.presentation.notice, copy.onlineErrorEntryChanged)
        let sent = await http.count("/v1/battles/\(room.battleId)/confirm")
        XCTAssertEqual(sent, 0)
    }
    func testActionTheRoomNoLongerAllowsSaysTheRoomMovedOnNotEntry() async throws {
        let room = try confirmedRoom()
        let (session, http, _, _) = try await setup([room])
        await session.bootstrap()
        await session.perform(.decline(room.battleId)) // Only the receiver of a pending room can decline.
        XCTAssertEqual(session.presentation.notice, copy.onlineErrorRoomChanged)
        let posts = await http.requests.filter { $0.httpMethod == "POST" }.count
        XCTAssertEqual(posts, 0)
    }
}
