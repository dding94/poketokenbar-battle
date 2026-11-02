import XCTest
@testable import PokeTokenBar

private final class OnlineTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double = 0
    func now() -> Double { lock.withLock { value } }
    func advance(_ seconds: Double) { lock.withLock { value += seconds } }
    var clock: OnlineBattleConnectionClock { .init(now: { self.now() }, sleep: { _ in throw CancellationError() }) }
}
private actor OnlineTestSocket: OnlineBattleSocket {
    nonisolated let events: AsyncStream<OnlineBattleSocketEvent>
    nonisolated let continuation: AsyncStream<OnlineBattleSocketEvent>.Continuation
    init() { let stream = AsyncStream<OnlineBattleSocketEvent>.makeStream(); events = stream.stream; continuation = stream.continuation }
    var pings = 0
    var closes = 0
    var failPing = false
    func setFailPing() { failPing = true }
    func sendPing() throws { pings += 1; if failPing { throw OnlineBattleFailure.transport } }
    func close() { closes += 1; continuation.finish() }
}
private actor OnlineTestSocketDriver: OnlineBattleSocketDriver {
    var requests: [URLRequest] = []
    var sockets: [OnlineTestSocket] = []
    func connect(_ request: URLRequest) -> any OnlineBattleSocket {
        requests.append(request)
        let socket = OnlineTestSocket(); sockets.append(socket); return socket
    }
}
private actor OnlineConnectionEvents {
    var events: [OnlineBattleConnectionEvent] = []
    func append(_ value: OnlineBattleConnectionEvent) { events.append(value) }
    var refreshCount: Int { events.filter { if case .refreshRequested = $0 { return true }; return false }.count }
}
private actor OnlineHeldSocketDriver: OnlineBattleSocketDriver {
    var pending: CheckedContinuation<any OnlineBattleSocket, Error>?
    var waiting: CheckedContinuation<Void, Never>?
    func connect(_ request: URLRequest) async throws -> any OnlineBattleSocket {
        try await withCheckedThrowingContinuation { pending = $0; waiting?.resume(); waiting = nil }
    }
    func waitUntilStarted() async { if pending != nil { return }; await withCheckedContinuation { waiting = $0 } }
    func finish(_ socket: any OnlineBattleSocket) { pending?.resume(returning: socket); pending = nil }
}
private struct OnlineFailingSocketDriver: OnlineBattleSocketDriver {
    let failure: OnlineBattleFailure
    func connect(_ request: URLRequest) async throws -> any OnlineBattleSocket { throw failure }
}
private actor OnlineSleepGate {
    var continuation: CheckedContinuation<Void, Error>?
    var waiting: CheckedContinuation<Void, Never>?
    var closed = false
    func sleep() async throws {
        if closed { throw CancellationError() }
        try await withCheckedThrowingContinuation { continuation = $0; waiting?.resume(); waiting = nil }
    }
    func waitUntilSleeping() async { if continuation != nil { return }; await withCheckedContinuation { waiting = $0 } }
    func release() { continuation?.resume(); continuation = nil }
    func close() { closed = true; continuation?.resume(throwing: CancellationError()); continuation = nil }
}
@MainActor
final class OnlineBattleConnectionTests: XCTestCase {
    private let hello = #"{"v":1,"type":"hello","trainerId":"synthetic-trainer","groupId":"synthetic-group","connectionId":"synthetic-connection","online":[]}"#
    private func setup() async throws -> (OnlineBattleConnection, OnlineTestClock, OnlineTestSocketDriver, OnlineConnectionEvents) {
        let clock = OnlineTestClock(), driver = OnlineTestSocketDriver(), events = OnlineConnectionEvents()
        let connection = OnlineBattleConnection(driver: driver, clock: clock.clock, jitter: { $0 }, automaticTicks: false, observer: { await events.append($0) })
        await connection.configure(origin: try OnlineBattleOrigin("https://example.invalid"), accessKey: "synthetic-key")
        return (connection, clock, driver, events)
    }
    private func send(_ value: OnlineBattleSocketEvent, to connection: OnlineBattleConnection) async {
        let snapshot = await connection.snapshot()
        await connection.receive(value, generation: snapshot.generation)
    }
    func testUnauthorizedUpgradeTakesPrecedenceOverAbnormalTransportClose() {
        XCTAssertEqual(OnlineBattleSocketEvent.receiveFailure(httpStatus: 401, closeCode: 1006), .failed(401))
        XCTAssertEqual(OnlineBattleSocketEvent.receiveFailure(httpStatus: nil, closeCode: 4003), .closed(4003))
        XCTAssertEqual(OnlineBattleSocketEvent.receiveFailure(httpStatus: 503, closeCode: 0), .failed(503))
    }
    func testSocketHeaderHelloPongAndThirtySecondPing() async throws {
        let (connection, clock, driver, _) = try await setup()
        let request = await driver.requests[0]
        XCTAssertEqual(request.url?.absoluteString, "wss://example.invalid/v1/connect")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-key")
        await send(.text("pong"), to: connection)
        var state = await connection.snapshot(); XCTAssertEqual(state.state, .connecting)
        await send(.text(hello), to: connection)
        state = await connection.snapshot(); XCTAssertEqual(state.state, .connected); XCTAssertEqual(state.connectionId, "synthetic-connection")
        clock.advance(29); await connection.tick()
        let socket = await driver.sockets[0]
        var count = await socket.pings; XCTAssertEqual(count, 0)
        clock.advance(1); await connection.tick()
        count = await socket.pings; XCTAssertEqual(count, 1)
        await send(.text("pong"), to: connection)
        state = await connection.snapshot(); XCTAssertEqual(state.state, .connected)
        await connection.stop()
    }
    func testHelloDeadlineAndThreeFailuresEnterPolling() async throws {
        let (connection, clock, driver, _) = try await setup()
        for retry in 0..<3 {
            clock.advance(15); await connection.tick()
            let state = await connection.snapshot()
            XCTAssertEqual(state.state, retry == 2 ? .polling : .retryWaiting)
            if retry < 2 { clock.advance(pow(2, Double(retry))); await connection.tick() }
        }
        let requests = await driver.requests; XCTAssertEqual(requests.count, 3)
        await connection.stop()
    }
    func testPollingIsPopoverOnlyAndWebSocketRetriesAfterTenMinutes() async throws {
        let (connection, clock, driver, events) = try await setup()
        for retry in 0..<3 {
            await send(.failed(nil), to: connection)
            if retry < 2 { clock.advance(pow(2, Double(retry))); await connection.tick() }
        }
        clock.advance(30); await connection.tick()
        var count = await events.refreshCount; XCTAssertEqual(count, 0)
        await connection.setPopoverOpen(true)
        count = await events.refreshCount; XCTAssertEqual(count, 1)
        clock.advance(30); await connection.tick()
        count = await events.refreshCount; XCTAssertEqual(count, 2)
        await connection.setPopoverOpen(false)
        clock.advance(30); await connection.tick()
        count = await events.refreshCount; XCTAssertEqual(count, 2)
        clock.advance(510); await connection.tick()
        let state = await connection.snapshot(); XCTAssertEqual(state.state, .connecting)
        let requests = await driver.requests; XCTAssertEqual(requests.count, 4)
        await connection.stop()
    }
    func testReplacedOnlyRetriesOnNextPopoverOpening() async throws {
        let (connection, clock, driver, _) = try await setup()
        await connection.setPopoverOpen(true)
        await send(.closed(4001), to: connection)
        clock.advance(1_000); await connection.tick(); await connection.setPopoverOpen(true)
        var requests = await driver.requests; XCTAssertEqual(requests.count, 1)
        await connection.setPopoverOpen(false); await connection.setPopoverOpen(true)
        requests = await driver.requests; XCTAssertEqual(requests.count, 2)
        await connection.stop()
    }
    func testRevokedAndProtocolCloseStopAllAutomaticRequests() async throws {
        for (event, expected) in [(OnlineBattleSocketEvent.closed(4003), OnlineBattleConnectionState.revoked), (.failed(401), .revoked), (.closed(4400), .protocolError)] {
            let (connection, clock, driver, _) = try await setup()
            await send(event, to: connection)
            clock.advance(10_000); await connection.tick(); await connection.setPopoverOpen(true)
            let state = await connection.snapshot(); XCTAssertEqual(state.state, expected)
            let requests = await driver.requests; XCTAssertEqual(requests.count, 1)
            await connection.stop()
        }
    }
    func testStaleCallbacksCannotRevokeNewConnection() async throws {
        let (connection, _, _, _) = try await setup()
        let old = await connection.snapshot()
        await connection.configure(origin: try OnlineBattleOrigin("https://example.invalid"), accessKey: "synthetic-new")
        await connection.receive(.closed(4003), generation: old.generation)
        await connection.authenticationFailed(generation: old.generation)
        await connection.receive(.text(hello), generation: old.generation)
        let state = await connection.snapshot(); XCTAssertEqual(state.state, .connecting); XCTAssertNil(state.connectionId)
        await connection.stop()
    }
    func testUnsupportedProtocolOrMissingHelloIdentityStops() async throws {
        for text in [#"{"v":2,"type":"hello"}"#, #"{"v":1,"type":"hello","online":[]}"#, #"{"v":1,"type":"mystery"}"#, "not-json"] {
            let (connection, _, _, _) = try await setup()
            await send(.text(text), to: connection)
            let state = await connection.snapshot(); XCTAssertEqual(state.state, .protocolError)
            await connection.stop()
        }
    }
    func testStableConnectionResetsExponentialBackoff() async throws {
        let (connection, clock, driver, _) = try await setup()
        await send(.failed(nil), to: connection); clock.advance(1); await connection.tick()
        await send(.text(hello), to: connection)
        clock.advance(60); await send(.closed(1006), to: connection)
        clock.advance(1); await connection.tick()
        let requests = await driver.requests; XCTAssertEqual(requests.count, 3)
        await connection.stop()
    }
    func testPresenceAndBattleNotificationsOnlyRequestRefresh() async throws {
        let (connection, _, _, events) = try await setup()
        await send(.text(hello), to: connection)
        for text in [#"{"v":1,"type":"presence","trainerId":"synthetic-other","online":true}"#, #"{"v":1,"type":"battle_changed","battleId":"bt_synthetic"}"#, #"{"v":1,"type":"battle_round","battleId":"bt_synthetic"}"#, #"{"v":1,"type":"group_changed","kind":"join"}"#] { await send(.text(text), to: connection) }
        let count = await events.refreshCount; XCTAssertEqual(count, 5)
        await connection.stop()
    }
    func testGroupVoidNotificationRefreshesWithoutStoppingProtocol() async throws {
        let (connection, _, _, events) = try await setup()
        await send(.text(hello), to: connection)
        await send(.text(#"{"v":1,"type":"battle_void","battleId":"bt_synthetic","reason":"result_mismatch"}"#), to: connection)
        let state = await connection.snapshot(); XCTAssertEqual(state.state, .connected)
        let count = await events.refreshCount; XCTAssertEqual(count, 2)
        await connection.stop()
    }
    func testDriverStreamActuallyDeliversHelloToConnection() async throws {
        let received = expectation(description: "driver hello consumed")
        let driver = OnlineTestSocketDriver()
        let connection = OnlineBattleConnection(driver: driver, automaticTicks: false) { event in
            if case .changed(let snapshot) = event, snapshot.state == .connected { received.fulfill() }
        }
        await connection.configure(origin: try OnlineBattleOrigin("https://example.invalid"), accessKey: "synthetic")
        let socket = await driver.sockets[0]
        socket.continuation.yield(.text(hello))
        await fulfillment(of: [received], timeout: 2)
        let state = await connection.snapshot(); XCTAssertEqual(state.connectionId, "synthetic-connection")
        await connection.stop()
    }
    func testLoopbackFixtureUsesWSWithoutMakingUserHTTPAllowed() async throws {
        let driver = OnlineTestSocketDriver(), connection = OnlineBattleConnection(driver: driver, automaticTicks: false)
        await connection.configure(origin: try OnlineBattleOrigin(testLoopbackURL: URL(string: "http://127.0.0.1:8787")!), accessKey: "synthetic")
        let request = await driver.requests[0]
        XCTAssertEqual(request.url?.absoluteString, "ws://127.0.0.1:8787/v1/connect")
        await connection.stop()
    }
    func testShortConnectionsBackOffToSixtySecondCap() async throws {
        let (connection, clock, driver, _) = try await setup()
        for attempt in 0..<9 {
            await send(.text(hello), to: connection)
            await send(.closed(1006), to: connection)
            let delay = min(60, pow(2, Double(attempt)))
            clock.advance(delay - 0.1); await connection.tick()
            var state = await connection.snapshot(); XCTAssertEqual(state.state, .retryWaiting)
            clock.advance(0.1); await connection.tick()
            state = await connection.snapshot(); XCTAssertEqual(state.state, .connecting)
        }
        let requests = await driver.requests; XCTAssertEqual(requests.count, 10)
        await connection.stop()
    }
    func testLateSocketCreationClosesOldSocketWithoutChangingNewConfiguration() async throws {
        let driver = OnlineHeldSocketDriver(), connection = OnlineBattleConnection(driver: driver, automaticTicks: false)
        let origin = try OnlineBattleOrigin("https://example.invalid")
        let old = Task { await connection.configure(origin: origin, accessKey: "synthetic-old") }
        await driver.waitUntilStarted()
        await connection.configure(origin: nil, accessKey: nil)
        let socket = OnlineTestSocket(); await driver.finish(socket); await old.value
        let state = await connection.snapshot(); XCTAssertEqual(state.state, .unconfigured)
        let closes = await socket.closes; XCTAssertEqual(closes, 1)
        await connection.stop()
    }
    func testDriverFailureAndCurrentHTTPAuthenticationFailureClassifyCorrectly() async throws {
        for failure in [OnlineBattleFailure.unauthorized, .transport] {
            let connection = OnlineBattleConnection(driver: OnlineFailingSocketDriver(failure: failure), automaticTicks: false)
            await connection.configure(origin: try OnlineBattleOrigin("https://example.invalid"), accessKey: "synthetic")
            let state = await connection.snapshot(); XCTAssertEqual(state.state, failure == .unauthorized ? .revoked : .retryWaiting)
            await connection.stop()
        }
        let (connection, _, _, _) = try await setup()
        let current = await connection.snapshot()
        await connection.authenticationFailed(generation: current.generation)
        let state = await connection.snapshot(); XCTAssertEqual(state.state, .revoked)
        await connection.stop()
    }
    func testFailedPingRetriesAndOpenPopoverStartsPollingImmediately() async throws {
        let (connection, clock, driver, events) = try await setup()
        await send(.text(hello), to: connection)
        let socket = await driver.sockets[0]; await socket.setFailPing()
        clock.advance(60); await connection.tick()
        var state = await connection.snapshot(); XCTAssertEqual(state.state, .retryWaiting)
        await connection.setPopoverOpen(true)
        for retry in 0..<3 {
            clock.advance(pow(2, Double(retry))); await connection.tick()
            await send(.failed(nil), to: connection)
        }
        state = await connection.snapshot(); XCTAssertEqual(state.state, .polling)
        let count = await events.refreshCount; XCTAssertEqual(count, 2)
        await connection.stop()
    }
    func testAutomaticSchedulerUsesInjectedSleepAndStopsWithoutRealWaiting() async throws {
        let gate = OnlineSleepGate(), clock = OnlineTestClock(), driver = OnlineTestSocketDriver()
        let timedOut = expectation(description: "injected timer fires")
        let connection = OnlineBattleConnection(driver: driver, clock: .init(now: { clock.now() }, sleep: { _ in try await gate.sleep() }), jitter: { $0 }, observer: { event in
            if case .changed(let snapshot) = event, snapshot.state == .retryWaiting { timedOut.fulfill() }
        })
        await connection.configure(origin: try OnlineBattleOrigin("https://example.invalid"), accessKey: "synthetic")
        await gate.waitUntilSleeping(); clock.advance(15); await gate.release()
        await fulfillment(of: [timedOut], timeout: 2)
        await connection.stop(); await gate.close()
    }
    func testMissingConfigurationAndKeyNeverOpenSocket() async throws {
        let driver = OnlineTestSocketDriver(), connection = OnlineBattleConnection(driver: driver, automaticTicks: false)
        await connection.configure(origin: nil, accessKey: nil)
        var state = await connection.snapshot(); XCTAssertEqual(state.state, .unconfigured)
        await connection.configure(origin: try OnlineBattleOrigin("https://example.invalid"), accessKey: nil)
        state = await connection.snapshot(); XCTAssertEqual(state.state, .credentialsRequired)
        let requests = await driver.requests; XCTAssertTrue(requests.isEmpty)
        await connection.stop()
    }
}
