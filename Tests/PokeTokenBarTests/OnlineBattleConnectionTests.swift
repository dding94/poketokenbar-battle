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
    nonisolated let events: AsyncStream<OnlineBattleSocketEvent> = AsyncStream { _ in }
    var pings = 0
    var closes = 0
    func sendPing() { pings += 1 }
    func close() { closes += 1 }
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
