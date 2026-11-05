import AppKit
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
private final class OnlineLogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ line: String) { lock.withLock { values.append(line) } }
    var lines: [String] { lock.withLock { values } }
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
private final class OnlinePingProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable (Error?) -> Void)?
    private var cancelled = 0
    func send(_ value: @escaping @Sendable (Error?) -> Void) { lock.withLock { callback = value } }
    func complete(_ error: Error?) { let value = lock.withLock { callback }; value?(error) }
    func cancel() { lock.withLock { cancelled += 1 } }
    var cancelCount: Int { lock.withLock { cancelled } }
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
    func testStandingsNotificationKeepsSocketConnectedWithoutRefreshingBattleList() async throws {
        let (connection, _, _, events) = try await setup()
        await send(.text(hello), to: connection)
        await send(.text(#"{"v":1,"type":"standings_changed"}"#), to: connection)
        let state = await connection.snapshot()
        XCTAssertEqual(state.state, .connected)
        let count = await events.refreshCount
        XCTAssertEqual(count, 1)
        await connection.stop()
    }
    func testProtocolPingCompletesOnPongAndPropagatesSocketError() async throws {
        for fails in [false, true] {
            let gate = OnlineSleepGate(), probe = OnlinePingProbe()
            let ping = Task { try await OnlineBattleProtocolPing.wait(sleep: { delay in
                XCTAssertEqual(delay, 15); try await gate.sleep()
            }, send: { probe.send($0) }, cancel: { probe.cancel() }) }
            await gate.waitUntilSleeping()
            probe.complete(fails ? URLError(.networkConnectionLost) : nil)
            do { try await ping.value; XCTAssertFalse(fails) }
            catch { XCTAssertTrue(fails); XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost) }
            probe.complete(nil) // A duplicate/late callback cannot resume twice.
            XCTAssertEqual(probe.cancelCount, 0); await gate.close()
        }
    }
    func testAlreadyCancelledProtocolPingDoesNotSendOrArmTimer() async throws {
        let probe = OnlinePingProbe()
        let ping = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await OnlineBattleProtocolPing.wait(sleep: { _ in XCTFail("Cancelled ping must not arm a timeout") },
                send: { _ in XCTFail("Cancelled ping must not send a frame") }, cancel: { probe.cancel() })
        }
        do { try await ping.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(probe.cancelCount, 1)
    }
    func testProtocolPingTimeoutAndCancellationIgnoreLatePong() async throws {
        for cancel in [false, true] {
            let gate = OnlineSleepGate(), probe = OnlinePingProbe()
            let ping = Task { try await OnlineBattleProtocolPing.wait(sleep: { _ in try await gate.sleep() },
                send: { probe.send($0) }, cancel: { probe.cancel() }) }
            await gate.waitUntilSleeping()
            if cancel { ping.cancel() } else { await gate.release() }
            do { try await ping.value; XCTFail("Ping must terminate when no pong can arrive") }
            catch {
                if cancel { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
            }
            probe.complete(nil)
            XCTAssertEqual(probe.cancelCount, 1); await gate.close()
        }
    }
    func testBattleNotificationsDoNotRequestFullAccountRefresh() async throws {
        let (connection, _, _, events) = try await setup()
        await send(.text(hello), to: connection)
        for payload in [
            #"{"v":1,"type":"battle_round","battleId":"bt_test","pair":{"roundSeq":1,"p1":{"kind":"move","slot":1},"p2":{"kind":"timeout"},"releasedAt":1000}}"#,
            #"{"v":1,"type":"battle_changed","battleId":"bt_test","state":"RUNNING","revision":2,"roundSeq":2,"deadline":31000}"#,
            #"{"v":1,"type":"battle_changed","battleId":"bt_test","state":"RUNNING","revision":2}"#
        ] { await send(.text(payload), to: connection) }
        let reads = await events.refreshCount
        XCTAssertEqual(reads, 1, "Only hello reconciles the entire account; battle notifications stay scoped")
        await connection.stop()
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
    /// Three failed opens in a row, from an attempt in flight. Sixty seconds outlasts any backoff step.
    private func enterPolling(_ connection: OnlineBattleConnection, _ clock: OnlineTestClock) async {
        for retry in 0..<3 {
            await send(.failed(nil), to: connection)
            if retry < 2 { clock.advance(60); await connection.tick() }
        }
    }
    func testAfterThreeFailuresTheSocketIsRetriedEveryTwoMinutesWithNoReadsWhileClosed() async throws {
        let (connection, clock, driver, events) = try await setup()
        await enterPolling(connection, clock)
        var state = await connection.snapshot(); XCTAssertEqual(state.state, .polling)
        clock.advance(30); await connection.tick()
        let reads = await events.refreshCount; XCTAssertEqual(reads, 0, "Nothing is read on a timer while the popover is closed")
        clock.advance(89); await connection.tick()
        state = await connection.snapshot(); XCTAssertEqual(state.state, .polling, "Still 1 second short of two minutes")
        var requests = await driver.requests; XCTAssertEqual(requests.count, 3)
        clock.advance(1); await connection.tick()
        state = await connection.snapshot(); XCTAssertEqual(state.state, .connecting)
        requests = await driver.requests; XCTAssertEqual(requests.count, 4)
        await send(.failed(nil), to: connection)
        state = await connection.snapshot(); XCTAssertEqual(state.state, .retryWaiting, "The retry starts a new round of three")
        await connection.stop()
    }
    func testOpeningThePopoverWhilePollingReadsAndReconnects() async throws {
        let (connection, clock, driver, events) = try await setup()
        await enterPolling(connection, clock)
        await connection.setPopoverOpen(true)
        var reads = await events.refreshCount; XCTAssertEqual(reads, 1)
        var state = await connection.snapshot(); XCTAssertEqual(state.state, .connecting)
        var requests = await driver.requests; XCTAssertEqual(requests.count, 4)
        // The network still blocks the socket: back to polling, with reads only while the popover stays open.
        await enterPolling(connection, clock)
        state = await connection.snapshot(); XCTAssertEqual(state.state, .polling)
        reads = await events.refreshCount; XCTAssertEqual(reads, 2)
        clock.advance(30); await connection.tick()
        reads = await events.refreshCount; XCTAssertEqual(reads, 3)
        await connection.setPopoverOpen(false)
        clock.advance(30); await connection.tick()
        reads = await events.refreshCount; XCTAssertEqual(reads, 3)
        requests = await driver.requests; XCTAssertEqual(requests.count, 6)
        await connection.stop()
    }
    func testAReconnectHintLeavesPollingAtOnceWithFreshCounters() async throws {
        let (connection, clock, driver, events) = try await setup()
        await enterPolling(connection, clock)
        await connection.reconnectHint(.wake)
        var state = await connection.snapshot(); XCTAssertEqual(state.state, .connecting)
        var requests = await driver.requests; XCTAssertEqual(requests.count, 4, "No waiting for the two-minute retry")
        await send(.failed(nil), to: connection)
        state = await connection.snapshot(); XCTAssertEqual(state.state, .retryWaiting, "openFailures went back to 0")
        clock.advance(1); await connection.tick()
        state = await connection.snapshot(); XCTAssertEqual(state.state, .connecting, "attempts went back to 0, so the first backoff step")
        await send(.text(hello), to: connection)
        let reads = await events.refreshCount; XCTAssertEqual(reads, 1, "Hello reconciles what the sleep missed")
        requests = await driver.requests; XCTAssertEqual(requests.count, 5)
        await connection.stop()
    }
    func testAReconnectHintCutsABackoffShort() async throws {
        let (connection, clock, driver, _) = try await setup()
        await send(.failed(nil), to: connection); clock.advance(1); await connection.tick()
        await send(.failed(nil), to: connection)
        var state = await connection.snapshot(); XCTAssertEqual(state.state, .retryWaiting)
        await connection.reconnectHint(.network)
        state = await connection.snapshot(); XCTAssertEqual(state.state, .connecting)
        let requests = await driver.requests; XCTAssertEqual(requests.count, 3)
        await send(.failed(nil), to: connection)
        clock.advance(1); await connection.tick()
        state = await connection.snapshot(); XCTAssertEqual(state.state, .connecting, "Backoff starts over, not from the third step")
        await connection.stop()
    }
    func testAReconnectHintChecksALiveSocketOnTheNextTick() async throws {
        let (connection, _, driver, _) = try await setup()
        await send(.text(hello), to: connection)
        let socket = await driver.sockets[0]
        await connection.tick()
        var pings = await socket.pings; XCTAssertEqual(pings, 0)
        await connection.reconnectHint(.wake)
        await connection.tick()
        pings = await socket.pings; XCTAssertEqual(pings, 1, "A socket that slept may be dead: find out now")
        await connection.tick()
        pings = await socket.pings; XCTAssertEqual(pings, 1, "One extra ping, back to the 30-second rhythm")
        let state = await connection.snapshot(); XCTAssertEqual(state.state, .connected)
        let requests = await driver.requests; XCTAssertEqual(requests.count, 1, "A live socket is not replaced")
        await connection.stop()
    }
    /// The network can come back while the last doomed attempt is still in flight: that failure must not cost two minutes.
    func testAReconnectHintDuringAnAttemptForgivesEarlierFailures() async throws {
        let (connection, clock, driver, _) = try await setup()
        await send(.failed(nil), to: connection); clock.advance(1); await connection.tick()
        await send(.failed(nil), to: connection); clock.advance(2); await connection.tick()
        await connection.reconnectHint(.network)
        let requests = await driver.requests; XCTAssertEqual(requests.count, 3, "The attempt in flight is not doubled")
        await send(.failed(nil), to: connection)
        let state = await connection.snapshot(); XCTAssertEqual(state.state, .retryWaiting)
        await connection.stop()
    }
    func testAReconnectHintNeverBringsBackAConnectionThatMustStayDown() async throws {
        for event in [OnlineBattleSocketEvent.closed(4001), .closed(4003), .closed(4400)] {
            let (connection, _, driver, _) = try await setup()
            await send(event, to: connection)
            let before = await connection.snapshot()
            await connection.reconnectHint(.wake)
            let after = await connection.snapshot(); XCTAssertEqual(after, before)
            let requests = await driver.requests; XCTAssertEqual(requests.count, 1, "\(event)")
            await connection.stop()
        }
        let (stopped, _, driver, _) = try await setup()
        await stopped.stop()
        await stopped.reconnectHint(.network)
        let requests = await driver.requests; XCTAssertEqual(requests.count, 1)
    }
    func testPresenceWhileClosedWaitsForOneRefreshOnOpen() async throws {
        let (connection, _, _, events) = try await setup()
        await send(.text(hello), to: connection)
        for online in [true, false, true] {
            await send(.text(#"{"v":1,"type":"presence","trainerId":"synthetic-other","online":\#(online)}"#), to: connection)
        }
        var reads = await events.refreshCount; XCTAssertEqual(reads, 1, "One colleague's flapping must not fan out while nobody looks")
        await connection.setPopoverOpen(true)
        reads = await events.refreshCount; XCTAssertEqual(reads, 2)
        await connection.setPopoverOpen(false); await connection.setPopoverOpen(true)
        reads = await events.refreshCount; XCTAssertEqual(reads, 2, "Only once, and only when something changed")
        await send(.text(#"{"v":1,"type":"presence","trainerId":"synthetic-other","online":false}"#), to: connection)
        reads = await events.refreshCount; XCTAssertEqual(reads, 3, "An open popover stays live")
        await connection.stop()
    }
    func testAnOtherReadCoversTheMissedPresence() async throws {
        let presence = #"{"v":1,"type":"presence","trainerId":"synthetic-other","online":true}"#
        let (changed, _, _, changedEvents) = try await setup()
        await send(.text(hello), to: changed); await send(.text(presence), to: changed)
        await send(.text(#"{"v":1,"type":"group_changed","kind":"join"}"#), to: changed)
        var reads = await changedEvents.refreshCount; XCTAssertEqual(reads, 2, "Group changes are rare and still read while closed")
        await changed.setPopoverOpen(true)
        reads = await changedEvents.refreshCount; XCTAssertEqual(reads, 2)
        await changed.stop()

        let (reconnected, clock, _, reconnectedEvents) = try await setup()
        await send(.text(hello), to: reconnected); await send(.text(presence), to: reconnected)
        await send(.closed(1006), to: reconnected); clock.advance(1); await reconnected.tick()
        await send(.text(hello), to: reconnected)
        await reconnected.setPopoverOpen(true)
        reads = await reconnectedEvents.refreshCount; XCTAssertEqual(reads, 2, "The second hello already read everything")
        await reconnected.stop()

        let (polling, pollClock, _, pollingEvents) = try await setup()
        await send(.text(hello), to: polling); await send(.text(presence), to: polling)
        await send(.closed(1006), to: polling); pollClock.advance(1); await polling.tick()
        await enterPolling(polling, pollClock)
        await polling.setPopoverOpen(true)
        reads = await pollingEvents.refreshCount; XCTAssertEqual(reads, 2, "Opening reads once, not once for polling and once for the mark")
        await polling.stop()
    }
    func testAMessageTypeThisVersionDoesNotKnowIsIgnored() async throws {
        let (connection, _, driver, events) = try await setup()
        await send(.text(#"{"v":1,"type":"mystery"}"#), to: connection)
        var state = await connection.snapshot(); XCTAssertEqual(state.state, .connecting, "Hello can still arrive")
        await send(.text(hello), to: connection)
        await send(.text(#"{"v":1,"type":"mystery","anything":{"nested":[1,2]}}"#), to: connection)
        await send(.text(#"{"v":1,"type":"mystery","trainerId":7,"online":"several"}"#), to: connection)
        state = await connection.snapshot(); XCTAssertEqual(state.state, .connected)
        XCTAssertEqual(state.connectionId, "synthetic-connection")
        let socket = await driver.sockets[0]
        let closes = await socket.closes; XCTAssertEqual(closes, 0)
        await send(.text(#"{"v":1,"type":"group_changed"}"#), to: connection)
        let reads = await events.refreshCount; XCTAssertEqual(reads, 2, "The socket keeps working after the unknown message")
        await connection.stop()
    }
    func testConnectionTransitionsAreLoggedWithoutKeyOrAddress() async throws {
        let clock = OnlineTestClock(), driver = OnlineTestSocketDriver(), sink = OnlineLogLines()
        let connection = OnlineBattleConnection(driver: driver, clock: clock.clock, jitter: { $0 }, automaticTicks: false, log: { sink.append($0) })
        await connection.configure(origin: try OnlineBattleOrigin("https://example.invalid"), accessKey: "synthetic-key")
        await send(.text(hello), to: connection)
        await send(.closed(1006), to: connection)
        await connection.reconnectHint(.wake)
        XCTAssertEqual(sink.lines, ["online connection: unconfigured -> connecting",
                                    "online connection: connecting -> connected",
                                    "online connection: connected -> retryWaiting",
                                    "online connection: reconnect hint (wake) in retryWaiting",
                                    "online connection: retryWaiting -> connecting"])
        await send(.text(hello), to: connection)
        await connection.reconnectHint(.network)
        await connection.tick()
        let all = sink.lines.joined(separator: "\n")
        XCTAssertTrue(all.contains("reconnect hint (network) in connected"), all)
        for secret in ["synthetic-key", "example.invalid", "synthetic-connection", "synthetic-trainer", "synthetic-group", "Bearer"] {
            XCTAssertFalse(all.contains(secret), secret)
        }
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
        for text in [#"{"v":2,"type":"hello"}"#, #"{"v":2,"type":"mystery"}"#, #"{"v":1,"type":"hello","online":[]}"#, "not-json"] {
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
    func testPresenceRefreshesAccountWhileBattleNotificationsStayScoped() async throws {
        let (connection, _, _, events) = try await setup()
        await connection.setPopoverOpen(true)
        await send(.text(hello), to: connection)
        for text in [#"{"v":1,"type":"presence","trainerId":"synthetic-other","online":true}"#, #"{"v":1,"type":"battle_changed","battleId":"bt_synthetic"}"#, #"{"v":1,"type":"battle_round","battleId":"bt_synthetic"}"#, #"{"v":1,"type":"group_changed","kind":"join"}"#] { await send(.text(text), to: connection) }
        let count = await events.refreshCount; XCTAssertEqual(count, 3)
        await connection.stop()
    }
    func testAKnownTypeThatBreaksItsOwnRulesStillStops() async throws {
        let (connection, _, _, _) = try await setup()
        await send(.text(hello), to: connection)
        await send(.text(#"{"v":1,"type":"battle_changed","battleId":"not-a-battle-id"}"#), to: connection)
        let state = await connection.snapshot(); XCTAssertEqual(state.state, .protocolError)
        await connection.stop()
    }
    func testGroupVoidNotificationRefreshesWithoutStoppingProtocol() async throws {
        let (connection, _, _, events) = try await setup()
        await send(.text(hello), to: connection)
        await send(.text(#"{"v":1,"type":"battle_void","battleId":"bt_synthetic","reason":"result_mismatch"}"#), to: connection)
        let state = await connection.snapshot(); XCTAssertEqual(state.state, .connected)
        let count = await events.refreshCount; XCTAssertEqual(count, 1)
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

@MainActor
private final class OnlineSignalBox { var values: [OnlineBattleReconnectReason] = [] }
@MainActor
final class OnlineReconnectSignalsTests: XCTestCase {
    func testWakeAndNetworkReturnBothSignal() async throws {
        let center = NotificationCenter(), received = expectation(description: "both signals"), box = OnlineSignalBox()
        received.expectedFulfillmentCount = 2
        let signals = OnlineReconnectSignals(center: center) { reason in box.values.append(reason); received.fulfill() }
        signals.start(); signals.start()
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        signals.network.onReconnected?()
        await fulfillment(of: [received], timeout: 2)
        XCTAssertEqual(Set(box.values), [.wake, .network])
        XCTAssertEqual(box.values.count, 2, "Starting twice must not signal twice")
    }
    /// The delegate cannot run under `swift test`, so this reads the wiring the way the other source guards do.
    func testTheAppFeedsTheSignalsToTheSession() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PokeTokenBar/PokeTokenBarApp.swift")
        let source = try String(contentsOf: app, encoding: .utf8)
        XCTAssertTrue(source.contains("OnlineReconnectSignals"), "No wake or network signal reaches the online session")
        XCTAssertTrue(source.contains(".reconnectHint("), "The signals must end at the session")
    }
}
