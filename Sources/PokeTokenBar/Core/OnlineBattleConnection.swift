import Foundation

enum OnlineBattleConnectionState: Equatable, Sendable {
    case unconfigured, credentialsRequired, connecting, connected, retryWaiting, polling, replaced, revoked, protocolError
}
struct OnlineBattleConnectionSnapshot: Equatable, Sendable {
    let state: OnlineBattleConnectionState
    let generation: UInt64
    let connectionId: String?
    let trainerId: String?
    let groupId: String?
}
/// Why the Mac may have a usable network again. Only said in the transition log.
enum OnlineBattleReconnectReason: String, Sendable { case wake, network }
enum OnlineBattleConnectionEvent: Sendable {
    case changed(OnlineBattleConnectionSnapshot)
    /// Account changes and reconnects reconcile through authoritative HTTP reads.
    case refreshRequested
    case standingsRefreshRequested
    /// Scoped public relay data, tied to the authenticated socket that received it.
    case battleNotification(OnlineBattleConnectionSnapshot, battleID: String, payload: Data)
}
enum OnlineBattleSocketEvent: Sendable, Equatable {
    case text(String), closed(Int), failed(Int?)
    static func receiveFailure(httpStatus: Int?, closeCode: Int) -> Self {
        if httpStatus == 401 { return .failed(401) }
        return closeCode != 0 ? .closed(closeCode) : .failed(httpStatus)
    }
}
protocol OnlineBattleSocket: Sendable {
    var events: AsyncStream<OnlineBattleSocketEvent> { get }
    func sendPing() async throws
    func close() async
}
protocol OnlineBattleSocketDriver: Sendable { func connect(_ request: URLRequest) async throws -> any OnlineBattleSocket }
struct OnlineBattleConnectionClock: Sendable {
    var now: @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }
    var sleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
}
protocol OnlineBattleConnecting: Sendable {
    func configure(origin: OnlineBattleOrigin?, accessKey: String?) async
    func setPopoverOpen(_ open: Bool) async
    func reconnectHint(_ reason: OnlineBattleReconnectReason) async
    func snapshot() async -> OnlineBattleConnectionSnapshot
    func authenticationFailed(generation: UInt64) async
    func stop() async
}
/// Owns reconnect policy; every callback is scoped to one connection generation.
actor OnlineBattleConnection: OnlineBattleConnecting {
    typealias Observer = @Sendable (OnlineBattleConnectionEvent) async -> Void
    private let driver: any OnlineBattleSocketDriver
    private let clock: OnlineBattleConnectionClock
    private let jitter: @Sendable (TimeInterval) -> TimeInterval
    private let automaticTicks: Bool
    private let observer: Observer
    private let log: @Sendable (String) -> Void
    private var state: OnlineBattleConnectionState = .unconfigured
    private var generation: UInt64 = 0
    private var origin: OnlineBattleOrigin?
    private var accessKey: String?
    private var socket: (any OnlineBattleSocket)?
    private var receiver: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var connectionId: String?
    private var trainerId: String?
    private var groupId: String?
    private var popoverOpen = false
    private var attempts = 0
    private var openFailures = 0
    private var openedAt: TimeInterval?
    private var nextAction: TimeInterval?
    private var nextPing: TimeInterval?
    private var nextPoll: TimeInterval?
    /// A colleague came or went while nobody could see it. The next read covers it, whatever asks for that read.
    private var presenceMissed = false
    private var loggedState: OnlineBattleConnectionState = .unconfigured
    /// How long the socket rests after three failed opens. The wake and network hints cut it short.
    private static let pollingRetryInterval: TimeInterval = 120
    /// Anything else is from a newer server: ignored, so an older app keeps its connection.
    private static let knownMessageTypes: Set<String> = ["hello", "standings_changed", "battle_changed", "battle_round", "battle_void", "presence", "group_changed"]
    init(driver: any OnlineBattleSocketDriver = OnlineBattleURLSessionSocketDriver(),
         clock: OnlineBattleConnectionClock = .init(),
         jitter: @escaping @Sendable (TimeInterval) -> TimeInterval = { Double.random(in: 0...$0) },
         automaticTicks: Bool = true, observer: @escaping Observer = { _ in },
         log: @escaping @Sendable (String) -> Void = { AppLog.write($0) }) {
        self.driver = driver; self.clock = clock; self.jitter = jitter; self.automaticTicks = automaticTicks; self.log = log; self.observer = observer
    }
    func snapshot() -> OnlineBattleConnectionSnapshot {
        .init(state: state, generation: generation, connectionId: connectionId, trainerId: trainerId, groupId: groupId)
    }
    func configure(origin: OnlineBattleOrigin?, accessKey: String?) async {
        invalidate()
        self.origin = origin; self.accessKey = accessKey
        attempts = 0; openFailures = 0
        if origin == nil { state = .unconfigured; await publish(); return }
        guard accessKey != nil else { state = .credentialsRequired; await publish(); return }
        startTimer()
        await connect()
    }
    func setPopoverOpen(_ open: Bool) async {
        let wasOpen = popoverOpen; popoverOpen = open
        if open && !wasOpen {
            if state == .replaced { attempts = 0; openFailures = 0; await connect() }
            else if state == .polling {
                attempts = 0; openFailures = 0; nextPoll = clock.now() + 30
                await requestRefresh()
                // The read suspended, so a wake or network hint may already have reconnected.
                if state == .polling { await connect() }
            } else if state == .connected, presenceMissed { await requestRefresh() }
        }
        if !open { nextPoll = nil }
    }
    /// The Mac woke or got its network back: stop waiting out a backoff that was measured against a dead network.
    /// A replaced socket stays down so two Macs do not fight over one account, and the other stopped states have nothing to retry.
    func reconnectHint(_ reason: OnlineBattleReconnectReason) async {
        log("online connection: reconnect hint (\(reason.rawValue)) in \(state)")
        switch state {
        case .polling, .retryWaiting:
            attempts = 0; openFailures = 0
            await connect()
        case .connecting:
            // This attempt may have started before the network returned. Its failure must not cost the two-minute rest.
            attempts = 0; openFailures = 0
        case .connected:
            // A socket that slept may be dead without having said so.
            nextPing = clock.now()
        case .unconfigured, .credentialsRequired, .replaced, .revoked, .protocolError:
            break
        }
    }
    func authenticationFailed(generation epoch: UInt64) async {
        guard epoch == generation else { return }
        await terminate(.revoked)
    }
    func stop() async { invalidate(); state = origin == nil ? .unconfigured : .credentialsRequired; await publish() }
    private func invalidate() {
        generation &+= 1
        receiver?.cancel(); receiver = nil; timer?.cancel(); timer = nil
        let old = socket; socket = nil
        connectionId = nil; trainerId = nil; groupId = nil
        nextAction = nil; nextPing = nil; nextPoll = nil; openedAt = nil
        if let old { Task { await old.close() } }
    }
    private func startTimer() {
        guard automaticTicks, timer == nil else { return }
        let clock = clock
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await clock.sleep(1) } catch { return }
                guard !Task.isCancelled else { return }
                await self?.tick()
            }
        }
    }
    private func publish() async {
        if state != loggedState {
            log("online connection: \(loggedState) -> \(state)")
            loggedState = state
        }
        await observer(.changed(snapshot()))
    }
    private func requestRefresh() async {
        presenceMissed = false
        await observer(.refreshRequested)
    }
    private func connect() async {
        guard let origin, let accessKey else { return }
        generation &+= 1; let epoch = generation
        receiver?.cancel(); receiver = nil
        let old = socket; socket = nil
        connectionId = nil; trainerId = nil; groupId = nil; nextPing = nil; openedAt = nil
        state = .connecting; nextAction = clock.now() + OnlineBattleProtocolPing.timeout
        await old?.close()
        guard epoch == generation else { return }
        await publish()
        guard epoch == generation else { return }
        var parts = URLComponents(url: origin.url, resolvingAgainstBaseURL: false)!
        parts.scheme = origin.url.scheme == "http" ? "ws" : "wss"; parts.path = "/v1/connect"
        var request = URLRequest(url: parts.url!)
        request.timeoutInterval = OnlineBattleProtocolPing.timeout; request.setValue("Bearer " + accessKey, forHTTPHeaderField: "Authorization")
        do {
            let candidate = try await driver.connect(request)
            guard epoch == generation, state == .connecting else { await candidate.close(); return }
            socket = candidate
            receiver = Task { [weak self] in
                for await event in candidate.events {
                    guard !Task.isCancelled else { return }
                    await self?.receive(event, generation: epoch)
                }
            }
        } catch {
            guard epoch == generation else { return }
            if error as? OnlineBattleFailure == .unauthorized { await terminate(.revoked) }
            else { await failedConnection() }
        }
    }
    private struct Message: Decodable {
        let v: Int
        let type: String
        let connectionId: String?
        let trainerId: String?
        let groupId: String?
        let online: [String]?
        let battleId: String?
        // `presence.online` is a Boolean, while hello.online is an array.
        private enum CodingKeys: String, CodingKey { case v, type, connectionId, trainerId, groupId, online, battleId }
        init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: CodingKeys.self)
            v = try box.decode(Int.self, forKey: .v); type = try box.decode(String.self, forKey: .type)
            // A newer message may use these names for something else; that must not fail the decode.
            guard OnlineBattleConnection.knownMessageTypes.contains(type) else {
                connectionId = nil; trainerId = nil; groupId = nil; battleId = nil; online = nil
                return
            }
            connectionId = try box.decodeIfPresent(String.self, forKey: .connectionId)
            trainerId = try box.decodeIfPresent(String.self, forKey: .trainerId)
            groupId = try box.decodeIfPresent(String.self, forKey: .groupId)
            battleId = try box.decodeIfPresent(String.self, forKey: .battleId)
            online = type == "hello" ? try box.decode([String].self, forKey: .online) : nil
        }
    }
    /// Also an injection boundary for deterministic transport tests.
    func receive(_ event: OnlineBattleSocketEvent, generation epoch: UInt64) async {
        guard epoch == generation, [.connecting, .connected].contains(state) else { return }
        switch event {
        case .text("pong"): return
        case .text(let text):
            guard let message = try? JSONDecoder().decode(Message.self, from: Data(text.utf8)), message.v == 1 else {
                await terminate(.protocolError); return
            }
            if message.type == "hello" {
                guard state == .connecting, let id = message.connectionId, !id.isEmpty,
                      let trainer = message.trainerId, !trainer.isEmpty, let group = message.groupId, !group.isEmpty else {
                    await terminate(.protocolError); return
                }
                connectionId = id; trainerId = trainer; groupId = group
                state = .connected; openedAt = clock.now(); nextAction = nil; nextPing = clock.now() + 30
                openFailures = 0
                await publish()
                guard epoch == generation else { return }
                await requestRefresh()
            } else if message.type == "standings_changed", state == .connected {
                await observer(.standingsRefreshRequested)
            } else if ["battle_changed", "battle_round", "battle_void"].contains(message.type), state == .connected,
                      let id = message.battleId, id.hasPrefix("bt_"), id.count <= 128 {
                await observer(.battleNotification(snapshot(), battleID: id, payload: Data(text.utf8)))
            } else if message.type == "presence", state == .connected {
                // One colleague's sign-in costs every other member a full read, so it waits until someone can see it.
                if popoverOpen { await requestRefresh() } else { presenceMissed = true }
            } else if message.type == "group_changed", state == .connected {
                await requestRefresh()
            } else if Self.knownMessageTypes.contains(message.type) { await terminate(.protocolError) }
        case .closed(4001): await terminate(.replaced)
        case .closed(4003), .failed(401): await terminate(.revoked)
        case .closed(4400): await terminate(.protocolError)
        case .closed, .failed: await failedConnection()
        }
    }
    private func terminate(_ target: OnlineBattleConnectionState) async {
        invalidate(); state = target; await publish()
        if target == .replaced { startTimer() }
    }
    private func failedConnection() async {
        let now = clock.now()
        if let openedAt, now - openedAt >= 60 { attempts = 0 }
        if state == .connecting { openFailures += 1 }
        generation &+= 1; receiver?.cancel(); receiver = nil
        let old = socket; socket = nil
        connectionId = nil; trainerId = nil; groupId = nil; nextPing = nil; openedAt = nil
        if openFailures >= 3 {
            state = .polling; nextAction = now + Self.pollingRetryInterval; nextPoll = popoverOpen ? now + 30 : nil
        } else {
            let maximum = min(60, pow(2, Double(min(attempts, 6))))
            state = .retryWaiting; nextAction = now + min(max(0, jitter(maximum)), maximum); attempts += 1
        }
        let epoch = generation
        await old?.close()
        guard epoch == generation else { return }
        await publish()
        if state == .polling, popoverOpen { await requestRefresh() }
    }
    func tick() async {
        let now = clock.now(), epoch = generation
        if state == .connected {
            if let openedAt, now - openedAt >= 60 { attempts = 0 }
            if let nextPing, now >= nextPing {
                self.nextPing = now + 30
                do { try await socket?.sendPing() }
                catch { if epoch == generation { await failedConnection() } }
            }
        } else if state == .connecting, let nextAction, now >= nextAction { await failedConnection() }
        else if (state == .retryWaiting || state == .polling), let nextAction, now >= nextAction {
            if state == .polling { openFailures = 0 }
            await connect()
        } else if state == .polling, popoverOpen, let nextPoll, now >= nextPoll {
            self.nextPoll = now + 30; await requestRefresh()
        }
    }
}

/// A missing control-frame pong must not leave the connection ticker suspended forever.
/// The single-resume gate does not wait for URLSession's callback to cooperate with cancellation.
enum OnlineBattleProtocolPing {
    static let timeout: TimeInterval = 15 // Same boundary as the WebSocket handshake.
    static func wait(sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
                     send: @Sendable (@escaping @Sendable (Error?) -> Void) -> Void,
                     cancel: @escaping @Sendable () -> Void) async throws {
        let completion = PingCompletion()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard completion.install(continuation) else { return }
                let timer = Task {
                    do { try await sleep(timeout) } catch { return }
                    completion.finish(.failure(URLError(.timedOut)), beforeResume: cancel)
                }
                completion.setTimer(timer)
                send { error in _ = completion.finish(error.map { .failure($0) } ?? .success(())) }
            }
        } onCancel: {
            completion.finish(.failure(CancellationError()), beforeResume: cancel)
        }
    }
    private final class PingCompletion: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?
        private var result: Result<Void, Error>?
        private var timer: Task<Void, Never>?
        func install(_ value: CheckedContinuation<Void, Error>) -> Bool {
            let finished: Result<Void, Error>? = lock.withLock {
                if let result { return result }
                continuation = value; return nil as Result<Void, Error>?
            }
            if let finished { value.resume(with: finished); return false }
            return true
        }
        func setTimer(_ value: Task<Void, Never>) {
            let finished = lock.withLock {
                if result != nil { return true }
                timer = value; return false
            }
            if finished { value.cancel() }
        }
        @discardableResult
        func finish(_ value: Result<Void, Error>, beforeResume: () -> Void = {}) -> Bool {
            let pending: (CheckedContinuation<Void, Error>?, Task<Void, Never>?)? = lock.withLock {
                guard result == nil else { return nil }
                result = value
                let pending = (continuation, timer); continuation = nil; timer = nil
                return pending
            }
            guard let pending else { return false }
            pending.1?.cancel(); beforeResume(); pending.0?.resume(with: value)
            return true
        }
    }
}

struct OnlineBattleURLSessionSocketDriver: OnlineBattleSocketDriver {
    func connect(_ request: URLRequest) async throws -> any OnlineBattleSocket { OnlineBattleURLSessionSocket(request: request) }
}
/// The delegate also rejects redirects during WebSocket upgrades.
private final class OnlineBattleURLSessionSocket: NSObject, OnlineBattleSocket, URLSessionWebSocketDelegate, @unchecked Sendable {
    let events: AsyncStream<OnlineBattleSocketEvent>
    private let continuation: AsyncStream<OnlineBattleSocketEvent>.Continuation
    private var session: URLSession!
    private var task: URLSessionWebSocketTask!
    private var receiveTask: Task<Void, Never>?
    init(request: URLRequest) {
        let stream = AsyncStream<OnlineBattleSocketEvent>.makeStream()
        events = stream.stream; continuation = stream.continuation
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        task = session.webSocketTask(with: request); task.resume()
        let task = task!, continuation = continuation
        receiveTask = Task {
            do {
                while !Task.isCancelled {
                    switch try await task.receive() {
                    case .string(let text): continuation.yield(.text(text))
                    case .data: continuation.yield(.closed(4400)); return
                    @unknown default: continuation.yield(.closed(4400)); return
                    }
                }
            } catch {
                if !Task.isCancelled {
                    let status = (task.response as? HTTPURLResponse)?.statusCode
                    let closeCode = task.closeCode.rawValue
                    continuation.yield(.receiveFailure(httpStatus: status, closeCode: closeCode))
                }
            }
        }
    }
    func sendPing() async throws {
        let task = task!
        try await OnlineBattleProtocolPing.wait(send: { completion in task.sendPing(pongReceiveHandler: completion) },
            cancel: { task.cancel(with: .goingAway, reason: nil) })
    }
    func close() async {
        receiveTask?.cancel(); task.cancel(with: .normalClosure, reason: nil); session.invalidateAndCancel(); continuation.finish()
    }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        continuation.yield(.closed(closeCode.rawValue))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
