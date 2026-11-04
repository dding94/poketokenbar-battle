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
    private(set) var committedDrops = 0
    init(_ endpoint: NativeEndpoint) { self.endpoint = endpoint }
    func dropCompletedReportAndDisconnect() { dropCompletion = true }
    func send(_ request: URLRequest) async throws -> OnlineBattleHTTPResponse {
        guard !offline else { throw URLError(.notConnectedToInternet) }
        let response = try await OnlineBattleURLSessionTransport().send(endpoint.rewrite(request))
        // RED scaffold: the integration assertion must detect that no post-commit loss occurred.
        return response
    }
}
private struct NativeSocketDriver: OnlineBattleSocketDriver {
    let endpoint: NativeEndpoint
    func connect(_ request: URLRequest) async throws -> any OnlineBattleSocket {
        try await OnlineBattleURLSessionSocketDriver().connect(endpoint.rewrite(request))
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
    private func snapshots() throws -> [OnlineBattleSnapshot] {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "golden", withExtension: "json", subdirectory: "OnlineBattle"))
        let room = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: file))[0].battle
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
    func testNativeManualAndAutomaticReportsPrivacyReplayAndRematch() async throws {
        let pair = try await pair(), snapshots = try snapshots()
        XCTAssertThrowsError(try OnlineBattleOrigin(endpoint.url.absoluteString), "Product HTTPS policy must remain intact")
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
        _ = try await pair.apis[0].report(id: terminal.battleId, report: report)
        let mismatch = OnlineBattleReport(readyToken: report.readyToken, engineHash: report.engineHash,
            terminalSeq: report.terminalSeq, winner: report.winner, logHash: String(repeating: "0", count: 64),
            journalHash: report.journalHash, finalHp: report.finalHp)
        let void = try await pair.apis[1].report(id: terminal.battleId, report: mismatch)
        XCTAssertEqual(void.state, .void)
        for i in 0..<2 {
            let store = try store(i, snapshot: snapshots[i], create: true)
            let scope = OnlineBattleScope(originHash: try OnlineBattleOrigin(NativeEndpoint.productOrigin).hash,
                groupID: pair.grants[i].group.groupId, trainerID: pair.grants[i].trainer.trainerId)
            try store.holdOnlineBattle(key: .init(scope: scope, battleID: void.battleId), instanceID: snapshots[i].instanceId)
            let session = session(pair.grants[i], snapshot: snapshots[i], store: store, transport: NativeHTTP(endpoint))
            await session.bootstrap(); await session.refresh()
            XCTAssertTrue(store.state.onlineBattleHolds.isEmpty)
            XCTAssertTrue(store.state.onlineBattleReceipts.isEmpty)
            XCTAssertEqual(store.healthShare(of: snapshots[i].instanceId), 1)
            XCTAssertEqual(store.state.active?.usedAtStage, 1_000_000)
            assertUnchangedEconomy(store)
        }
        let standings = try await pair.apis[0].standings()
        XCTAssertEqual(standings.rows.reduce(0) { $0 + $1.wins + $1.losses + $1.draws }, 0)
    }
}
