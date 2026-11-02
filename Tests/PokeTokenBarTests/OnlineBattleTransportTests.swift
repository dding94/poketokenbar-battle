import XCTest
@testable import PokeTokenBar

final class OnlineBattleTransportTests: XCTestCase {
    func testOriginRejectsCredentialAndPathLeaks() throws {
        do {
        for value in ["http://example.invalid", "https://person:secret@example.invalid", "https://example.invalid/path", "https://example.invalid?key=secret", "https://example.invalid#secret"] {
            XCTAssertThrowsError(try OnlineBattleOrigin(value))
        }
        } catch { XCTFail("Expected successful fixture operation; received \(error)") }
    }
    func testExplicitLoopbackOriginAllowsOnlyHTTPOnLoopback() throws {
        do {
        let origin = try OnlineBattleOrigin(testLoopbackURL: URL(string: "http://127.0.0.1:8787")!)
        XCTAssertEqual(origin.url.absoluteString, "http://127.0.0.1:8787")
        for url in ["http://example.invalid:8787", "http://127.0.0.1:8787/path", "http://user:secret@127.0.0.1:8787", "http://127.0.0.1:8787?key=secret"] {
            XCTAssertThrowsError(try OnlineBattleOrigin(testLoopbackURL: URL(string: url)!))
        }
        XCTAssertThrowsError(try OnlineBattleOrigin("http://127.0.0.1:8787"))
        } catch { XCTFail("Expected successful fixture operation; received \(error)") }
    }
    func testOriginCanonicalizesDefaultPortAndCase() throws {
        do {
        XCTAssertEqual(try OnlineBattleOrigin("HTTPS://EXAMPLE.INVALID:443/").url.absoluteString, "https://example.invalid")
        } catch { XCTFail("Expected successful fixture operation; received \(error)") }
    }
}

private actor OnlineHTTPStub: OnlineBattleHTTPTransport {
    var responses: [OnlineBattleHTTPResponse]
    var requests: [URLRequest] = []
    init(_ responses: [OnlineBattleHTTPResponse]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> OnlineBattleHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw URLError(.networkConnectionLost) }
        return responses.removeFirst()
    }
}
private actor OnlineHeldHTTP: OnlineBattleHTTPTransport {
    var pending: CheckedContinuation<OnlineBattleHTTPResponse, Error>?
    var started: CheckedContinuation<Void, Never>?
    func send(_ request: URLRequest) async throws -> OnlineBattleHTTPResponse {
        try await withCheckedThrowingContinuation { pending = $0; started?.resume(); started = nil }
    }
    func waitUntilRequested() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish(status: Int) { pending?.resume(returning: .init(status: status, body: Data("{}".utf8))); pending = nil }
}

@MainActor
final class OnlineBattleAPITests: XCTestCase {
    private let account = #"{"trainer":{"trainerId":"trainer-synthetic","displayEmail":"synthetic@example.invalid","role":"member","status":"active"},"group":{"groupId":"group-synthetic","name":"Synthetic","hostTrainerId":"host-synthetic"}}"#
    private func response(_ text: String, status: Int = 200) -> OnlineBattleHTTPResponse { .init(status: status, body: Data(text.utf8)) }
    private func api(_ transport: any OnlineBattleHTTPTransport) throws -> OnlineBattleAPI { .init(origin: try OnlineBattleOrigin("https://example.invalid"), transport: transport) }
    func testBearerAppearsOnlyInHeaderAndBodyIsConsumed() async throws {
        do {
        let driver = OnlineHTTPStub([response(account)]), api = try api(driver)
        await api.setAccessKey("synthetic-access-key")
        let value = try await api.me()
        XCTAssertEqual(value.trainer.trainerId, "trainer-synthetic")
        let request = await driver.requests[0]
        XCTAssertEqual(request.url?.absoluteString, "https://example.invalid/v1/me")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-access-key")
        XCTAssertNil(request.httpBody)
        } catch { XCTFail("Expected successful fixture operation; received \(error)") }
    }
    func testJoinIsSinglePOSTWithoutBearerAndRedactsGrant() async throws {
        do {
        let grant = String(account.dropLast()) + #", "accessKey":"synthetic-access-key","recoveryCode":"synthetic-recovery"}"#
        let driver = OnlineHTTPStub([response(grant)]), api = try api(driver)
        let value = try await api.join(inviteCode: "synthetic-invite", displayEmail: "synthetic@example.invalid")
        let requests = await driver.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].httpMethod, "POST")
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization"))
        XCTAssertFalse(String(reflecting: value).contains("synthetic-access-key"))
        XCTAssertFalse(String(describing: value).contains("synthetic-recovery"))
        let body = try XCTUnwrap(requests[0].httpBody)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(fields, ["inviteCode":"synthetic-invite", "displayEmail":"synthetic@example.invalid"])
        } catch { XCTFail("Expected successful fixture operation; received \(error)") }
    }
    func testLostOnboardingResponseIsNeverRetried() async throws {
        do {
        let driver = OnlineHTTPStub([]), api = try api(driver)
        do { _ = try await api.join(inviteCode: "synthetic-invite", displayEmail: "synthetic@example.invalid"); XCTFail() }
        catch { XCTAssertEqual(error as? OnlineBattleFailure, .transport) }
        let requests = await driver.requests
        XCTAssertEqual(requests.count, 1)
        } catch { XCTFail("Expected successful fixture operation; received \(error)") }
    }
    func testErrorUsesOnlyFixedCodeAndRetryAfter() async throws {
        do {
        let driver = OnlineHTTPStub([.init(status: 429, body: Data(#"{"error":{"code":"too_many_attempts","secret":"must-not-appear"}}"#.utf8), retryAfter: 60)]), api = try api(driver)
        do { _ = try await api.recover(recoveryCode: "must-not-appear"); XCTFail() }
        catch {
            XCTAssertEqual(error as? OnlineBattleServerError, .init(code: .tooManyAttempts, retryAfter: 60))
            XCTAssertFalse(String(reflecting: error).contains("must-not-appear"))
        }
        } catch { XCTFail("Expected successful fixture operation; received \(error)") }
    }
    func testUnknownErrorAndMalformedSuccessCannotLeakBody() async throws {
        do {
        for (status, body) in [(500, #"{"error":{"code":"secret-unknown"}}"#), (200, "secret-malformed")] {
            let driver = OnlineHTTPStub([response(body, status: status)]), api = try api(driver)
            do { _ = try await api.recover(recoveryCode: "synthetic"); XCTFail() }
            catch { XCTAssertEqual(error as? OnlineBattleFailure, .invalidResponse) }
        }
        } catch { XCTFail("Expected successful fixture operation; received \(error)") }
    }
    func testMissingCredentialStopsBeforeNetwork() async throws {
        do {
        let driver = OnlineHTTPStub([]), api = try api(driver)
        do { _ = try await api.me(); XCTFail() } catch { XCTAssertEqual(error as? OnlineBattleFailure, .unauthorized) }
        let requests = await driver.requests; XCTAssertTrue(requests.isEmpty)
        } catch { XCTFail("Expected successful fixture operation; received \(error)") }
    }
    func testStale401CannotRevokeRotatedCredential() async throws {
        do {
        let driver = OnlineHeldHTTP(), api = try api(driver)
        await api.setAccessKey("synthetic-old")
        let task = Task { try await api.me() }
        await driver.waitUntilRequested()
        await api.setAccessKey("synthetic-new")
        await driver.finish(status: 401)
        do { _ = try await task.value; XCTFail() } catch { XCTAssertEqual(error as? OnlineBattleFailure, .staleGeneration) }
        } catch { XCTFail("Expected successful fixture operation; received \(error)") }
    }
    func testStaleSuccessCannotCrossOrigin() async throws {
        do {
        let driver = OnlineHeldHTTP(), api = try api(driver)
        await api.setAccessKey("synthetic-old")
        let task = Task { try await api.me() }
        await driver.waitUntilRequested()
        await api.setOrigin(try OnlineBattleOrigin("https://other.invalid"))
        await driver.finish(status: 200)
        do { _ = try await task.value; XCTFail() } catch { XCTAssertEqual(error as? OnlineBattleFailure, .staleGeneration) }
        } catch { XCTFail("Expected successful fixture operation; received \(error)") }
    }
    func testBattlePagesReadThroughLastCursor() async throws {
        do {
        let driver = OnlineHTTPStub([response(#"{"battles":[],"before":"200"}"#), response(#"{"battles":[],"before":"100"}"#), response(#"{"battles":[],"before":null}"#)]), api = try api(driver)
        await api.setAccessKey("synthetic")
        let battles = try await api.listBattles()
        XCTAssertTrue(battles.isEmpty)
        let requests = await driver.requests
        XCTAssertEqual(requests.map { $0.url!.query }, [nil, "before=200", "before=100"])
        } catch { XCTFail("Expected successful fixture operation; received \(error)") }
    }
    func testRepeatedCursorStopsLoop() async throws {
        do {
        let page = response(#"{"battles":[],"before":"100"}"#)
        let driver = OnlineHTTPStub([page, page]), api = try api(driver)
        await api.setAccessKey("synthetic")
        do { _ = try await api.listBattles(); XCTFail() } catch { XCTAssertEqual(error as? OnlineBattleFailure, .invalidResponse) }
        } catch { XCTFail("Expected successful fixture operation; received \(error)") }
    }
    func testChoiceAndBattleIDRejectBeforeNetwork() async throws {
        do {
        let driver = OnlineHTTPStub([]), api = try api(driver)
        await api.setAccessKey("synthetic")
        do { _ = try await api.choose(id: "bt_test", roundSeq: 1, slot: 5); XCTFail() } catch { XCTAssertEqual(error as? OnlineBattleFailure, .invalidRequest) }
        do { _ = try await api.battle(id: "bt_x/../../me"); XCTFail() } catch { XCTAssertEqual(error as? OnlineBattleFailure, .invalidRequest) }
        let requests = await driver.requests; XCTAssertTrue(requests.isEmpty)
        } catch { XCTFail("Expected successful fixture operation; received \(error)") }
    }
    func testAllBattleActionsUseExactClosedBodiesAndRoutes() async throws {
        let view = #"{"battleId":"bt_synthetic","state":"PENDING","revision":1,"mode":"manual","p1":{"trainerId":"p1"},"p2":{"trainerId":"p2"},"createdAt":1,"expiresAt":2,"startedAt":null,"reportedAt":null,"confirmed":false,"config":null,"roundSeq":0,"deadline":null,"ownChoice":null,"journal":[],"result":null,"reason":null,"rematchOf":null}"#
        let driver = OnlineHTTPStub(Array(repeating: response(view), count: 13)), api = try api(driver)
        await api.setAccessKey("synthetic")
        let set = BattleSet(speciesNum: 25, form: nil, level: 50, gender: .male, nature: "hardy", ability: "static", moves: ["thunderbolt"], ivs: [:], shiny: false)
        let snapshot = OnlineBattleSnapshot(instanceId: "synthetic-individual", set: set, publicInfo: .init(speciesNum: 25, species: "Pikachu", level: 50, types: ["Electric"], stats: ["hp": 100]), hp: 100)
        _ = try await api.battle(id: "bt_synthetic")
        _ = try await api.createBattle(requestId: "synthetic-request", targetTrainerId: "p2", mode: .manual, snapshot: snapshot)
        _ = try await api.update(id: "bt_synthetic", revision: 1, snapshot: snapshot)
        _ = try await api.accept(id: "bt_synthetic", revision: 2, snapshot: snapshot)
        _ = try await api.confirm(id: "bt_synthetic", revision: 3)
        _ = try await api.decline(id: "bt_synthetic", revision: 3)
        _ = try await api.cancel(id: "bt_synthetic", revision: 3)
        _ = try await api.ready(id: "bt_synthetic", revision: 3, connectionId: "synthetic-connection", engineHash: "synthetic-hash", rulesVersion: "rules", policyVersion: "policy")
        _ = try await api.start(id: "bt_synthetic", revision: 3, connectionId: "synthetic-connection", readyToken: "synthetic-ready", engineHash: "synthetic-hash")
        _ = try await api.choose(id: "bt_synthetic", roundSeq: 1, slot: 2)
        _ = try await api.advance(id: "bt_synthetic", processedRoundSeq: 1)
        _ = try await api.report(id: "bt_synthetic", report: .init(readyToken: "synthetic-ready", engineHash: "synthetic-hash", terminalSeq: 1, winner: .p1, logHash: "log", journalHash: "journal", finalHp: .init(p1: 50, p2: 0)))
        _ = try await api.rematch(id: "bt_synthetic", requestId: "synthetic-rematch", snapshot: snapshot)
        let requests = await driver.requests
        XCTAssertEqual(requests.count, 13)
        XCTAssertEqual(requests.map { $0.url!.path }, ["/v1/battles/bt_synthetic", "/v1/battles"] + ["update", "accept", "confirm", "decline", "cancel", "ready", "start", "choices", "advance", "report", "rematch"].map { "/v1/battles/bt_synthetic/" + $0 })
        let expectedKeys = [["mode", "requestId", "snapshot", "targetTrainerId"], ["revision", "snapshot"], ["revision", "snapshot"], ["revision"], ["revision"], ["revision"], ["connectionId", "engineHash", "policyVersion", "revision", "rulesVersion"], ["connectionId", "engineHash", "readyToken", "revision"], ["choice", "roundSeq"], ["processedRoundSeq"], ["engineHash", "finalHp", "journalHash", "logHash", "readyToken", "terminalSeq", "winner"], ["requestId", "snapshot"]]
        for (request, keys) in zip(requests.dropFirst(), expectedKeys) {
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertEqual(body.keys.sorted(), keys)
        }
        let choice = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests[9].httpBody)) as? [String: Any])
        XCTAssertEqual(choice["choice"] as? String, "move 2")
    }
    func testRecoveryAndReconnectNeverAutomaticallyRetry() async throws {
        let driver = OnlineHTTPStub([]), api = try api(driver)
        for reconnect in [false, true] {
            do {
                if reconnect { _ = try await api.reconnect(reconnectCode: "synthetic", displayEmail: "synthetic@example.invalid") }
                else { _ = try await api.recover(recoveryCode: "synthetic") }
                XCTFail()
            } catch { XCTAssertEqual(error as? OnlineBattleFailure, .transport) }
        }
        let requests = await driver.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.map { $0.url!.path }, ["/v1/recover", "/v1/reconnect"])
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
    }
    func testGroupAdministrationRoutesDecodeTheirActualServerEnvelopes() async throws {
        let group = #"{"groupId":"group-synthetic","name":"Synthetic","hostTrainerId":"host-synthetic"}"#
        let invite = #"{"inviteId":"invite-synthetic","createdAt":1,"expiresAt":2,"maxUses":30,"uses":0,"revoked":false,"revokedAt":null}"#
        let driver = OnlineHTTPStub([
            response("{\"group\":" + group + ",\"members\":[]}"), response(#"{"entries":[]}"#), response("{\"invites\":[" + invite + "]}"),
            response("{\"invite\":" + invite + ",\"inviteCode\":\"synthetic-code\"}"), response("{\"invite\":" + invite + "}"),
            response(#"{"trainerId":"synthetic-other","reconnectCode":"synthetic-code","expiresAt":2}"#), response(#"{"ok":true,"revokedInvites":3}"#), response("{\"group\":" + group + "}"), response(#"{"ok":true}"#)
        ]), api = try api(driver)
        await api.setAccessKey("synthetic")
        let members = try await api.group(); XCTAssertTrue(members.members.isEmpty)
        let audit = try await api.audit(); XCTAssertTrue(audit.entries.isEmpty)
        let invites = try await api.invites(); XCTAssertEqual(invites.invites.count, 1)
        let issued = try await api.createInvite(ttlSeconds: 3600, maxUses: 1); XCTAssertFalse(String(reflecting: issued).contains("synthetic-code"))
        _ = try await api.revokeInvite(inviteId: "invite-synthetic")
        let code = try await api.issueReconnectCode(trainerId: "synthetic-other"); XCTAssertFalse(String(reflecting: code).contains("synthetic-code"))
        let revoked = try await api.removeMember(trainerId: "synthetic-other"); XCTAssertEqual(revoked, 3)
        let transfer = try await api.transferHost(trainerId: "synthetic-other"); XCTAssertEqual(transfer.groupId, "group-synthetic")
        try await api.leave()
        let requests = await driver.requests
        XCTAssertEqual(requests.map { $0.url!.path }, ["/v1/group", "/v1/audit", "/v1/invites", "/v1/invites", "/v1/invites/revoke", "/v1/reconnect-codes", "/v1/members/remove", "/v1/host/transfer", "/v1/leave"])
    }
    func testRedirectDelegateNeverFollowsLocation() {
        let transport = OnlineBattleURLSessionTransport()
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: URL(string: "https://example.invalid")!)
        let response = HTTPURLResponse(url: URL(string: "https://example.invalid")!, statusCode: 302, httpVersion: nil, headerFields: ["Location": "https://elsewhere.invalid"])!
        let rejected = expectation(description: "redirect rejected")
        transport.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: URL(string: "https://elsewhere.invalid")!)) { request in
            XCTAssertNil(request); rejected.fulfill()
        }
        wait(for: [rejected], timeout: 1)
        session.invalidateAndCancel()
    }
}
