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
