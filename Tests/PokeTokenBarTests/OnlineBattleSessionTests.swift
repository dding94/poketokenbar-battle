import XCTest
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
    func route(_ path: String, _ data: Data, status: Int = 200) { routes[path] = .init(status: status, body: data) }
    func send(_ request: URLRequest) async throws -> OnlineBattleHTTPResponse {
        requests.append(request)
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
    private func battle() throws -> OnlineBattleView {
        try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "golden", withExtension: "json", subdirectory: "OnlineBattle"))))[0].battle
    }
    private func roster(_ battle: OnlineBattleView) -> [PracticeCandidate] {
        [battle.p1.snapshot!, battle.p2.snapshot!].map { value in
            .init(id: value.instanceId, name: value.publicInfo.species, snapshot: .init(schemaVersion: 1, instanceID: value.instanceId, engineHash: BattleEngineManifest.sha256, rulesVersion: BattleSnapshot.rules, policyVersion: BattleSnapshot.policy, set: value.set, publicInfo: value.publicInfo), blockedReason: nil)
        }
    }
    private func setup(_ battles: [OnlineBattleView] = [], credential: SessionCredentials = .init(), effects: SessionEffects = .init()) async throws -> (OnlineBattleSession, SessionHTTP, SessionCredentials, SessionEffects) {
        let http = SessionHTTP(), connection = SessionConnection(), room = try battle()
        await http.route("/v1/me", try JSONEncoder().encode(account))
        await http.route("/v1/group", try JSONEncoder().encode(OnlineBattleGroupMembers(group: account.group, members: [])))
        await http.route("/v1/battles", try JSONEncoder().encode(OnlineBattlePage(battles: battles, before: nil)))
        let session = OnlineBattleSession(settings: .init(profileID: UUID().uuidString, serverURL: "https://battle.example.invalid"), credentials: credential, transport: http, effects: effects, engineFactory: { try BattleEngine(url: self.engineURL) }, connectionFactory: { _ in connection }, rosterProvider: { self.roster(room) }, automaticTicks: false)
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
}
