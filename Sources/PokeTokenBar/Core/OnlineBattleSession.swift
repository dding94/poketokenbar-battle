import Foundation
import CryptoKit
import Observation

/// App-lifetime owner: closing a popover never stops the server clock, replay, or settlement.
@MainActor
final class OnlineBattleSession {
    let presentation = OnlineBattlePresentation()
    private var settings: OnlineBattleSettings
    private let credentials: any OnlineBattleCredentialStoring
    private let transport: any OnlineBattleHTTPTransport
    private let effects: any OnlineBattleEffects
    private let engineFactory: () throws -> BattleEngine
    private let connectionFactory: (@escaping OnlineBattleConnection.Observer) -> any OnlineBattleConnecting
    private let saveSettings: (OnlineBattleSettings) throws -> Void
    private let rosterProvider: (() throws -> [PracticeCandidate])?
    private let clock: OnlineBattleConnectionClock
    private let automaticTicks: Bool
    private var enabled: Bool
    private let accessAllowed: () -> Bool
    private let localization: @MainActor () -> L
    private var onlineAllowed: Bool { enabled && accessAllowed() }
    private var refreshAgain = false
    private var prepared: [String: Int] = [:]
    private var acknowledgedStarts = Set<String>()
    private var submittedReports = Set<String>()
    private var nextRecoveryRead: TimeInterval?
    /// Battles this connection already pressed "ready" for at their current revision. The server view does not expose it.
    func preparedBattleIDs() -> Set<String> {
        var ids = Set(presentation.battles.filter { prepared[$0.battleId] == $0.revision }.map(\.battleId))
        if let room = presentation.room, prepared[room.battleId] == room.revision { ids.insert(room.battleId) }
        return ids
    }
    private struct RoundWork: Hashable {
        let generation: UInt64
        let battleID: String
        let readyToken: String
        let seq: Int
    }
    private var advancing = Set<RoundWork>()
    private var reporting = Set<RoundWork>()
    private var fallback: [String: (work: RoundWork, due: TimeInterval)] = [:]
    private var fallbackTasks: [String: Task<Void, Never>] = [:]
    private var battleReads = Set<String>()
    private var battleReadAgain = Set<String>()
    private var battleRecovery: [String: TimeInterval] = [:]
    private var api: OnlineBattleAPI?
    private var origin: OnlineBattleOrigin?
    private var connection: (any OnlineBattleConnecting)?
    private var bootstrapped = false
    private var authenticated = false
    private var generation: UInt64 = 0
    private var pendingGrant: OnlineBattleGrant?
    private var standingsTask: Task<Void, Never>?
    private var standingsAgain = false
    private var standingsRevision: UInt64 = 0
    private var rematchFromHistory = false
    private var refreshTask: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var actionInFlight = false
    private var reconciled = false
    private var popoverOpen = false
    private var views: [String: OnlineBattleView] = [:]
    /// Display-only terminal records, including those not yet verified for settlement.
    private var historyViews: [String: OnlineBattleView] = [:]
    private var resolvers: [String: OnlineBattleResolver] = [:]
    private var resultByBattleID: [String: OnlineBattleUIResult] = [:]
    /// The display of each battle. It outlives the popover's views and, for a final beat, the resolver.
    private var stagings: [String: OnlineBattleStaging] = [:]
    private var onlineScreenVisible = false
    private var stageDriver: Task<Void, Never>?
    private var prefersLobby = false
    private var navigationRevision: UInt64 = 0
    private var selectedBattleID: String?
    private var checkedDeadlines: [String: Double] = [:]
    private struct ChallengeIntent {
        let sourceID: String?
        let requestID: String
        let target: String
        let mode: OnlineBattleMode
        let snapshot: OnlineBattleSnapshot
    }
    private var challengeIntent: ChallengeIntent?

    init(settings: OnlineBattleSettings, credentials: any OnlineBattleCredentialStoring,
         transport: any OnlineBattleHTTPTransport = OnlineBattleURLSessionTransport(), effects: any OnlineBattleEffects,
         engineFactory: @escaping () throws -> BattleEngine,
         connectionFactory: @escaping (@escaping OnlineBattleConnection.Observer) -> any OnlineBattleConnecting,
         saveSettings: @escaping (OnlineBattleSettings) throws -> Void = { _ in },
         rosterProvider: (() throws -> [PracticeCandidate])? = nil,
         clock: OnlineBattleConnectionClock = .init(), automaticTicks: Bool = true, enabled: Bool = true, accessAllowed: @escaping () -> Bool = { true },
         localization: @escaping @MainActor () -> L = { L(.ko) }) {
        self.settings = settings; self.credentials = credentials; self.transport = transport
        self.effects = effects; self.engineFactory = engineFactory; self.connectionFactory = connectionFactory
        self.saveSettings = saveSettings; self.rosterProvider = rosterProvider
        self.clock = clock; self.automaticTicks = automaticTicks
        self.enabled = enabled; self.accessAllowed = accessAllowed; self.localization = localization
        presentation.serverAddress = settings.serverURL ?? ""
        presentation.serverIsEmbedded = settings.serverIsEmbedded
        presentation.setupInput.server = presentation.serverAddress
        presentation.onAction = { [weak self] action in Task { await self?.perform(action) } }
    }
    func setEnabled(_ value: Bool) async {
        guard value != enabled || (value && !bootstrapped) else { return }
        enabled = value
        if value { await bootstrap(); return }
        presentation.clearSetupCodes()
        generation &+= 1
        refreshTask?.cancel(); refreshTask = nil; refreshAgain = false
        ticker?.cancel(); ticker = nil
        let old = connection, oldAPI = api; connection = nil
        authenticated = false; reconciled = false; bootstrapped = false; actionInFlight = false
        pendingGrant = nil; challengeIntent = nil; prepared = [:]; acknowledgedStarts = []; submittedReports = []
        for resolver in resolvers.values { resolver.close() }; resolvers = [:]; views = [:]; historyViews = [:]; dropStagings()
        selectedBattleID = nil; resultByBattleID = [:]; prefersLobby = false; checkedDeadlines = [:]; nextRecoveryRead = nil
        presentation.account = nil; presentation.members = []; presentation.battles = []
        resetBattleRuntime(); resetExtras(); clearHistory(); presentation.liveLogs = []
        presentation.room = nil; presentation.arena = nil; presentation.request = nil
        presentation.recoveryCode = nil; presentation.result = nil; presentation.canRetryCredentialSave = false
        presentation.canStart = false; presentation.isBusy = false; presentation.phase = .setup
        presentation.connectionStatus = "키체인 접근이 꺼져 있어 온라인 배틀을 중단했어요"
        await oldAPI?.setAccessKey(nil)
        await old?.stop()
    }
    /// Notification delivery never waits for a whole battle. Changes during a read retain one follow-up read.
    func requestRefresh() {
        guard onlineAllowed, authenticated else { return }
        if refreshTask != nil { refreshAgain = true; requestStandingsRefresh() }
        else { Task { [weak self] in await self?.refresh() } }
    }
    func bootstrap() async {
        guard onlineAllowed else { presentation.connectionStatus = "키체인 접근이 꺼져 있어요"; return }
        guard !bootstrapped else { return }
        bootstrapped = true
        let epoch = generation
        do {
            try rebuildRoster()
            guard let address = settings.serverURL else { return }
            let origin = try OnlineBattleOrigin(address)
            self.origin = origin; api = OnlineBattleAPI(origin: origin, transport: transport)
            let key = try await credentials.load(scope: .init(profileID: settings.profileID, origin: origin))
            try current(epoch)
            guard let key else { presentation.connectionStatus = "접속 정보가 필요해요"; return }
            try await activate(key, epoch: epoch)
            await refresh()
        } catch { await handle(error, epoch: epoch) }
    }
    func configureServer(_ value: String) async {
        do {
            var next = settings; try next.setServer(value); try saveSettings(next)
            generation &+= 1
            refreshTask?.cancel(); refreshTask = nil; ticker?.cancel(); ticker = nil
            let old = connection; connection = nil
            for resolver in resolvers.values { resolver.close() }
            dropStagings()
            resolvers = [:]; views = [:]; historyViews = [:]; selectedBattleID = nil; resultByBattleID = [:]; prefersLobby = false; checkedDeadlines = [:]
            api = nil; origin = nil; pendingGrant = nil; challengeIntent = nil
            authenticated = false; reconciled = false; actionInFlight = false
            refreshAgain = false; prepared = [:]; acknowledgedStarts = []; submittedReports = []; nextRecoveryRead = nil
            if settings.serverURL != nil, settings.serverURL != next.serverURL {
                presentation.setupInput.recovery = ""; presentation.setupInput.reconnect = ""
            }
            settings = next; bootstrapped = false
            presentation.serverAddress = next.serverURL ?? ""
            presentation.account = nil; presentation.members = []; presentation.battles = []
            resetBattleRuntime(); resetExtras(); clearHistory(); presentation.liveLogs = []
            presentation.room = nil; presentation.arena = nil; presentation.request = nil
            presentation.result = nil; presentation.recoveryCode = nil; presentation.notice = nil
            presentation.canRetryCredentialSave = false; presentation.canStart = false
            presentation.phase = .setup; presentation.isBusy = false
            await old?.stop()
            await bootstrap()
        } catch { await handle(error, epoch: generation) }
    }
    private func current(_ epoch: UInt64) throws {
        guard onlineAllowed, epoch == generation, !Task.isCancelled else { throw OnlineBattleFailure.staleGeneration }
    }
    private func activate(_ key: String, epoch: UInt64) async throws {
        guard let api else { throw OnlineBattleFailure.invalidSettings }
        await api.setAccessKey(key); try current(epoch)
        authenticated = true
        let connection = connectionFactory { [weak self] event in await self?.connectionEvent(event, epoch: epoch) }
        self.connection = connection
        await connection.configure(origin: origin, accessKey: key); try current(epoch)
        await connection.setPopoverOpen(popoverOpen); try current(epoch)
        if automaticTicks, ticker == nil {
            let clock = clock
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await clock.sleep(1) } catch { return }
                    guard !Task.isCancelled else { return }
                    await self?.tick()
                }
            }
        }
    }
    private func connectionEvent(_ event: OnlineBattleConnectionEvent, epoch: UInt64) async {
        guard epoch == generation else { return }
        switch event {
        case .changed(let snapshot):
            guard let connection, snapshot == (await connection.snapshot()), epoch == generation else { return }
            presentation.canStart = snapshot.state == .connected
            switch snapshot.state {
            case .unconfigured: presentation.connectionStatus = "서버 주소를 설정해 주세요"
            case .credentialsRequired: presentation.connectionStatus = "접속 정보가 필요해요"
            case .connecting: presentation.connectionStatus = "연결 중"
            case .connected: presentation.connectionStatus = "접속 중"
            case .retryWaiting: presentation.connectionStatus = "다시 연결할 때까지 기다리고 있어요"
            case .polling: presentation.connectionStatus = "화면을 열 때 경기 정보를 확인해요"
            case .replaced: presentation.connectionStatus = "다른 기기에서 연결했어요. 다시 열면 연결해요"
            case .revoked:
                await revoke(epoch: epoch); return
            case .protocolError: presentation.connectionStatus = "서버와 앱 버전을 확인해 주세요"
            }
        case .refreshRequested:
            requestRefresh()
        case .standingsRefreshRequested:
            requestStandingsRefresh()
        case .battleNotification(let snapshot, let id, let payload):
            guard let connection, snapshot == (await connection.snapshot()), epoch == generation,
                  snapshot.state == .connected, let account = presentation.account,
                  snapshot.trainerId == account.trainer.trainerId, snapshot.groupId == account.group.groupId else { return }
            await consumeNotification(payload, battleID: id, account: account, epoch: epoch)
        }
    }
    private struct BattleNotice: Decodable {
        let type: String
        let state: OnlineBattleState?
        let revision: Int?
        let roundSeq: Int?
        let deadline: Double?
        let pair: OnlineBattlePair?
        let hasDeadline: Bool
        private enum CodingKeys: String, CodingKey { case type, state, revision, roundSeq, deadline, pair }
        init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: CodingKeys.self)
            type = try box.decode(String.self, forKey: .type)
            state = try box.decodeIfPresent(OnlineBattleState.self, forKey: .state)
            revision = try box.decodeIfPresent(Int.self, forKey: .revision)
            roundSeq = try box.decodeIfPresent(Int.self, forKey: .roundSeq)
            deadline = try box.decodeIfPresent(Double.self, forKey: .deadline)
            pair = try box.decodeIfPresent(OnlineBattlePair.self, forKey: .pair)
            hasDeadline = box.contains(.deadline)
        }
    }
    private func consumeNotification(_ payload: Data, battleID id: String, account: OnlineBattleAccount, epoch: UInt64) async {
        guard onlineAllowed, authenticated, let api else { return }
        guard let notice = try? JSONDecoder().decode(BattleNotice.self, from: payload) else {
            await readBattle(id, epoch: epoch); return
        }
        // Mismatch announcements also go to nonparticipants; they contain no result to reconcile.
        if notice.type == "battle_void", views[id] == nil { return }
        guard let room = views[id], room.side(for: account.trainer.trainerId) != nil else {
            await readBattle(id, epoch: epoch); return
        }
        // HTTP may have already consumed these buffered notifications, including an entire auto match.
        if notice.type == "battle_round", let pair = notice.pair, pair.roundSeq > 0, pair.roundSeq <= room.journal.count {
            if room.journal[pair.roundSeq - 1] != pair { await readBattle(id, epoch: epoch) }
            return
        }
        if notice.type == "battle_changed", notice.revision == room.revision {
            if !room.state.isActive { return }
            if room.state == .reported, notice.state == .running || notice.state == .reported { return }
        }
        guard room.state == .running, room.config != nil, let resolver = resolvers[id] else {
            await readBattle(id, epoch: epoch); return
        }
        do {
            if notice.type == "battle_round", let pair = notice.pair {
                guard (1...200).contains(pair.roundSeq), pair.releasedAt.isFinite, pair.releasedAt >= 0,
                      [pair.p1, pair.p2].allSatisfy({ token in
                          switch token {
                          case .move(let slot): return room.mode == .manual && (1...4).contains(slot)
                          case .timeout: return room.mode == .manual
                          case .policy: return room.mode == .auto
                          }
                      }) else { await readBattle(id, epoch: epoch); return }
                guard pair.roundSeq == room.journal.count + 1,
                      resolver.processedRoundSeq == room.journal.count,
                      pair.roundSeq == room.roundSeq || pair.roundSeq == room.roundSeq + 1 else {
                    await readBattle(id, epoch: epoch); return
                }
                let updated = room.relayView(roundSeq: max(room.roundSeq, pair.roundSeq),
                    deadline: nil,
                    ownChoice: nil, journal: room.journal + [pair])
                try await process(updated, account: account, api: api, epoch: epoch)
                return
            }
            if notice.type == "battle_changed", notice.state == .running, notice.revision == room.revision, notice.hasDeadline,
               let seq = notice.roundSeq, (1...200).contains(seq) {
                // Earlier open/closed messages can arrive behind our own newer HTTP response.
                if seq < room.roundSeq { return }
                if seq == room.roundSeq {
                    if seq <= room.journal.count || notice.deadline == room.deadline { return }
                }
                if room.mode == .manual, seq == room.roundSeq + 1, seq == resolver.processedRoundSeq + 1,
                   let deadline = notice.deadline, deadline.isFinite, deadline <= 9_007_199_254_740_991,
                   let releasedAt = room.journal.last?.releasedAt, deadline > releasedAt {
                    views[id] = room.relayView(roundSeq: seq, deadline: deadline, ownChoice: nil, journal: room.journal)
                    cancelFallback(id); publish(); return
                }
            }
            // Legacy, missing, changed, expired and terminal notifications all require HTTP proof.
            await readBattle(id, epoch: epoch)
        } catch {
            await readBattle(id, epoch: epoch)
        }
    }
    private func readBattle(_ id: String, epoch: UInt64) async {
        guard epoch == generation, onlineAllowed, authenticated, let api, let account = presentation.account else { return }
        if battleReads.contains(id) { battleReadAgain.insert(id); return }
        battleReads.insert(id)
        defer { if epoch == generation { battleReads.remove(id) } }
        repeat {
            battleReadAgain.remove(id)
            do {
                let room = try await api.battle(id: id); try current(epoch)
                try await process(room, account: account, api: api, epoch: epoch)
                try current(epoch); battleRecovery[id] = nil; try rebuildRoster(); publish()
            } catch {
                guard epoch == generation else { return }
                await handle(error, epoch: epoch)
                // Battle recovery stays scoped even when the general error path arms a full read.
                nextRecoveryRead = nil; battleRecovery[id] = clock.now() + 5
                return
            }
        } while battleReadAgain.contains(id) && epoch == generation
    }
    private func cancelFallback(_ id: String) {
        fallback[id] = nil; fallbackTasks.removeValue(forKey: id)?.cancel()
    }
    private func scheduleFallback(_ work: RoundWork) {
        guard fallback[work.battleID]?.work != work else { return }
        cancelFallback(work.battleID)
        fallback[work.battleID] = (work, clock.now() + 2)
        guard automaticTicks else { return }
        let clock = clock
        fallbackTasks[work.battleID] = Task { [weak self] in
            do { try await clock.sleep(2) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.resumeFallback(work)
        }
    }
    private func resumeFallback(_ work: RoundWork) async {
        guard work.generation == generation, onlineAllowed, authenticated,
              fallback[work.battleID]?.work == work,
              let room = views[work.battleID], room.state == .running,
              room.roundSeq == work.seq, room.config?.readyToken == work.readyToken,
              let api, let account = presentation.account else { return }
        fallback[work.battleID] = nil; fallbackTasks[work.battleID] = nil
        do { try await process(room, account: account, api: api, epoch: work.generation, fallbackWork: work) }
        catch {
            await handle(error, epoch: work.generation)
            if work.generation == generation { nextRecoveryRead = nil; battleRecovery[work.battleID] = clock.now() + 5 }
        }
    }
    func join(inviteCode: String, email: String) async {
        await obtainGrant { try await $0.join(inviteCode: inviteCode, displayEmail: email) }
    }
    private func obtainGrant(_ request: (OnlineBattleAPI) async throws -> OnlineBattleGrant) async {
        guard onlineAllowed, let api, let origin, pendingGrant == nil else { return }
        var epoch = generation
        do {
            // Recovery revokes the old WebSocket before its HTTP grant arrives. Its credential
            // generation must not invalidate this unauthenticated, one-use grant response.
            let grantAPI = OnlineBattleAPI(origin: origin, transport: transport)
            let grant = try await request(grantAPI); try current(epoch)
            // A grant replaces credentials even at the same origin. Retire all work before any await.
            generation &+= 1; epoch = generation
            refreshTask?.cancel(); refreshTask = nil; refreshAgain = false
            ticker?.cancel(); ticker = nil
            let old = connection; connection = nil
            authenticated = false; reconciled = false
            for resolver in resolvers.values { resolver.close() }
            dropStagings()
            resolvers = [:]; views = [:]; historyViews = [:]; resultByBattleID = [:]
            selectedBattleID = nil; prefersLobby = false; checkedDeadlines = [:]; nextRecoveryRead = nil
            prepared = [:]; acknowledgedStarts = []; submittedReports = []; challengeIntent = nil
            presentation.account = nil; presentation.members = []; presentation.battles = []
            resetBattleRuntime(); resetExtras(); clearHistory(); presentation.liveLogs = []
            presentation.room = nil; presentation.arena = nil; presentation.request = nil
            presentation.result = nil; presentation.recoveryCode = nil; presentation.canStart = false
            presentation.phase = .setup
            pendingGrant = grant; presentation.canRetryCredentialSave = true
            await api.setAccessKey(nil)
            await old?.stop(); try current(epoch)
            await retryCredentialSave()
        } catch { await handle(error, epoch: epoch) }
        if epoch == generation { actionInFlight = false; presentation.isBusy = false }
    }
    func retryCredentialSave() async {
        guard onlineAllowed, let grant = pendingGrant, let origin else { return }
        let epoch = generation
        do {
            try await credentials.save(grant.accessKey, scope: .init(profileID: settings.profileID, origin: origin))
            try current(epoch)
            pendingGrant = nil; presentation.canRetryCredentialSave = false
            presentation.clearSetupCodes(); presentation.setupInput.nickname = ""
            presentation.account = grant.account; presentation.recoveryCode = grant.recoveryCode; presentation.notice = nil
            try await activate(grant.accessKey, epoch: epoch)
            await refresh()
        } catch { await handle(error, epoch: epoch) }
    }
    /// One shared read owns reconciliation. Notifications never apply effects directly.
    func refresh() async {
        guard onlineAllowed, authenticated, let api else { return }
        requestStandingsRefresh()
        if let refreshTask { await refreshTask.value; return }
        let epoch = generation
        let task = Task { [weak self] in
            guard let self else { return }
            repeat {
                self.refreshAgain = false
                await self.readAll(api: api, epoch: epoch)
            } while self.refreshAgain && self.generation == epoch && self.onlineAllowed && self.authenticated
        }
        refreshTask = task
        await task.value
        if epoch == generation { refreshTask = nil }
    }
    private func readAll(api: OnlineBattleAPI, epoch: UInt64) async {
        do {
            let account = try await api.me(); try current(epoch)
            guard account.trainer.status == .active else { throw OnlineBattleFailure.unauthorized }
            let group = try await api.group(); try current(epoch)
            guard group.group.groupId == account.group.groupId else { throw OnlineBattleFailure.invalidResponse }
            var battles = try await api.listBattles(); try current(epoch)
            let scope = try scope(account)
            let ids = Set(battles.map(\.battleId))
            for hold in effects.companionState()?.state.onlineBattleHolds ?? [] where hold.key.scope == scope && !ids.contains(hold.key.battleID) {
                let room = try await api.battle(id: hold.key.battleID); try current(epoch); battles.append(room)
            }
            if let old = presentation.account, old.trainer.trainerId != account.trainer.trainerId || old.group.groupId != account.group.groupId {
                throw OnlineBattleFailure.unauthorized
            }
            if presentation.account == nil { presentation.clearSetupCodes() }
            presentation.account = account; presentation.members = group.members
            historyViews = [:]
            for room in battles where !room.state.isActive && room.side(for: account.trainer.trainerId) != nil {
                historyViews[room.battleId] = room
            }
            // An ended-challenge notice stays until the person closes it; error notices are re-evaluated.
            if !presentation.noticeSurvivesRefresh { presentation.notice = nil }
            try rebuildRoster()
            // Old unapplied completions are reconciled before accepting new entries or acquiring newer holds.
            for room in battles.sorted(by: { ($0.state == .completed ? 0 : 1, $0.createdAt) < ($1.state == .completed ? 0 : 1, $1.createdAt) }) {
                try current(epoch)
                try await process(room, account: account, api: api, epoch: epoch)
            }
            try current(epoch); reconciled = true
            try rebuildRoster(); _ = try await reconcileRematchIntent(account: account, api: api, epoch: epoch); publish()
            if let connection { let snapshot = await connection.snapshot(); try current(epoch); presentation.canStart = snapshot.state == .connected }
        } catch {
            guard epoch == generation, onlineAllowed else { return }
            reconciled = false
            // Do not republish cached rows after revocation or move unfinished onboarding to the lobby.
            // Only an authenticated account can expose the separately fetched archive summaries.
            if authenticated, presentation.account != nil { publish() }
            await handle(error, epoch: epoch)
        }
    }
    private func scope(_ account: OnlineBattleAccount) throws -> OnlineBattleScope {
        guard let origin else { throw OnlineBattleFailure.invalidSettings }
        return .init(originHash: origin.hash, groupID: account.group.groupId, trainerID: account.trainer.trainerId)
    }
    private func receiptKey(_ room: OnlineBattleView, account: OnlineBattleAccount) throws -> OnlineBattleReceiptKey {
        .init(scope: try scope(account), battleID: room.battleId)
    }
    private func accepts(_ room: OnlineBattleView) -> Bool {
        guard let old = views[room.battleId] else { return true }
        guard room.revision >= old.revision else { return false }
        if !old.state.isActive { return !room.state.isActive && room.state == old.state }
        guard room.revision == old.revision else { return true }
        let rank: [OnlineBattleState: Int] = [.pending: 0, .accepted: 1, .ready: 2, .running: 3, .reported: 4]
        if let before = rank[old.state], let after = rank[room.state], after < before { return false }
        guard room.roundSeq >= old.roundSeq, room.journal.count >= old.journal.count else { return false }
        if room.roundSeq == old.roundSeq, old.ownChoice != nil, room.ownChoice == nil, room.journal.count == old.journal.count { return false }
        return true
    }
    private func process(_ initial: OnlineBattleView, account: OnlineBattleAccount, api: OnlineBattleAPI, epoch: UInt64, fallbackWork: RoundWork? = nil) async throws {
        var room = initial
        var refetched = false
        // An automatic battle has at most 200 public pairs. Each response must make progress.
        for _ in 0..<202 {
            try current(epoch)
            let previousView = views[room.battleId]
            guard accepts(room) else { return }
            guard let side = room.side(for: account.trainer.trainerId) else { throw OnlineBattleFailure.invalidResponse }
            views[room.battleId] = room
            if let pending = fallback[room.battleId], room.state != .running || room.roundSeq > pending.work.seq {
                cancelFallback(room.battleId)
            }
            let key = try receiptKey(room, account: account)
            if [.void, .cancelled, .declined, .expired].contains(room.state) {
                try effects.releaseOnlineBattle(key: key)
                resolvers.removeValue(forKey: room.battleId)?.close()
                presentation.announceEnded(room, previous: previousView?.state, l: localization())
                stagings.removeValue(forKey: room.battleId)?.skipToEnd()
                if room.state == .void {
                    resultByBattleID[room.battleId] = .init(title: "경기 무효", detail: "체력과 경험치는 바뀌지 않았어요.", xpAwarded: 0, hpApplied: false, isVoid: true)
                }
                publish(); return
            }
            if room.state == .completed {
                try settle(room, account: account); resolvers.removeValue(forKey: room.battleId)?.close(); publish(); return
            }
            if let own = side == .p1 ? room.p1.snapshot : room.p2.snapshot {
                guard presentation.roster.contains(where: { $0.id == own.instanceId }) else { throw OnlineBattleFailure.invalidResponse }
                try effects.holdOnlineBattle(key: key, instanceID: own.instanceId)
            }
            guard [.ready, .running, .reported].contains(room.state) else { publish(); return }
            let resolver: OnlineBattleResolver
            if let existing = resolvers[room.battleId] { resolver = existing }
            else {
                resolver = try OnlineBattleResolver(battle: room, localTrainerID: account.trainer.trainerId, engine: engineFactory())
                resolvers[room.battleId] = resolver
            }
            do { try resolver.consume(journal: room.journal) }
            catch OnlineBattleResolver.Failure.needsRefetch {
                guard !refetched else { throw OnlineBattleResolver.Failure.invalidJournal }
                refetched = true
                resolver.close(); resolvers[room.battleId] = nil
                stagings[room.battleId]?.markResync()
                // One authoritative refetch and a fresh engine, then fail closed if the server remains invalid.
                let fresh = try await api.battle(id: room.battleId); try current(epoch)
                guard views[room.battleId] == room else { return }
                let rebuilt = try OnlineBattleResolver(battle: fresh, localTrainerID: account.trainer.trainerId, engine: engineFactory())
                do { try rebuilt.consume(journal: fresh.journal) } catch { rebuilt.close(); throw error }
                // The rejected journal is not a trusted monotonic baseline for this authoritative read.
                views[room.battleId] = nil
                resolvers[room.battleId] = rebuilt; room = fresh; continue
            }
            // Every consumed round passes here: WebSocket, read and fallback alike.
            ingestStage(room, resolver: resolver)
            publish()
            if room.state == .ready, prepared[room.battleId] == room.revision, let connection {
                let snapshot = await connection.snapshot(); try current(epoch)
                guard snapshot.state == .connected, snapshot.trainerId == account.trainer.trainerId,
                      snapshot.groupId == account.group.groupId, let connectionID = snapshot.connectionId else { return }
                let acknowledgement = room.battleId + ":" + connectionID
                guard !acknowledgedStarts.contains(acknowledgement) else { return }
                let updated = try await api.start(id: room.battleId, revision: room.revision, connectionId: connectionID,
                                                 readyToken: room.config!.readyToken, engineHash: BattleEngineManifest.sha256)
                try current(epoch); acknowledgedStarts.insert(acknowledgement)
                guard updated != room else { return }
                room = updated; continue
            }
            guard room.state == .running || room.state == .reported else { return }
            if let report = try resolver.terminalReport() {
                let reportKey = room.battleId + ":" + report.readyToken
                if room.state == .reported, submittedReports.contains(reportKey) { return }
                // Sending the identical deterministic report is safe after a response was lost.
                let work = RoundWork(generation: epoch, battleID: room.battleId, readyToken: report.readyToken, seq: report.terminalSeq)
                guard reporting.insert(work).inserted else { return }
                let updated: OnlineBattleView
                do { updated = try await api.report(id: room.battleId, report: report); reporting.remove(work) }
                catch { reporting.remove(work); throw error }
                try current(epoch)
                submittedReports.insert(reportKey)
                guard accepts(updated) else { return }
                if updated == room { return }
                room = updated
                if room.state == .reported { views[room.battleId] = room; publish(); return }
                continue
            }
            guard room.state == .running, resolver.processedRoundSeq == room.roundSeq, room.roundSeq > 0 else { return }
            let work = RoundWork(generation: epoch, battleID: room.battleId, readyToken: room.config!.readyToken, seq: resolver.processedRoundSeq)
            if side == .p2, fallbackWork != work { scheduleFallback(work); return }
            guard advancing.insert(work).inserted else { return }
            let updated: OnlineBattleView
            do { updated = try await api.advance(id: room.battleId, processedRoundSeq: resolver.processedRoundSeq); advancing.remove(work) }
            catch { advancing.remove(work); throw error }
            try current(epoch)
            guard updated != room else { return }
            room = updated
        }
        throw OnlineBattleFailure.invalidResponse
    }
    private func settle(_ battle: OnlineBattleView, account: OnlineBattleAccount) throws {
        let key = try receiptKey(battle, account: account)
        if let state = effects.companionState()?.state,
           let receipt = state.onlineBattleReceipts.first(where: { $0.key == key }) {
            guard state.onlineLedgerTrusted, let report = battle.result else { throw OnlineBattleEffectError.untrustedLedger }
            let hash = SHA256.hash(data: Data(try BattleJSON.encode(report).utf8)).map { String(format: "%02x", $0) }.joined()
            guard receipt.resultHash == hash else { throw OnlineBattleEffectError.conflictingResult }
            let side = battle.side(for: account.trainer.trainerId)
            let outcome: OnlineBattleOutcome = report.winner == .draw ? .draw : report.winner.rawValue == side?.rawValue ? .win : .loss
            showResult(receipt, outcome: outcome)
            return
        }
        guard let hash = battle.config?.engineHash else { throw OnlineBattleFailure.invalidResponse }
        let resolver = try OnlineBattleResolver.completedResolver(battle: battle, localTrainerID: account.trainer.trainerId,
                                                                  engine: completedEngine(hash: hash))
        defer { resolver.close() }
        let proof = try resolver.verifyCompleted(battle)
        guard presentation.roster.contains(where: { $0.id == proof.localInstanceID }) else { throw OnlineBattleFailure.invalidResponse }
        let outcome: OnlineBattleOutcome = proof.winner == .draw ? .draw : proof.winner.rawValue == proof.localSide.rawValue ? .win : .loss
        let receipt = try effects.applyVerifiedOnlineBattleEffect(.init(key: receiptKey(battle, account: account), resultHash: proof.resultHash,
            localInstanceID: proof.localInstanceID, remainingHPShare: proof.remainingHPShare, outcome: outcome))
        showResult(receipt, outcome: outcome)
    }
    private func showResult(_ receipt: OnlineBattleEffectReceipt, outcome: OnlineBattleOutcome) {
        resultByBattleID[receipt.key.battleID] = .init(title: outcome == .win ? "승리" : outcome == .loss ? "패배" : "무승부",
            detail: "양쪽의 전투 결과가 일치해 반영했어요.", xpAwarded: Int64(receipt.grantedXP), hpApplied: true, isVoid: false)
    }
    private func rebuildRoster() throws {
        if let rosterProvider { presentation.roster = try rosterProvider() }
        else if let source = effects.companionState() {
            presentation.roster = PracticeRoster(state: source.state, activeName: source.activeName, engine: try engineFactory()).candidates
        } else { presentation.roster = [] }
        presentation.entryHP = Dictionary(uniqueKeysWithValues: presentation.roster.compactMap { entry in
            guard let maxHP = entry.snapshot?.publicInfo.stats["hp"] else { return nil }
            return (entry.id, Self.hp(share: effects.healthShare(of: entry.id), maxHP: maxHP))
        })
        presentation.blockedEntryIDs = Set(presentation.roster.filter { effects.isHeldForBattle(instanceID: $0.id) }.map(\.id))
        if presentation.selectedEntryID == nil { presentation.selectedEntryID = presentation.roster.first(where: { presentation.entryIsEligible($0) })?.id }
    }
    private static func hp(share: Double, maxHP: Int) -> Int { share <= 0 ? 0 : max(1, Int((min(1, share) * Double(maxHP)).rounded(.down))) }
    private func selectedSnapshot(allow key: OnlineBattleReceiptKey? = nil, id: String? = nil) throws -> OnlineBattleSnapshot {
        try rebuildRoster()
        guard let selected = id ?? presentation.selectedEntryID,
              let candidate = presentation.roster.first(where: { $0.id == selected }), candidate.blockedReason == nil,
              let snapshot = candidate.snapshot, snapshot.engineHash == BattleEngineManifest.sha256,
              let hp = presentation.entryHP[selected], hp > 0 else { throw OnlineBattleFailure.invalidRequest }
        if effects.isHeldForBattle(instanceID: selected) {
            guard let key, effects.companionState()?.state.onlineBattleHolds.contains(where: { $0.key == key && $0.instanceID == selected }) == true else { throw OnlineBattleEffectError.individualHeld }
        }
        return .init(snapshot: snapshot, hp: hp)
    }
    private func validateConsent(_ room: OnlineBattleView, account: OnlineBattleAccount) throws {
        let side = room.side(for: account.trainer.trainerId)
        guard let own = side == .p1 ? room.p1.snapshot : room.p2.snapshot,
              try selectedSnapshot(allow: receiptKey(room, account: account), id: own.instanceId) == own else { throw OnlineBattleFailure.invalidRequest }
    }
    /// The live room on screen. Only processed live views can drive the live room/result; archive summaries cannot settle it.
    private func displayedRoom() -> OnlineBattleView? {
        guard !prefersLobby else { return nil }
        // Only processed live views can drive the live room/result; archive summaries cannot settle it.
        let live = views.values.sorted { ($0.createdAt, $0.battleId) > ($1.createdAt, $1.battleId) }
        // A match in play or being verified outranks a newer request, so a relaunch returns to it.
        let inPlay = live.first(where: { $0.state == .running || $0.state == .reported })
        return selectedBattleID.flatMap { views[$0] } ?? inPlay ?? live.first(where: { $0.state.isActive }) ?? live.first
    }
    private func publish() {
        syncStages()
        var listed = views
        for (id, room) in historyViews { listed[id] = room }
        presentation.battles = listed.values.sorted { ($0.createdAt, $0.battleId) > ($1.createdAt, $1.battleId) }
        let room = displayedRoom()
        let staging = room.flatMap { stagings[$0.battleId] }
        // Progress is already done when this holds; it only keeps the arena up until the last beat ends.
        let holdsArena = staging?.isPlaying == true
        presentation.stage = staging
        presentation.room = room
        presentation.result = room.flatMap { resultByBattleID[$0.battleId] }
        presentation.arena = nil; presentation.request = nil; presentation.deadline = nil
        presentation.choiceSubmitted = false
        presentation.localReady = room.map { prepared[$0.battleId] == $0.revision } ?? false
        presentation.moveSlugs = [:]; presentation.abilitySlugs = [:]
        presentation.liveLogs = []
        guard let room, let account = presentation.account else { presentation.phase = authenticated ? .lobby : .setup; return }
        presentation.localSide = room.side(for: account.trainer.trainerId) ?? .p1
        presentation.deadline = room.deadline.map { Date(timeIntervalSince1970: $0 / 1000) }
        presentation.choiceSubmitted = room.ownChoice != nil
        presentation.arena = resolvers[room.battleId]?.view ?? staging?.lastView
        presentation.request = resolvers[room.battleId]?.request ?? staging?.lastRequest
        presentation.liveLogs = OnlineBattleHistoryText.logs(resolvers[room.battleId]?.logs ?? [], localSide: presentation.localSide)
        publishDisclosedNames(room)
        switch room.state {
        case .pending, .accepted, .ready: presentation.phase = .room
        case .running: presentation.phase = .arena
        case .reported: presentation.phase = holdsArena ? .arena : .verifying
        case .completed: presentation.phase = holdsArena ? .arena : .result
        case .void: presentation.phase = .result
        case .declined, .cancelled, .expired: presentation.phase = .lobby
        }
    }
    private func ingestStage(_ room: OnlineBattleView, resolver: OnlineBattleResolver) {
        let staging: OnlineBattleStaging
        if let existing = stagings[room.battleId] { staging = existing }
        else {
            staging = OnlineBattleStaging(resolver: resolver, clock: clock.now)
            staging.playback.timeScale = presentation.stageSpeed.timeScale
            stagings[room.battleId] = staging
        }
        staging.ingest(resolver, mode: room.mode, visible: stageIsVisible(room.battleId, displayed: displayedRoom()?.battleId),
                       secondsLeft: room.deadline.map { $0 / 1000 - clock.now() })
    }
    private func stageIsVisible(_ id: String, displayed: String?) -> Bool {
        popoverOpen && onlineScreenVisible && id == displayed && presentation.stageSpeed != .instant
            && !presentation.showsHistory && !presentation.showsStandings && presentation.rematchSourceID == nil
    }
    /// A stage nobody can see has nothing to play, so reopening never shows old beats and a held phase lets go.
    private func syncStages() {
        let displayed = displayedRoom()?.battleId
        for (id, staging) in stagings {
            if !stageIsVisible(id, displayed: displayed) { staging.skipToEnd() }
            // A finished battle off screen will never draw again; the one on screen waits for its result to go.
            if id != displayed, let room = views[id], !room.state.isActive { stagings[id] = nil }
        }
        let playing = displayed.flatMap { stagings[$0] }?.isPlaying == true
        if playing, automaticTicks { startStageDriver() } else { stopStageDriver() }
    }
    private func startStageDriver() {
        guard stageDriver == nil else { return }
        let clock = clock
        stageDriver = Task { [weak self] in
            while !Task.isCancelled {
                do { try await clock.sleep(0.1) } catch { return }
                guard !Task.isCancelled else { return }
                self?.tickStage()
            }
        }
    }
    private func stopStageDriver() { stageDriver?.cancel(); stageDriver = nil }
    private func dropStagings() {
        stagings = [:]; presentation.stage = nil
        stopStageDriver()
    }
    /// A visibility change has to reach the phase too, which only `publish()` sets.
    private func refreshStageVisibility() {
        if authenticated, presentation.account != nil { publish() } else { syncStages() }
    }
    /// Moves the beat on screen; the driver calls it every 100 ms and tests call it directly. It also catches
    /// an overlay opened since the last publish. When the last beat ends, a held phase moves on.
    func tickStage() {
        let wasPlaying = stagings.values.contains { $0.isPlaying }
        syncStages()
        displayedRoom().flatMap { stagings[$0.battleId] }?.advance()
        if wasPlaying, !stagings.values.contains(where: { $0.isPlaying }) { refreshStageVisibility() }
    }
    private func publishDisclosedNames(_ room: OnlineBattleView) {
        guard let view = presentation.arena else { return }
        func normalized(_ value: String) -> String { value.lowercased().filter { $0.isLetter || $0.isNumber } }
        for (side, visible, snapshot) in [(OnlineBattleSide.p1, view.p1, room.p1.snapshot), (.p2, view.p2, room.p2.snapshot)] {
            guard let snapshot else { continue }
            var ids = Set(visible.moves)
            if side == presentation.localSide { ids.formUnion(presentation.request?.moves.map(\.id) ?? []) }
            presentation.moveSlugs[side] = Dictionary(uniqueKeysWithValues: ids.compactMap { id in
                snapshot.set.moves.first(where: { normalized($0) == normalized(id) }).map { (id, $0) }
            })
            if let ability = visible.ability, normalized(ability) == normalized(snapshot.set.ability) {
                presentation.abilitySlugs[side] = [ability: snapshot.set.ability]
            }
        }
    }
    func perform(_ action: OnlineBattleUIAction) async {
        switch action {
        case .setPopoverVisible(let open):
            popoverOpen = open
            if open { requestStandingsRefresh() } else { invalidateStandingsRead() }
            // The popover's views are released on close with no guaranteed onDisappear; the screen's onAppear sets it again.
            if !open { onlineScreenVisible = false }
            refreshStageVisibility()
            await connection?.setPopoverOpen(open); return
        case .setOnlineScreenVisible(let visible):
            onlineScreenVisible = visible
            refreshStageVisibility(); return
        case .skipStage:
            presentation.stage?.skipToEnd()
            refreshStageVisibility(); return
        case .setStageSpeed(let speed):
            presentation.stageSpeed = speed
            for staging in stagings.values { staging.playback.timeScale = speed.timeScale }
            refreshStageVisibility(); return
        case .showStandings:
            guard onlineAllowed, authenticated, presentation.account != nil, presentation.phase == .lobby,
                  !actionInFlight, presentation.rematchSourceID == nil else { return }
            clearHistory(); presentation.showsStandings = true
            await refreshStandings(); return
        case .refreshStandings: await refreshStandings(); return
        case .prepareRematch(let id): prepareRematch(id); return
        case .cancelRematch:
            presentation.rematchSourceID = nil
            presentation.showsHistory = rematchFromHistory
            rematchFromHistory = false
            navigationRevision &+= 1
            return
        case .selectEntry(let id):
            if presentation.selectedEntryID != id { challengeIntent = nil }
            presentation.selectedEntryID = id; return
        case .selectOpponent(let id):
            guard presentation.rematchSourceID == nil else { return }
            if presentation.selectedOpponentID != id { challengeIntent = nil }
            presentation.selectedOpponentID = id; return
        case .setMode(let mode):
            guard presentation.rematchSourceID == nil else { return }
            if presentation.mode != mode { challengeIntent = nil }
            presentation.mode = mode; return
        case .acknowledgeRecoveryCode: presentation.recoveryCode = nil; return
        case .dismissResult, .backToLobby: resetExtras(); clearHistory(); prefersLobby = true; navigationRevision &+= 1; selectedBattleID = nil; publish(); return
        case .openBattle(let id): prefersLobby = false; navigationRevision &+= 1; selectedBattleID = id; publish(); return
        case .configureServer(let value): await configureServer(value); return
        case .applyingServer(let address, let inner):
            // Save the typed address first, then run the setup request against it. If it cannot be saved
            // (an embedded build, a failed write) the error is already shown and nothing is sent.
            guard onlineAllowed, let target = (try? OnlineBattleOrigin(address))?.url.absoluteString else { return }
            await configureServer(address)
            guard settings.serverURL == target else { return }
            await perform(inner); return
        case .showHistory:
            guard onlineAllowed, authenticated, presentation.account != nil else { return }
            guard !presentation.showsStandings, presentation.rematchSourceID == nil else { return }
            clearHistory(); presentation.showsHistory = true; return
        case .openReplay(let id): openReplay(id); return
        case .seekReplay(let index):
            guard onlineAllowed, authenticated, presentation.showsHistory,
                  let replay = presentation.replay, replay.frames.indices.contains(index) else { return }
            presentation.replayFrameIndex = index; return
        case .closeReplay:
            clearHistory(keepOpen: onlineAllowed && authenticated && presentation.showsHistory); return
        case .challenge, .accept, .confirm, .prepareBattle, .decline, .cancel, .chooseMove:
            guard !presentation.showsHistory, !presentation.showsStandings, presentation.rematchSourceID == nil else { return }
        default: break
        }
        guard onlineAllowed, !actionInFlight else { return }
        actionInFlight = true; presentation.isBusy = true; presentation.notice = nil
        let epoch = generation
        defer { if epoch == generation { actionInFlight = false; presentation.isBusy = false } }
        switch action {
        case .join(let code, let email): await join(inviteCode: code, email: email)
        case .recover(let code): await obtainGrant { try await $0.recover(recoveryCode: code) }
        case .reconnect(let code): await obtainGrant { try await $0.reconnect(reconnectCode: code) }
        case .retryCredentialSave: await retryCredentialSave()
        case .refresh: await refresh()
        default:
            do { try await battleAction(action, epoch: epoch) }
            catch {
                // A notification can publish the created room before the POST reports failure.
                // Resolve the submitted intent while this action still owns the busy gate.
                if case .submitRematch = action, epoch == generation, authenticated,
                   let api, let account = presentation.account {
                    do {
                        if try await reconcileRematchIntent(account: account, api: api, epoch: epoch, completingSubmission: true) {
                            publish(); return
                        }
                    } catch { publish(); await handle(error, epoch: epoch); return }
                }
                publish(); await handle(error, epoch: epoch)
            }
        }
    }
    private var standingsVisible: Bool {
        onlineAllowed && authenticated && popoverOpen && presentation.showsStandings && presentation.account != nil
    }
    private func invalidateStandingsRead() {
        standingsRevision &+= 1
        standingsTask?.cancel(); standingsTask = nil; standingsAgain = false
        presentation.standingsLoading = false
    }
    private func resetBattleRuntime() {
        fallbackTasks.values.forEach { $0.cancel() }; fallbackTasks = [:]; fallback = [:]
        advancing = []; reporting = []; battleReads = []; battleReadAgain = []; battleRecovery = [:]
    }
    private func resetExtras() {
        invalidateStandingsRead()
        presentation.showsStandings = false; presentation.standings = nil; presentation.standingsError = nil
        presentation.rematchSourceID = nil; rematchFromHistory = false
    }
    private func requestStandingsRefresh() {
        guard standingsVisible else { return }
        if standingsTask != nil { standingsAgain = true; return }
        startStandingsRead()
    }
    private func refreshStandings() async {
        guard standingsVisible else { return }
        if standingsTask != nil { standingsAgain = true } else { startStandingsRead() }
        await standingsTask?.value
    }
    private func startStandingsRead() {
        guard standingsVisible, let api, let account = presentation.account else { return }
        let epoch = generation, revision = standingsRevision
        presentation.standingsLoading = true
        standingsTask = Task { [weak self] in
            guard let self else { return }
            repeat {
                self.standingsAgain = false
                do {
                    let value = try await api.standings()
                    try self.current(epoch)
                    guard self.standingsVisible, self.standingsRevision == revision else { return }
                    guard value.groupId == account.group.groupId else { throw OnlineBattleFailure.invalidResponse }
                    self.presentation.standings = value; self.presentation.standingsError = nil
                } catch {
                    guard self.standingsVisible, self.standingsRevision == revision, self.generation == epoch,
                          !(error is CancellationError), error as? OnlineBattleFailure != .staleGeneration else { return }
                    if error as? OnlineBattleFailure == .unauthorized { await self.handle(error, epoch: epoch); return }
                    self.presentation.standingsError = "그룹 전적을 불러오지 못했어요. 서버 지원 여부와 연결을 확인하고 다시 시도해 주세요."
                }
            } while self.standingsAgain && self.standingsVisible && self.standingsRevision == revision && self.generation == epoch
            if self.standingsRevision == revision, self.generation == epoch {
                self.standingsTask = nil; self.presentation.standingsLoading = false
            }
        }
    }
    /// A lost POST response can be discovered by the ordinary list read. It is the same
    /// explicitly submitted intent, so expose its room instead of trapping the UI on a held entry.
    private func reconcileRematchIntent(account: OnlineBattleAccount, api: OnlineBattleAPI, epoch: UInt64,
                                        completingSubmission: Bool = false) async throws -> Bool {
        guard !actionInFlight || completingSubmission, let intent = challengeIntent, let sourceID = intent.sourceID,
              presentation.rematchSourceID == sourceID,
              let room = views.values.first(where: {
                  $0.state.isActive && $0.rematchOf == sourceID && $0.p1.trainerId == account.trainer.trainerId &&
                  $0.p2.trainerId == intent.target && $0.mode == intent.mode && $0.p1.snapshot == intent.snapshot
              }) else { return false }
        guard (try? selectedSnapshot(allow: receiptKey(room, account: account))) == intent.snapshot else {
            try await cancelChangedRematch(room, account: account, api: api, epoch: epoch)
            throw OnlineBattleFailure.invalidRequest
        }
        challengeIntent = nil; presentation.rematchSourceID = nil; rematchFromHistory = false
        presentation.notice = nil
        clearHistory(); prefersLobby = false; selectedBattleID = room.battleId
        return true
    }
    private func cancelChangedRematch(_ room: OnlineBattleView, account: OnlineBattleAccount,
                                      api: OnlineBattleAPI, epoch: UInt64) async throws {
        guard [.pending, .accepted, .ready].contains(room.state) else { throw OnlineBattleFailure.invalidRequest }
        presentation.suppressEndedNotice(for: room.battleId)
        let cancelled = try await api.cancel(id: room.battleId, revision: room.revision); try current(epoch)
        try await process(cancelled, account: account, api: api, epoch: epoch)
        challengeIntent = nil
        try rebuildRoster()
    }

    private func prepareRematch(_ id: String) {
        guard onlineAllowed, authenticated, !actionInFlight,
              let source = presentation.selectedHistoryBattle?.battleId == id ? presentation.selectedHistoryBattle : presentation.room,
              source.battleId == id, let account = presentation.account else { return }
        do { try rebuildRoster() } catch { return }
        guard presentation.canRematch(source), let side = source.side(for: account.trainer.trainerId) else { return }
        rematchFromHistory = presentation.showsHistory
        if challengeIntent?.sourceID != id { challengeIntent = nil }
        presentation.rematchSourceID = id
        presentation.selectedOpponentID = side == .p1 ? source.p2.trainerId : source.p1.trainerId
        presentation.mode = source.mode
        if presentation.selectedEntry.map({ presentation.entryIsEligible($0) }) != true {
            presentation.selectedEntryID = presentation.roster.first(where: presentation.entryIsEligible)?.id
        }
        presentation.showsHistory = false; presentation.notice = nil
        navigationRevision &+= 1
    }

    /// History owns only immutable display frames. It never enters the live process/settlement path.
    private func clearHistory(keepOpen: Bool = false) {
        presentation.showsHistory = keepOpen
        presentation.selectedHistoryBattle = nil
        presentation.replay = nil
        presentation.replayFrameIndex = 0
        presentation.historyBusy = false
        presentation.historyError = nil
    }
    private func completedEngine(hash: String) throws -> BattleEngine {
        if hash == BattleEngineManifest.sha256 { return try engineFactory() }
        return try BattleEngineArchive.engine(hash: hash)
    }
    private func openReplay(_ id: String) {
        guard onlineAllowed, authenticated, let account = presentation.account,
              let room = historyViews[id] ?? views[id], !room.state.isActive,
              room.side(for: account.trainer.trainerId) != nil else { return }
        clearHistory(keepOpen: true)
        presentation.selectedHistoryBattle = room
        guard room.state == .completed else {
            presentation.historyError = room.state == .void
                ? "무효로 끝난 경기예요. 확정된 승패나 보상은 없어요."
                : "시작 전에 종료되어 다시보기 자료가 없어요."
            return
        }
        // Synchronous replay has no network or state-store dependencies. Future historical versions
        // use only the archive allowlist; a missing old engine never falls back to the current one.
        do {
            presentation.replay = try OnlineBattleReplay(battle: room, localTrainerID: account.trainer.trainerId) { hash in
                try self.completedEngine(hash: hash)
            }
        } catch OnlineBattleReplay.Failure.unavailableEngine {
            presentation.historyError = "이 경기의 전투 엔진이 앱에 없어 다시 볼 수 없어요. 경기 요약은 유지돼요."
        } catch OnlineBattleReplay.Failure.incompleteRecord {
            presentation.historyError = "다시보기에 필요한 경기 자료가 없어요. 경기 요약은 유지돼요."
        } catch {
            presentation.historyError = "기록을 검증하지 못해 다시보기를 열 수 없어요. 경기 결과는 바꾸지 않았어요."
        }
    }

    private func battleAction(_ action: OnlineBattleUIAction, epoch: UInt64) async throws {
        let navigation = navigationRevision
        let isRematch: Bool
        if case .submitRematch = action { isRematch = true } else { isRematch = false }
        if case .challenge = action { await refresh(); try current(epoch) }
        if isRematch { await refresh(); try current(epoch) }
        if case .accept = action { await refresh(); try current(epoch) }
        guard onlineAllowed, authenticated, reconciled, let api, let account = presentation.account else { throw OnlineBattleFailure.invalidRequest }
        var result: OnlineBattleView
        let isChallenge: Bool
        if case .challenge = action { isChallenge = true } else { isChallenge = false }
        if isChallenge || isRematch {
            let sourceID = isRematch ? presentation.rematchSourceID : nil
            if isRematch {
                guard let sourceID, let source = historyViews[sourceID] ?? views[sourceID], source.state == .completed,
                      let side = source.side(for: account.trainer.trainerId) else { throw OnlineBattleFailure.invalidRequest }
                let opponent = side == .p1 ? source.p2.trainerId : source.p1.trainerId
                guard presentation.selectedOpponentID == opponent, presentation.mode == source.mode,
                      presentation.members.contains(where: { $0.trainerId == opponent && $0.status == .active }) else { throw OnlineBattleFailure.invalidRequest }
            }
            let previousRoom = challengeIntent.flatMap { intent in
                views.values.first { $0.state.isActive && $0.rematchOf == intent.sourceID && $0.p1.trainerId == account.trainer.trainerId && $0.p2.trainerId == intent.target && $0.p1.snapshot == intent.snapshot && $0.mode == intent.mode }
            }
            let snapshot = try selectedSnapshot(allow: previousRoom.map { try receiptKey($0, account: account) })
            guard let target = presentation.selectedOpponentID, target != account.trainer.trainerId else { throw OnlineBattleFailure.invalidRequest }
            if isRematch, let previousRoom, previousRoom.p1.snapshot != snapshot {
                try await cancelChangedRematch(previousRoom, account: account, api: api, epoch: epoch)
                throw OnlineBattleFailure.invalidRequest
            }
            if challengeIntent?.sourceID != sourceID || challengeIntent?.snapshot != snapshot || challengeIntent?.target != target || challengeIntent?.mode != presentation.mode {
                challengeIntent = .init(sourceID: sourceID, requestID: UUID().uuidString, target: target, mode: presentation.mode, snapshot: snapshot)
            }
            let intent = challengeIntent!
            if let previousRoom, previousRoom.p1.snapshot == intent.snapshot, previousRoom.rematchOf == intent.sourceID { result = previousRoom }
            else if let sourceID { result = try await api.rematch(id: sourceID, requestId: intent.requestID, snapshot: intent.snapshot) }
            else { result = try await api.createBattle(requestId: intent.requestID, targetTrainerId: intent.target, mode: intent.mode, snapshot: intent.snapshot) }
            try current(epoch)
            // A local evolution, heal, or practice entry during the request invalidates consent.
            guard (try? selectedSnapshot(allow: receiptKey(result, account: account), id: snapshot.instanceId)) == snapshot else {
                presentation.suppressEndedNotice(for: result.battleId)
                let cancelled = try await api.cancel(id: result.battleId, revision: result.revision); try current(epoch)
                try await process(cancelled, account: account, api: api, epoch: epoch)
                throw OnlineBattleFailure.invalidRequest
            }
            challengeIntent = nil
            if isRematch, navigation == navigationRevision {
                presentation.rematchSourceID = nil; rematchFromHistory = false; clearHistory()
            }
        } else {
            guard let room = presentation.room else { throw OnlineBattleFailure.invalidRequest }
            switch action {
            case .accept:
                if room.side(for: account.trainer.trainerId) == .p2 {
                    if room.state == .cancelled { throw OnlineBattleFailure.peerCancelled }
                    if room.state == .expired { throw OnlineBattleFailure.peerExpired }
                }
                guard room.state == .pending, room.side(for: account.trainer.trainerId) == .p2 else { throw OnlineBattleFailure.invalidRequest }
                let snapshot = try selectedSnapshot(allow: receiptKey(room, account: account))
                do { result = try await api.accept(id: room.battleId, revision: room.revision, snapshot: snapshot) }
                catch let rejected as OnlineBattleServerError where rejected.code == .invalidState || rejected.code == .staleRevision {
                    // The peer may have cancelled between our read and the accept. Re-read to say so.
                    try current(epoch); await refresh(); try current(epoch)
                    if let latest = views[room.battleId] {
                        if latest.state == .cancelled { throw OnlineBattleFailure.peerCancelled }
                        if latest.state == .expired { throw OnlineBattleFailure.peerExpired }
                    }
                    throw rejected
                }
                try current(epoch)
                guard (try? selectedSnapshot(allow: receiptKey(result, account: account), id: snapshot.instanceId)) == snapshot else {
                    presentation.suppressEndedNotice(for: result.battleId)
                    let cancelled = try await api.cancel(id: result.battleId, revision: result.revision); try current(epoch)
                    try await process(cancelled, account: account, api: api, epoch: epoch)
                    throw OnlineBattleFailure.invalidRequest
                }
            case .confirm:
                guard room.state == .accepted, room.side(for: account.trainer.trainerId) == .p1 else { throw OnlineBattleFailure.invalidRequest }
                try validateConsent(room, account: account)
                result = try await api.confirm(id: room.battleId, revision: room.revision)
            case .decline:
                guard room.state == .pending, room.side(for: account.trainer.trainerId) == .p2 else { throw OnlineBattleFailure.invalidRequest }
                presentation.suppressEndedNotice(for: room.battleId)
                result = try await api.decline(id: room.battleId, revision: room.revision)
            case .cancel:
                guard [.pending, .accepted, .ready].contains(room.state) else { throw OnlineBattleFailure.invalidRequest }
                presentation.suppressEndedNotice(for: room.battleId)
                result = try await api.cancel(id: room.battleId, revision: room.revision)
            case .prepareBattle:
                guard let connection else { throw OnlineBattleFailure.invalidRequest }
                let connected = await connection.snapshot(); try current(epoch)
                guard connected.state == .connected, let connectionID = connected.connectionId,
                      connected.trainerId == account.trainer.trainerId, connected.groupId == account.group.groupId else { throw OnlineBattleFailure.invalidRequest }
                if room.state == .accepted, room.confirmed {
                    try validateConsent(room, account: account)
                    prepared[room.battleId] = room.revision
                    do {
                        result = try await api.ready(id: room.battleId, revision: room.revision, connectionId: connectionID, engineHash: BattleEngineManifest.sha256, rulesVersion: BattleSnapshot.rules, policyVersion: BattleSnapshot.policy)
                    } catch {
                        // A refused ready call must not read as "I am ready" on the room screen.
                        if prepared[room.battleId] == room.revision { prepared[room.battleId] = nil }
                        throw error
                    }
                } else if room.state == .ready {
                    // The frozen inputs stay valid through later local growth. process validates both sets.
                    prepared[room.battleId] = room.revision
                    result = room
                } else { throw OnlineBattleFailure.invalidRequest }
            case .chooseMove(let slot):
                guard room.state == .running, room.mode == .manual, room.ownChoice == nil,
                      let request = resolvers[room.battleId]?.request, request.kind == "move",
                      request.moves.contains(where: { $0.slot == slot && !$0.disabled && $0.pp > 0 }) else { throw OnlineBattleFailure.invalidRequest }
                result = try await api.choose(id: room.battleId, roundSeq: room.roundSeq, slot: slot)
            default: throw OnlineBattleFailure.invalidRequest
            }
            try current(epoch)
        }
        if navigation == navigationRevision { prefersLobby = false; selectedBattleID = result.battleId }
        try await process(result, account: account, api: api, epoch: epoch)
        try rebuildRoster(); publish()
    }
    func tick() async {
        guard onlineAllowed, authenticated else { return }
        let now = clock.now()
        for pending in Array(fallback.values) where now >= pending.due { await resumeFallback(pending.work) }
        let recovery = battleRecovery.filter { now >= $0.value }.map(\.key)
        for id in recovery { await readBattle(id, epoch: generation) }
        let due = views.values.filter { room in
            room.state == .running && !recovery.contains(room.battleId) && room.deadline.map { now * 1000 >= $0 } == true && now >= (checkedDeadlines[room.battleId] ?? 0)
        }
        for room in due {
            checkedDeadlines[room.battleId] = now + 5
            await readBattle(room.battleId, epoch: generation)
        }
        if nextRecoveryRead.map({ now >= $0 }) == true { nextRecoveryRead = nil; await refresh() }
    }
    private func revoke(epoch: UInt64) async {
        guard epoch == generation else { return }
        if authenticated { presentation.clearSetupCodes() }
        authenticated = false; reconciled = false
        presentation.canStart = false; presentation.phase = .setup; presentation.account = nil
        resetBattleRuntime(); resetExtras(); clearHistory(); historyViews = [:]; presentation.battles = []; presentation.liveLogs = []
        dropStagings()
        presentation.connectionStatus = "접속키가 만료되었어요. 복구코드로 다시 연결해 주세요"
        ticker?.cancel(); ticker = nil
        await api?.setAccessKey(nil)
    }
    private func handle(_ error: Error, epoch: UInt64) async {
        guard onlineAllowed, epoch == generation, !(error is CancellationError), error as? OnlineBattleFailure != .staleGeneration else { return }
        if authenticated, views.values.contains(where: { $0.state == .running || $0.state == .reported }) {
            nextRecoveryRead = clock.now() + 5
        }
        if error as? OnlineBattleFailure == .unauthorized {
            if let connection { let snapshot = await connection.snapshot(); guard epoch == generation else { return }; await connection.authenticationFailed(generation: snapshot.generation) }
            await revoke(epoch: epoch); return
        }
        let l = localization()
        if error as? OnlineBattleFailure == .credentialsUnavailable {
            presentation.notice = l.onlineErrorKeySaveFailed
        } else if error as? OnlineBattleFailure == .credentialsDisabled {
            presentation.notice = l.onlineErrorKeySaveDisabled
        } else if error as? OnlineBattleFailure == .peerCancelled {
            // The re-read inside the action already announced it with the opponent's name.
            if !presentation.noticeSurvivesRefresh { presentation.notice = l.onlineErrorPeerCancelled }
        } else if error as? OnlineBattleFailure == .peerExpired {
            if !presentation.noticeSurvivesRefresh { presentation.notice = l.onlineErrorPeerExpired }
        } else if error as? OnlineBattleFailure == .invalidRequest {
            presentation.notice = l.onlineErrorEntryChanged
        } else if error is OnlineBattleResolver.Failure {
            presentation.notice = l.onlineErrorResultUnverified
        } else if let server = error as? OnlineBattleServerError, let text = l.onlineServerError(server) {
            presentation.notice = text
        } else {
            presentation.notice = l.onlineErrorGeneric
        }
    }
}

/// Re-arms the one-shot settings observation before asynchronous connection work.
@MainActor
final class OnlineBattleAccessObservation {
    private let read: () -> Bool
    private let changed: (Bool) async -> Void
    init(read: @escaping () -> Bool, changed: @escaping (Bool) async -> Void) {
        self.read = read; self.changed = changed
    }
    func start() {
        withObservationTracking { _ = read() } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.start()
                await self.changed(self.read())
            }
        }
    }
}

private extension OnlineBattleView {
    func relayView(roundSeq: Int, deadline: Double?, ownChoice: String?, journal: [OnlineBattlePair]) -> Self {
        .init(battleId: battleId, state: state, revision: revision, mode: mode, p1: p1, p2: p2,
              createdAt: createdAt, expiresAt: expiresAt, startedAt: startedAt, reportedAt: reportedAt,
              confirmed: confirmed, config: config, roundSeq: roundSeq, deadline: deadline, ownChoice: ownChoice,
              journal: journal, result: result, reason: reason, rematchOf: rematchOf)
    }
}
