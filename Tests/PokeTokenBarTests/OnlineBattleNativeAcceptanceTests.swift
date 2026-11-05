import XCTest
@testable import PokeTokenBar

// Real URLSession HTTP/WebSocket, workerd, JSC, OnlineBattleSession and disk-backed CompanionStore.
// Only endpoint routing, credential storage, roster metadata and the deliberate network failure are injected.
private struct NativeEndpoint: Sendable {
    static let productOrigin = "https://native-acceptance.example.invalid"
    let url: URL
    func rewrite(_ request: URLRequest) throws -> URLRequest {
        guard let original = request.url, original.host == "native-acceptance.example.invalid",
              ["https", "wss"].contains(original.scheme), url.scheme == "http", url.host == "127.0.0.1",
              url.port != nil else { throw OnlineBattleFailure.invalidRequest }
        var parts = try XCTUnwrap(URLComponents(url: original, resolvingAgainstBaseURL: false))
        parts.scheme = original.scheme == "wss" ? "ws" : "http"; parts.host = url.host; parts.port = url.port
        var local = request; local.url = try XCTUnwrap(parts.url)
        return local
    }
}
private actor NativeHTTP: OnlineBattleHTTPTransport {
    let endpoint: NativeEndpoint
    private var dropCompletion = false
    private var offline = false
    private var reporting = false
    private(set) var committedDrops = 0
    private var requests: [String: Int] = [:]
    func counts() -> [String: Int] { requests }
    init(_ endpoint: NativeEndpoint) { self.endpoint = endpoint }
    func dropCompletedReportAndDisconnect() { dropCompletion = true }
    func send(_ request: URLRequest) async throws -> OnlineBattleHTTPResponse {
        guard !offline else { throw URLError(.notConnectedToInternet) }
        let path = request.url!.path
        let category = path.hasSuffix("/choices") ? "choices" : path.hasSuffix("/advance") ? "advance" : path.hasSuffix("/report") ? "report" : (request.httpMethod ?? "GET") + " " + (path.hasPrefix("/v1/battles/") ? "/v1/battles/:id" : path)
        requests[category, default: 0] += 1
        let isReport = request.httpMethod == "POST" && request.url?.path.hasSuffix("/report") == true
        if isReport { reporting = true }
        defer { if isReport { reporting = false } }
        let response = try await OnlineBattleURLSessionTransport().send(endpoint.rewrite(request))
        // A concurrent notification read cannot sneak a completed result past the disconnected client.
        guard !offline, isReport || !reporting else { throw URLError(.notConnectedToInternet) }
        if dropCompletion, isReport, response.status == 200,
           let room = try? JSONDecoder().decode(OnlineBattleView.self, from: response.body), room.state == .completed {
            // workerd has already committed. Lose only the response, then keep this client offline
            // until a fresh session/transport is created from its on-disk state.
            committedDrops += 1; offline = true
            throw URLError(.networkConnectionLost)
        }
        return response
    }
}
private final class NativePingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double = 0
    func now() -> Double { lock.withLock { value } }
    func advance(_ seconds: Double) { lock.withLock { value += seconds } }
}
/// Forwards every real frame unchanged; records whether the heartbeat leaked into the text protocol.
private final class NativeTracedSocket: OnlineBattleSocket, @unchecked Sendable {
    let events: AsyncStream<OnlineBattleSocketEvent>
    private let raw: any OnlineBattleSocket
    private let lock = NSLock()
    private var textPongs = 0
    private var successfulPings = 0
    private var receiver: Task<Void, Never>?
    init(_ raw: any OnlineBattleSocket) {
        self.raw = raw
        let stream = AsyncStream<OnlineBattleSocketEvent>.makeStream(); events = stream.stream
        receiver = Task { [weak self] in
            for await event in raw.events {
                if event == .text("pong") { self?.lock.withLock { self?.textPongs += 1 } }
                stream.continuation.yield(event)
            }
            stream.continuation.finish()
        }
    }
    func counts() -> (textPongs: Int, successfulPings: Int) { lock.withLock { (textPongs, successfulPings) } }
    func sendPing() async throws {
        try await raw.sendPing()
        lock.withLock { successfulPings += 1 }
    }
    func close() async { await raw.close(); receiver?.cancel() }
}
private actor NativeSocketProbe {
    private var sockets: [NativeTracedSocket] = []
    func append(_ socket: NativeTracedSocket) { sockets.append(socket) }
    func first() -> NativeTracedSocket? { sockets.first }
}
private struct NativeSocketDriver: OnlineBattleSocketDriver {
    let endpoint: NativeEndpoint
    var probe: NativeSocketProbe? = nil
    func connect(_ request: URLRequest) async throws -> any OnlineBattleSocket {
        let socket = try await OnlineBattleURLSessionSocketDriver().connect(endpoint.rewrite(request))
        guard let probe else { return socket }
        let traced = NativeTracedSocket(socket); await probe.append(traced); return traced
    }
}
private actor NativeCredentials: OnlineBattleCredentialStoring {
    private var key: String?
    init(_ key: String) { self.key = key }
    func load(scope: OnlineBattleCredentialScope) -> String? { key }
    func save(_ accessKey: String, scope: OnlineBattleCredentialScope) { key = accessKey }
    func remove(scope: OnlineBattleCredentialScope) { key = nil }
}
private struct NativeOfflineProvider: PokeProviding {
    enum Offline: Error { case intentional }
    func line(baseSpeciesID: Int) async throws -> EvoLine { throw Offline.intentional }
    func baseSpeciesIndex() async throws -> [BaseSpecies] { [] }
    func baseSpecies(id: Int) async throws -> BaseSpecies? { nil }
}

@MainActor
final class OnlineBattleNativeAcceptanceTests: XCTestCase {
    private var endpoint: NativeEndpoint!
    private var folder: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var sessions: [OnlineBattleSession] = []
    private var connections: [OnlineBattleConnection] = []
    private var engineURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("engine/dist/battle-engine.js")
    }
    override func setUp() async throws {
        guard let value = ProcessInfo.processInfo.environment["PTB_NATIVE_ACCEPTANCE_URL"] else {
            throw XCTSkip("Opt-in local Worker acceptance: run scripts/run-native-acceptance.sh")
        }
        let url = try XCTUnwrap(URL(string: value))
        guard url.scheme == "http", url.host == "127.0.0.1", url.port != nil,
              let state = ProcessInfo.processInfo.environment["PTB_STATE_DIR"], !state.isEmpty else {
            throw OnlineBattleFailure.invalidSettings
        }
        endpoint = NativeEndpoint(url: url)
        folder = URL(fileURLWithPath: state).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        suite = "OnlineBattleNativeAcceptanceTests." + UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defaults.set(1.0, forKey: "growthDifficulty")
    }
    override func tearDown() async throws {
        for session in sessions { await session.setEnabled(false) }
        for connection in connections { await connection.stop() }
        sessions = []; connections = []
        if let suite { defaults?.removePersistentDomain(forName: suite) }
        if let folder { try FileManager.default.removeItem(at: folder) }
    }
    private func engine() throws -> BattleEngine { try BattleEngine(url: engineURL) }
    private struct Fixture: Decodable { let battle: OnlineBattleView }
    private func snapshots(_ index: Int = 0) throws -> [OnlineBattleSnapshot] {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "golden", withExtension: "json", subdirectory: "OnlineBattle"))
        let room = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: file))[index].battle
        return [try XCTUnwrap(room.p1.snapshot), try XCTUnwrap(room.p2.snapshot)]
    }
    private struct Pair {
        let grants: [OnlineBattleGrant]
        let apis: [OnlineBattleAPI]
    }
    private func pair() async throws -> Pair {
        let transport = NativeHTTP(endpoint)
        var request = URLRequest(url: URL(string: NativeEndpoint.productOrigin + "/v1/groups")!)
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "operatorSecret": try XCTUnwrap(ProcessInfo.processInfo.environment["PTB_NATIVE_OPERATOR_SECRET"]),
            "groupName": "Synthetic native acceptance", "displayEmail": "Host"])
        let response = try await transport.send(request)
        XCTAssertEqual(response.status, 200)
        let host = try JSONDecoder().decode(OnlineBattleGrant.self, from: response.body)
        let origin = try OnlineBattleOrigin(NativeEndpoint.productOrigin)
        let a = OnlineBattleAPI(origin: origin, transport: transport)
        let b = OnlineBattleAPI(origin: origin, transport: NativeHTTP(endpoint))
        await a.setAccessKey(host.accessKey)
        let invite = try await a.createInvite(ttlSeconds: 3600, maxUses: 1)
        let guest = try await b.join(inviteCode: invite.inviteCode, displayEmail: "Guest")
        await b.setAccessKey(guest.accessKey)
        _ = try await a.revokeInvite(inviteId: invite.invite.inviteId)
        return Pair(grants: [host, guest], apis: [a, b])
    }
    private func connected(_ grant: OnlineBattleGrant) async throws -> String {
        let connection = OnlineBattleConnection(driver: NativeSocketDriver(endpoint: endpoint))
        connections.append(connection)
        await connection.configure(origin: try OnlineBattleOrigin(NativeEndpoint.productOrigin), accessKey: grant.accessKey)
        for _ in 0..<200 {
            let status = await connection.snapshot()
            if status.state == .connected { return try XCTUnwrap(status.connectionId) }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Native WebSocket hello did not arrive")
        throw OnlineBattleFailure.transport
    }
    private func running(_ pair: Pair, mode: OnlineBattleMode, snapshots: [OnlineBattleSnapshot]) async throws -> OnlineBattleView {
        let ids = [try await connected(pair.grants[0]), try await connected(pair.grants[1])]
        var room = try await pair.apis[0].createBattle(requestId: UUID().uuidString,
            targetTrainerId: pair.grants[1].trainer.trainerId, mode: mode, snapshot: snapshots[0])
        XCTAssertEqual(room.state, .pending)
        room = try await pair.apis[1].accept(id: room.battleId, revision: room.revision, snapshot: snapshots[1])
        room = try await pair.apis[0].confirm(id: room.battleId, revision: room.revision)
        for i in 0..<2 {
            room = try await pair.apis[i].ready(id: room.battleId, revision: room.revision, connectionId: ids[i],
                engineHash: BattleEngineManifest.sha256, rulesVersion: BattleSnapshot.rules, policyVersion: BattleSnapshot.policy)
        }
        XCTAssertEqual(room.state, .ready)
        let config = try XCTUnwrap(room.config)
        for i in 0..<2 {
            room = try await pair.apis[i].start(id: room.battleId, revision: room.revision,
                connectionId: ids[i], readyToken: config.readyToken, engineHash: config.engineHash)
        }
        XCTAssertEqual(room.state, .running)
        return room
    }
    private func terminal(_ initial: OnlineBattleView, pair: Pair) async throws -> (OnlineBattleView, OnlineBattleReport) {
        var room = initial
        let resolvers = try pair.grants.map { try OnlineBattleResolver(battle: room, localTrainerID: $0.trainer.trainerId, engine: engine()) }
        defer { resolvers.forEach { $0.close() } }
        for _ in 0..<200 {
            if room.mode == .manual {
                let slot1 = resolvers[0].request.moves.first { !$0.disabled && $0.pp > 0 }?.slot ?? 1
                let slot2 = resolvers[1].request.moves.first { !$0.disabled && $0.pp > 0 }?.slot ?? 1
                _ = try await pair.apis[0].choose(id: room.battleId, roundSeq: room.roundSeq, slot: slot1)
                let hidden = try await pair.apis[1].battle(id: room.battleId)
                XCTAssertNil(hidden.ownChoice, "First opponent choice must remain private")
                XCTAssertEqual(hidden.journal.count, resolvers[1].processedRoundSeq)
                room = try await pair.apis[1].choose(id: room.battleId, roundSeq: room.roundSeq, slot: slot2)
            }
            for resolver in resolvers { try resolver.consume(journal: room.journal) }
            if let report = try resolvers[0].terminalReport() {
                XCTAssertEqual(try resolvers[1].terminalReport(), report)
                return (room, report)
            }
            room = try await pair.apis[0].advance(id: room.battleId, processedRoundSeq: resolvers[0].processedRoundSeq)
        }
        XCTFail("Native match did not finish within the 200-round rule")
        throw OnlineBattleFailure.invalidResponse
    }
    private func protocolHeartbeatAndReconnect(_ grant: OnlineBattleGrant) async throws {
        let clock = NativePingClock(), probe = NativeSocketProbe()
        let connection = OnlineBattleConnection(driver: NativeSocketDriver(endpoint: endpoint, probe: probe),
            clock: .init(now: { clock.now() }), jitter: { $0 }, automaticTicks: false)
        connections.append(connection)
        await connection.configure(origin: try OnlineBattleOrigin(NativeEndpoint.productOrigin), accessKey: grant.accessKey)
        for _ in 0..<200 {
            if await connection.snapshot().state == .connected { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let before = await connection.snapshot()
        XCTAssertEqual(before.state, .connected)
        let traced = await probe.first()
        let socket = try XCTUnwrap(traced)
        clock.advance(29); await connection.tick(); XCTAssertEqual(socket.counts().successfulPings, 0)
        clock.advance(1); await connection.tick()
        XCTAssertEqual(socket.counts().successfulPings, 1, "A protocol ping must receive its actual control-frame pong")
        // A legacy text ping causes a text pong on the actual Worker; a control frame never does.
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(socket.counts().textPongs, 0, "Heartbeat must bypass the Worker's text message handler")
        await socket.close(); clock.advance(30); await connection.tick()
        var state = await connection.snapshot()
        XCTAssertEqual(state.state, .retryWaiting, "Failed real ping must enter the existing reconnect policy")
        clock.advance(1); await connection.tick()
        for _ in 0..<200 {
            if await connection.snapshot().state == .connected { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        state = await connection.snapshot()
        XCTAssertEqual(state.state, .connected); XCTAssertGreaterThan(state.generation, before.generation)
        XCTAssertNotEqual(state.connectionId, before.connectionId)
        await connection.stop()
    }
    func testNativeManualAndAutomaticReportsPrivacyReplayAndRematch() async throws {
        let pair = try await pair(), snapshots = try snapshots()
        XCTAssertThrowsError(try OnlineBattleOrigin(endpoint.url.absoluteString), "Product HTTPS policy must remain intact")
        try await protocolHeartbeatAndReconnect(pair.grants[0])
        for mode in [OnlineBattleMode.manual, .auto] {
            let initial = try await running(pair, mode: mode, snapshots: snapshots)
            let (terminal, report) = try await terminal(initial, pair: pair)
            var room = try await pair.apis[0].report(id: terminal.battleId, report: report)
            XCTAssertEqual(room.state, .reported)
            room = try await pair.apis[1].report(id: room.battleId, report: report)
            XCTAssertEqual(room.state, .completed)
            let duplicate = try await pair.apis[0].report(id: room.battleId, report: report)
            XCTAssertEqual(duplicate, room)
            let reloaded = try await pair.apis[1].battle(id: room.battleId)
            let rebuilt = try OnlineBattleResolver.completedResolver(battle: reloaded,
                localTrainerID: pair.grants[1].trainer.trainerId, engine: engine())
            defer { rebuilt.close() }
            let replayProof = try rebuilt.verifyCompleted(reloaded)
            XCTAssertEqual(replayProof.winner, report.winner)
            let other = try OnlineBattleResolver.completedResolver(battle: room,
                localTrainerID: pair.grants[0].trainer.trainerId, engine: engine())
            defer { other.close() }
            XCTAssertEqual(try other.verifyCompleted(room).resultHash, replayProof.resultHash)
            let standings = try await pair.apis[0].standings()
            XCTAssertEqual(standings.rows.reduce(0) { $0 + $1.wins + $1.losses + $1.draws }, mode == .manual ? 2 : 4)
            let rematch = try await pair.apis[0].rematch(id: room.battleId, requestId: UUID().uuidString, snapshot: snapshots[0])
            XCTAssertEqual(rematch.state, .pending)
            XCTAssertNil(rematch.p2.snapshot)
            XCTAssertFalse(rematch.confirmed)
            do {
                _ = try await pair.apis[0].confirm(id: rematch.battleId, revision: rematch.revision)
                XCTFail("A rematch must require a new opponent acceptance")
            } catch let error as OnlineBattleServerError { XCTAssertEqual(error.code, .invalidState) }
            let accepted = try await pair.apis[1].accept(id: rematch.battleId,
                revision: rematch.revision, snapshot: snapshots[1])
            XCTAssertEqual(accepted.state, .accepted)
            XCTAssertNotEqual(accepted.battleId, room.battleId)
            XCTAssertEqual(accepted.rematchOf, room.battleId)
            _ = try await pair.apis[0].cancel(id: accepted.battleId, revision: accepted.revision)
        }
        try await pairedTwoHundredTurnRequestBudget()
    }
    /// Production Sessions, with no per-turn helper GET/advance. Measures actual request paths.
    private func pairedTwoHundredTurnRequestBudget() async throws {
        let pair = try await pair(), snapshots = try snapshots(6)
        let initial = try await running(pair, mode: .manual, snapshots: snapshots)
        let stores = try (0..<2).map { try store($0, snapshot: snapshots[$0], create: true) }
        let transports = [NativeHTTP(endpoint), NativeHTTP(endpoint)]
        let live = (0..<2).map { session(pair.grants[$0], snapshot: snapshots[$0], store: stores[$0], transport: transports[$0]) }
        for session in live { await session.bootstrap() }
        for _ in 0..<200 {
            if live.allSatisfy({ $0.presentation.canStart && $0.presentation.room?.roundSeq == 1 }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        // Drain initial hello reconciliation before measuring the normal-turn request path.
        for session in live { await session.refresh() }
        let baseline = [await transports[0].counts(), await transports[1].counts()]
        for seq in 1...200 {
            for _ in 0..<400 {
                if live.allSatisfy({ $0.presentation.room?.state == .running && $0.presentation.room?.roundSeq == seq && $0.presentation.room?.journal.count == seq - 1 }) { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            for session in live {
                XCTAssertEqual(session.presentation.room?.roundSeq, seq)
                XCTAssertEqual(session.presentation.room?.journal.count, seq - 1)
                guard let request = session.presentation.request,
                      let slot = request.moves.first(where: { !$0.disabled && $0.pp > 0 })?.slot else {
                    XCTFail("Long-match fixture ran out of selectable moves before the terminal cap")
                    throw OnlineBattleFailure.invalidResponse
                }
                await session.perform(.chooseMove(slot))
            }
        }
        for _ in 0..<400 {
            if stores.allSatisfy({ $0.state.onlineBattleReceipts.count == 1 }) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        for (i, session) in live.enumerated() {
            XCTAssertEqual(session.presentation.room?.state, .completed)
            XCTAssertEqual(session.presentation.room?.roundSeq, 200)
            XCTAssertEqual(session.presentation.room?.result?.winner, .draw)
            XCTAssertEqual(stores[i].state.onlineBattleReceipts.count, 1)
            XCTAssertTrue(stores[i].state.onlineBattleHolds.isEmpty)
            XCTAssertEqual(stores[i].state.onlineBattleReceipts.first?.grantedXP, 0)
        }
        var totals: [String: Int] = [:], deltas: [String: Int] = [:]
        for i in 0..<2 {
            for (key, value) in await transports[i].counts() {
                totals[key, default: 0] += value
                deltas[key, default: 0] += value - (baseline[i][key] ?? 0)
            }
        }
        XCTAssertEqual(deltas["choices"], 400)
        XCTAssertEqual(deltas["advance"], 199, "p2 must not duplicate normal p1 advancement; terminal round must not advance")
        XCTAssertEqual(deltas["report"], 2)
        XCTAssertEqual(deltas["GET /v1/me", default: 0], 0)
        XCTAssertEqual(deltas["GET /v1/group", default: 0], 0)
        XCTAssertEqual(deltas["GET /v1/battles", default: 0], 0)
        XCTAssertLessThanOrEqual(deltas["GET /v1/battles/:id", default: 0], 6)
        print("Native paired Session 200-turn requests including bootstrap: \(totals.sorted { $0.key < $1.key }); normal phase: \(deltas.sorted { $0.key < $1.key }); battle=\(initial.roundSeq)...200")
        for session in live { await session.setEnabled(false) }
    }
    private func store(_ index: Int, snapshot: OnlineBattleSnapshot, create: Bool) throws -> CompanionStore {
        let save = folder.appendingPathComponent("synthetic-\(index).json")
        if create {
            var state = CompanionState(); state.usedSinceInstall = 1_000_000_000; state.spentTokens = 123
            state.inventory = [ItemKind.potion.rawValue: 2]
            state.active = MonState(baseID: 1, pathIDs: [1], plannedPathIDs: [1, 2, 3], stageIndex: 0,
                usedAtStage: 1_000_000, rarity: .common, totalForms: 3,
                profile: PokemonProfile.generate(seed: 1, instanceID: snapshot.instanceId))
            try JSONEncoder().encode(state).write(to: save, options: .atomic)
        }
        return CompanionStore(provider: NativeOfflineProvider(), fileURL: save, dittoDisguiseRollingEnabled: false, defaults: defaults)
    }
    private func session(_ grant: OnlineBattleGrant, snapshot: OnlineBattleSnapshot, store: CompanionStore,
                         transport: NativeHTTP) -> OnlineBattleSession {
        let endpoint = endpoint!, engineURL = engineURL
        let candidate = PracticeCandidate(id: snapshot.instanceId, name: snapshot.publicInfo.species,
            snapshot: .init(schemaVersion: 1, instanceID: snapshot.instanceId, engineHash: BattleEngineManifest.sha256,
                rulesVersion: BattleSnapshot.rules, policyVersion: BattleSnapshot.policy, set: snapshot.set,
                publicInfo: snapshot.publicInfo), blockedReason: nil)
        let session = OnlineBattleSession(settings: .init(profileID: UUID().uuidString, serverURL: NativeEndpoint.productOrigin),
            credentials: NativeCredentials(grant.accessKey), transport: transport, effects: store,
            engineFactory: { try BattleEngine(url: engineURL) },
            connectionFactory: { OnlineBattleConnection(driver: NativeSocketDriver(endpoint: endpoint), observer: $0) },
            rosterProvider: { [candidate] }, automaticTicks: false)
        sessions.append(session)
        return session
    }
    private func assertUnchangedEconomy(_ store: CompanionStore, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(store.state.usedSinceInstall, 1_000_000_000, file: file, line: line)
        XCTAssertEqual(store.state.spentTokens, 123, file: file, line: line)
        XCTAssertEqual(store.state.inventory, [ItemKind.potion.rawValue: 2], file: file, line: line)
    }
    /// The real server binds ready to a socket: one side's reconnect used to lock both sides in ACCEPTED.
    func testSessionsStillStartWhenOneSideReconnectsAfterPressingReady() async throws {
        let pair = try await pair(), snapshots = try snapshots()
        var room = try await pair.apis[0].createBattle(requestId: UUID().uuidString,
            targetTrainerId: pair.grants[1].trainer.trainerId, mode: .manual, snapshot: snapshots[0])
        room = try await pair.apis[1].accept(id: room.battleId, revision: room.revision, snapshot: snapshots[1])
        room = try await pair.apis[0].confirm(id: room.battleId, revision: room.revision)
        let stores = try (0..<2).map { try store($0, snapshot: snapshots[$0], create: true) }
        let live = (0..<2).map { session(pair.grants[$0], snapshot: snapshots[$0], store: stores[$0], transport: NativeHTTP(endpoint)) }
        func waitFor(_ what: String, _ condition: () -> Bool) async throws {
            for _ in 0..<400 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTFail("Timed out waiting for " + what)
            throw OnlineBattleFailure.transport
        }
        for session in live {
            await session.bootstrap(); await session.perform(.setPopoverVisible(true))
            try await waitFor("the first hello") { session.presentation.canStart }
        }
        await live[0].perform(.prepareBattle(room.battleId))
        XCTAssertTrue(live[0].presentation.localReady)
        // A second socket for the same trainer makes the server close the session's one, so its ready no longer counts.
        _ = try await connected(pair.grants[0])
        try await waitFor("the replaced socket") { !live[0].presentation.canStart }
        XCTAssertFalse(live[0].presentation.localReady)
        for connection in connections { await connection.stop() }
        await live[1].perform(.prepareBattle(room.battleId))
        let waiting = try await pair.apis[1].battle(id: room.battleId)
        XCTAssertEqual(waiting.state, .accepted, "The server must not count the ready of a socket that is gone")
        await live[0].perform(.setPopoverVisible(false)); await live[0].perform(.setPopoverVisible(true))
        try await waitFor("both sides in the match") { live.allSatisfy { $0.presentation.room?.state == .running } }
        XCTAssertEqual(live[0].presentation.phase, .arena)
        XCTAssertEqual(live[1].presentation.phase, .arena)
    }
    func testSessionsRecoverCommittedResponseLossAndApplyDurablyOnce() async throws {
        let pair = try await pair(), snapshots = try snapshots()
        let initial = try await running(pair, mode: .manual, snapshots: snapshots)
        let stores = try (0..<2).map { try store($0, snapshot: snapshots[$0], create: true) }
        let transports = [NativeHTTP(endpoint), NativeHTTP(endpoint)]
        for transport in transports { await transport.dropCompletedReportAndDisconnect() }
        let live = (0..<2).map { session(pair.grants[$0], snapshot: snapshots[$0], store: stores[$0], transport: transports[$0]) }
        for session in live { await session.bootstrap(); await session.perform(.setPopoverVisible(true)) }
        for store in stores {
            XCTAssertTrue(store.state.onlineBattleReceipts.isEmpty)
            XCTAssertEqual(store.state.onlineBattleHolds.count, 1)
            XCTAssertEqual(store.state.active?.usedAtStage, 1_000_000)
            assertUnchangedEconomy(store)
        }
        var room = initial
        for _ in 0..<200 {
            for session in live { await session.refresh() }
            room = try await pair.apis[0].battle(id: room.battleId)
            if room.state == .completed { break }
            for session in live {
                if let request = session.presentation.request, request.kind == "move",
                   let slot = request.moves.first(where: { !$0.disabled && $0.pp > 0 })?.slot {
                    await session.perform(.chooseMove(slot))
                }
            }
        }
        room = try await pair.apis[0].battle(id: initial.battleId)
        XCTAssertEqual(room.state, .completed)
        let counts = [await transports[0].committedDrops, await transports[1].committedDrops]
        XCTAssertEqual(counts.reduce(0, +), 1, "The response must disappear only AFTER workerd commits completion")
        for i in 0..<2 where counts[i] == 1 {
            XCTAssertTrue(stores[i].state.onlineBattleReceipts.isEmpty, "Disconnected client must await authoritative recovery")
            XCTAssertEqual(stores[i].state.active?.usedAtStage, 1_000_000)
        }
        for session in live { await session.setEnabled(false) }
        for i in 0..<2 {
            let reopened = try store(i, snapshot: snapshots[i], create: false)
            let restored = session(pair.grants[i], snapshot: snapshots[i], store: reopened, transport: NativeHTTP(endpoint))
            await restored.bootstrap(); await restored.refresh(); await restored.refresh()
            let receipt = try XCTUnwrap(reopened.state.onlineBattleReceipts.first)
            XCTAssertEqual(reopened.state.onlineBattleReceipts.count, 1)
            XCTAssertEqual(receipt.key.battleID, room.battleId)
            let winner = try XCTUnwrap(room.result).winner
            let won = winner.rawValue == (i == 0 ? "p1" : "p2")
            XCTAssertEqual(receipt.grantedXP, won ? 10_000_000 : 0)
            XCTAssertEqual(reopened.state.active?.usedAtStage, 1_000_000 + receipt.grantedXP)
            XCTAssertFalse(reopened.isHeldForBattle(instanceID: snapshots[i].instanceId))
            if !won && winner != .draw { XCTAssertEqual(reopened.healthShare(of: snapshots[i].instanceId), 0) }
            assertUnchangedEconomy(reopened)
            await restored.setEnabled(false)
            let secondRestart = try store(i, snapshot: snapshots[i], create: false)
            XCTAssertEqual(secondRestart.state.onlineBattleReceipts, reopened.state.onlineBattleReceipts)
            XCTAssertEqual(secondRestart.state.active?.usedAtStage, reopened.state.active?.usedAtStage)
            XCTAssertEqual(secondRestart.state.battleHealth, reopened.state.battleHealth)
        }
    }
    func testSessionsReleaseVoidWithoutHealthXPWalletOrUsageEffects() async throws {
        let pair = try await pair(), snapshots = try snapshots()
        let initial = try await running(pair, mode: .manual, snapshots: snapshots)
        let (terminal, report) = try await terminal(initial, pair: pair)
        let reported = try await pair.apis[0].report(id: terminal.battleId, report: report)
        XCTAssertEqual(reported.state, .reported)
        let stores = try (0..<2).map { try store($0, snapshot: snapshots[$0], create: true) }
        for i in 0..<2 {
            let scope = OnlineBattleScope(originHash: try OnlineBattleOrigin(NativeEndpoint.productOrigin).hash,
                groupID: pair.grants[i].group.groupId, trainerID: pair.grants[i].trainer.trainerId)
            try stores[i].holdOnlineBattle(key: .init(scope: scope, battleID: reported.battleId), instanceID: snapshots[i].instanceId)
        }
        // Only p1 reconnects while the other result is missing. Its repeated report cannot settle.
        let first = session(pair.grants[0], snapshot: snapshots[0], store: stores[0], transport: NativeHTTP(endpoint))
        await first.bootstrap(); await first.refresh()
        let waiting = try await pair.apis[0].battle(id: terminal.battleId)
        XCTAssertEqual(waiting.state, .reported)
        XCTAssertTrue(stores[0].state.onlineBattleReceipts.isEmpty)
        XCTAssertEqual(stores[0].state.onlineBattleHolds.count, 1)
        XCTAssertEqual(stores[0].state.active?.usedAtStage, 1_000_000)
        XCTAssertEqual(stores[0].healthShare(of: snapshots[0].instanceId), 1)
        assertUnchangedEconomy(stores[0])
        let mismatch = OnlineBattleReport(readyToken: report.readyToken, engineHash: report.engineHash,
            terminalSeq: report.terminalSeq, winner: report.winner, logHash: String(repeating: "0", count: 64),
            journalHash: report.journalHash, finalHp: report.finalHp)
        let void = try await pair.apis[1].report(id: terminal.battleId, report: mismatch)
        XCTAssertEqual(void.state, .void)
        let second = session(pair.grants[1], snapshot: snapshots[1], store: stores[1], transport: NativeHTTP(endpoint))
        await second.bootstrap()
        for session in [first, second] { await session.refresh() }
        for i in 0..<2 {
            XCTAssertTrue(stores[i].state.onlineBattleHolds.isEmpty)
            XCTAssertTrue(stores[i].state.onlineBattleReceipts.isEmpty)
            XCTAssertEqual(stores[i].healthShare(of: snapshots[i].instanceId), 1)
            XCTAssertEqual(stores[i].state.active?.usedAtStage, 1_000_000)
            assertUnchangedEconomy(stores[i])
            let reopened = try store(i, snapshot: snapshots[i], create: false)
            XCTAssertTrue(reopened.state.onlineBattleHolds.isEmpty)
            XCTAssertTrue(reopened.state.onlineBattleReceipts.isEmpty)
            XCTAssertEqual(reopened.state.battleHealth, stores[i].state.battleHealth)
            XCTAssertEqual(reopened.state.active?.usedAtStage, 1_000_000)
            assertUnchangedEconomy(reopened)
        }
        let standings = try await pair.apis[0].standings()
        XCTAssertEqual(standings.rows.reduce(0) { $0 + $1.wins + $1.losses + $1.draws }, 0)
    }
}
