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
    /// One press of "ready". The server binds ready and start to the socket that sent them, and its
    /// `both` check only counts the peer's current socket, so a press holds on its own connection only.
    private struct ReadyPress: Equatable {
        let revision: Int
        let connectionID: String
    }
    private var prepared: [String: ReadyPress] = [:]
    /// Nil while no socket has said hello.
    private var liveConnectionID: String?
    private var acknowledgedStarts = Set<String>()
    private var submittedReports = Set<String>()
    private var nextRecoveryRead: TimeInterval?
    /// Battles whose staged display is still playing. A hidden stage skips to its end, so only the one on screen can be here.
    func stagingHeldBattleIDs() -> Set<String> {
        Set(stagings.filter { $0.value.isPlaying }.keys)
    }
    /// Battles whose open round has nothing to pick (a recharge, Struggle): the round closes at its deadline without the person.
    func noChoiceBattleIDs() -> Set<String> {
        Set(resolvers.filter { $0.value.request.kind != "move" }.keys)
    }
    /// Battles with nothing left for the person to press at their current revision. The server view does not expose it.
    /// A press on an older socket counts while its resend is still owed, so a socket blip raises no notification.
    func preparedBattleIDs() -> Set<String> {
        var ids = Set(presentation.battles.filter { readyPressed($0) }.map(\.battleId))
        if let room = presentation.room, readyPressed(room) { ids.insert(room.battleId) }
        return ids
    }
    private func readyPressed(_ room: OnlineBattleView) -> Bool {
        prepared[room.battleId]?.revision == room.revision
    }
    /// The server still holds this press, so the button has nothing to add.
    private func readyHeld(_ room: OnlineBattleView) -> Bool {
        readyPressed(room) && prepared[room.battleId]?.connectionID == liveConnectionID
    }
    private func noteConnection(_ snapshot: OnlineBattleConnectionSnapshot) {
        presentation.canStart = snapshot.state == .connected
        liveConnectionID = snapshot.state == .connected ? snapshot.connectionId : nil
        presentation.localReady = presentation.room.map { readyHeld($0) } ?? false
    }
    private struct RoundWork: Hashable {
        let generation: UInt64
        let battleID: String
        let readyToken: String
        let seq: Int
    }
    /// Battles whose kept move is on its way to the server.
    private var sendingHeld = Set<String>()
    private var advancing = Set<RoundWork>()
    private var reporting = Set<RoundWork>()
    private var fallback: [String: (work: RoundWork, due: TimeInterval)] = [:]
    private var fallbackTasks: [String: Task<Void, Never>] = [:]
    private var battleReads = Set<String>()
    private var battleReadAgain = Set<String>()
    private var battleRecovery: [String: TimeInterval] = [:]
    private var recoveryBackoff = OnlineBattleRetryBackoff()
    private var battleBackoff: [String: OnlineBattleRetryBackoff] = [:]
    /// Battles whose read failed the same way any later read of those bytes would. Only news or a person reads them again.
    private var parkedBattles = Set<String>()
    /// Rooms set aside because this save lacks their pokemon. Said once each, so a closed banner stays closed across later reads.
    private var otherSaveBattlesAnnounced = Set<String>()
    private var api: OnlineBattleAPI?
    private var origin: OnlineBattleOrigin?
    private var connection: (any OnlineBattleConnecting)?
    private var bootstrapped = false
    private var authenticated = false
    private var generation: UInt64 = 0
    private var pendingGrant: OnlineBattleGrant?
    private var pendingGrantCode: String?
    private var standingsTask: Task<Void, Never>?
    private var standingsAgain = false
    private var standingsRevision: UInt64 = 0
    /// Matches whose other seat's streak was asked for. One read each, whether it worked or not.
    private var opponentStreakReads = Set<String>()
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
    /// The room on screen when nobody chose one, so a newer request cannot slide under its buttons.
    private var pinnedBattleID: String?
    private var checkedDeadlines: [String: Double] = [:]
    private struct ChallengeIntent {
        let sourceID: String?
        let requestID: String
        let target: String
        let mode: OnlineBattleMode
        let snapshot: OnlineBattleSnapshot
    }
    private var challengeIntent: ChallengeIntent?
    /// A code that just did its job. The app forgets it from the clipboard; tests listen here instead.
    var onSetupCodeUsed: @MainActor (String) -> Void = { _ in }

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
        presentation.serverMoved = settings.serverMovedFromStored
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
        pendingGrant = nil; pendingGrantCode = nil; challengeIntent = nil; prepared = [:]; liveConnectionID = nil; acknowledgedStarts = []; submittedReports = []
        for resolver in resolvers.values { resolver.close() }; resolvers = [:]; views = [:]; historyViews = [:]; dropStagings()
        selectedBattleID = nil; pinnedBattleID = nil; resultByBattleID = [:]; prefersLobby = false; checkedDeadlines = [:]; nextRecoveryRead = nil
        presentation.account = nil; presentation.members = []; presentation.battles = []
        resetBattleRuntime(); resetExtras(); clearHistory(); presentation.liveLogs = []
        presentation.room = nil; presentation.arena = nil; presentation.request = nil
        presentation.recoveryCode = nil; presentation.result = nil; presentation.canRetryCredentialSave = false
        presentation.canStart = false; presentation.isBusy = false; presentation.phase = .setup; presentation.restoringAccount = false
        presentation.connectionStatus = .accessStopped
        await oldAPI?.setAccessKey(nil)
        await old?.stop()
    }
    /// Notification delivery never waits for a whole battle. Changes during a read retain one follow-up read.
    func requestRefresh() {
        guard onlineAllowed, authenticated else { return }
        if refreshTask != nil { refreshAgain = true; requestStandingsRefresh() }
        else { Task { [weak self] in await self?.refresh() } }
    }
    /// The Mac woke or got its network back. Without an account there is no socket to bring back.
    func reconnectHint(_ reason: OnlineBattleReconnectReason) async {
        guard onlineAllowed, authenticated else { return }
        retryNow()
        await connection?.reconnectHint(reason)
    }
    /// No build of this app can reach another server again once one is fixed, and a hold there would otherwise
    /// block the pokemon for good. Done without an account: joining the new server is not the price of an egg.
    /// A failed write leaves the hold for the next launch and must not take online down with it.
    private func releaseHoldsOfOtherServers() {
        guard let fixed = settings.embeddedServerURL, let origin = try? OnlineBattleOrigin(fixed) else { return }
        for hold in effects.companionState()?.state.onlineBattleHolds ?? [] where hold.key.scope.originHash != origin.hash {
            try? effects.releaseOnlineBattle(key: hold.key)
        }
    }
    func bootstrap() async {
        releaseHoldsOfOtherServers()
        guard onlineAllowed else { presentation.connectionStatus = .accessOff; return }
        guard !bootstrapped else { return }
        bootstrapped = true
        let epoch = generation
        do {
            try rebuildRoster()
            guard let address = settings.serverURL else { return }
            let origin = try OnlineBattleOrigin(address)
            self.origin = origin; api = OnlineBattleAPI(origin: origin, transport: transport)
            // Assumed until the key is read, so a relaunch does not flash the sign-up form.
            presentation.restoringAccount = true
            let key = try await credentials.load(scope: .init(profileID: settings.profileID, origin: origin))
            try current(epoch)
            guard let key else { presentation.restoringAccount = false; presentation.connectionStatus = .connection(.credentialsRequired); return }
            try await activate(key, epoch: epoch)
            await refresh()
        } catch {
            if epoch == generation { presentation.restoringAccount = false }
            await handle(error, epoch: epoch)
        }
    }
    func configureServer(_ value: String) async {
        do {
            var next = settings; try next.setServer(value); try saveSettings(next)
            generation &+= 1
            refreshTask?.cancel(); refreshTask = nil; ticker?.cancel(); ticker = nil
            let old = connection; connection = nil
            for resolver in resolvers.values { resolver.close() }
            dropStagings()
            resolvers = [:]; views = [:]; historyViews = [:]; selectedBattleID = nil; pinnedBattleID = nil; resultByBattleID = [:]; prefersLobby = false; checkedDeadlines = [:]
            api = nil; origin = nil; pendingGrant = nil; pendingGrantCode = nil; challengeIntent = nil
            authenticated = false; reconciled = false; actionInFlight = false
            refreshAgain = false; prepared = [:]; liveConnectionID = nil; acknowledgedStarts = []; submittedReports = []; nextRecoveryRead = nil
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
            presentation.phase = .setup; presentation.isBusy = false; presentation.restoringAccount = false
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
            noteConnection(snapshot)
            if snapshot.state == .revoked { await revoke(epoch: epoch); return }
            presentation.connectionStatus = .connection(snapshot.state)
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
        /// True only when the server says the other seat's first choice for this round is in; absent or anything else is false.
        let opponentSubmitted: Bool
        private enum CodingKeys: String, CodingKey { case type, state, revision, roundSeq, deadline, pair, opponentSubmitted }
        init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: CodingKeys.self)
            type = try box.decode(String.self, forKey: .type)
            state = try box.decodeIfPresent(OnlineBattleState.self, forKey: .state)
            revision = try box.decodeIfPresent(Int.self, forKey: .revision)
            roundSeq = try box.decodeIfPresent(Int.self, forKey: .roundSeq)
            deadline = try box.decodeIfPresent(Double.self, forKey: .deadline)
            pair = try box.decodeIfPresent(OnlineBattlePair.self, forKey: .pair)
            hasDeadline = box.contains(.deadline)
            opponentSubmitted = (try? box.decodeIfPresent(Bool.self, forKey: .opponentSubmitted)) == true
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
                    if seq <= room.journal.count { return }
                    if notice.deadline == room.deadline {
                        // The first-choice signal: same round and deadline, one more fact. No read is needed to show it.
                        if notice.opponentSubmitted, room.mode == .manual, room.deadline != nil, room.opponentSubmitted != true {
                            var marked = room; marked.opponentSubmitted = true
                            views[id] = marked; publish()
                        }
                        return
                    }
                }
                if room.mode == .manual, seq == room.roundSeq + 1, seq == resolver.processedRoundSeq + 1,
                   let deadline = notice.deadline, deadline.isFinite, deadline <= 9_007_199_254_740_991,
                   let releasedAt = room.journal.last?.releasedAt, deadline > releasedAt {
                    var opened = room.relayView(roundSeq: seq, deadline: deadline, ownChoice: nil, journal: room.journal)
                    // relayView starts a round with no signal; a first-choice notice that outran its open notice carries it.
                    if notice.opponentSubmitted { opened.opponentSubmitted = true }
                    views[id] = opened
                    cancelFallback(id); publish()
                    // The round a kept move was waiting for. A failed send falls to the read below, which tries again.
                    if presentation.heldChoice?.battleID == id { try await process(opened, account: account, api: api, epoch: epoch) }
                    return
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
                try current(epoch); battleRecovery[id] = nil; parkedBattles.remove(id); try rebuildRoster(); publish()
            } catch {
                guard epoch == generation else { return }
                // Battle recovery stays scoped: this failure arms a read of this battle, not a full read.
                await handle(error, epoch: epoch, armsFullRead: false)
                armBattleRecovery(id, after: error)
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
            await handle(error, epoch: work.generation, armsFullRead: false)
            if work.generation == generation { armBattleRecovery(work.battleID, after: error) }
        }
    }
    /// What this error says about reading again. Verifying the same bytes fails the same way, however often they are read.
    private static func anotherReadCouldHelp(_ error: Error) -> Bool {
        !(error is OnlineBattleResolver.Failure || error is OnlineBattleEffectError
            || error is OnlineBattleReplay.Failure || error is BattleEngine.Failure)
    }
    private func armBattleRecovery(_ id: String, after error: Error) {
        guard Self.anotherReadCouldHelp(error) else { battleRecovery[id] = nil; parkedBattles.insert(id); return }
        battleRecovery[id] = clock.now() + battleBackoff[id, default: .init()].nextDelay()
    }
    /// The waits start over.
    private func restartRetries() {
        recoveryBackoff = .init(); battleBackoff = [:]; parkedBattles = []
    }
    /// A person looked or the network came back. Whatever was waiting its turn goes now.
    private func retryNow() {
        restartRetries()
        guard authenticated else { return }
        let now = clock.now()
        // A failed read that had nothing left to wait for (no match to rescue, or nothing a retry could change) asks once more too.
        if nextRecoveryRead != nil || !reconciled { nextRecoveryRead = now }
        battleRecovery = battleRecovery.mapValues { _ in now }
    }
    func join(inviteCode: String, email: String) async {
        await obtainGrant(usedCode: inviteCode) { try await $0.join(inviteCode: inviteCode, displayEmail: email) }
    }
    private func obtainGrant(usedCode: String, _ request: (OnlineBattleAPI) async throws -> OnlineBattleGrant) async {
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
            selectedBattleID = nil; pinnedBattleID = nil; prefersLobby = false; checkedDeadlines = [:]; nextRecoveryRead = nil
            prepared = [:]; liveConnectionID = nil; acknowledgedStarts = []; submittedReports = []; challengeIntent = nil
            presentation.account = nil; presentation.members = []; presentation.battles = []
            resetBattleRuntime(); resetExtras(); clearHistory(); presentation.liveLogs = []
            presentation.room = nil; presentation.arena = nil; presentation.request = nil
            presentation.result = nil; presentation.recoveryCode = nil; presentation.canStart = false
            presentation.phase = .setup; presentation.restoringAccount = false
            pendingGrant = grant; pendingGrantCode = usedCode; presentation.canRetryCredentialSave = true
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
            // Only now is the code spent: until the key is safe, the person may still need what they copied.
            if let pendingGrantCode { onSetupCodeUsed(pendingGrantCode) }
            pendingGrant = nil; pendingGrantCode = nil; presentation.canRetryCredentialSave = false
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
            // In the same turn as the last check, so a signal either runs the loop again or starts a new read.
            // Clearing it after `await task.value` left a turn where a signal found a task that would not read again.
            if self.generation == epoch { self.refreshTask = nil }
        }
        refreshTask = task
        await task.value
    }
    private func readAll(api: OnlineBattleAPI, epoch: UInt64) async {
        do {
            let account = try await api.me(); try current(epoch)
            guard account.trainer.status == .active else { throw OnlineBattleFailure.unauthorized }
            let group = try await api.group(); try current(epoch)
            guard group.group.groupId == account.group.groupId else { throw OnlineBattleFailure.invalidResponse }
            var battles = try await api.listBattles(); try current(epoch)
            let scope = try scope(account)
            // This read proved who this is on this server. A hold of any other trainer or group here belongs to a key
            // that has been replaced. Another server's hold stays: a manual build keeps that key and can go back,
            // where the room is listed again, settles once by its receipt, and the pokemon was not entered twice.
            for hold in effects.companionState()?.state.onlineBattleHolds ?? []
            where hold.key.scope.originHash == scope.originHash && hold.key.scope != scope {
                try effects.releaseOnlineBattle(key: hold.key)
            }
            let ids = Set(battles.map(\.battleId))
            for hold in effects.companionState()?.state.onlineBattleHolds ?? [] where hold.key.scope == scope && !ids.contains(hold.key.battleID) {
                let room = try await api.battle(id: hold.key.battleID); try current(epoch); battles.append(room)
            }
            if let old = presentation.account, old.trainer.trainerId != account.trainer.trainerId || old.group.groupId != account.group.groupId {
                throw OnlineBattleFailure.unauthorized
            }
            if presentation.account == nil { presentation.clearSetupCodes() }
            presentation.account = account; presentation.members = group.members; presentation.restoringAccount = false
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
            recoveryBackoff = .init(); nextRecoveryRead = nil; parkedBattles = []
            try rebuildRoster(); _ = try await reconcileRematchIntent(account: account, api: api, epoch: epoch); publish()
            if let connection { let snapshot = await connection.snapshot(); try current(epoch); noteConnection(snapshot) }
        } catch {
            guard epoch == generation, onlineAllowed else { return }
            reconciled = false
            // This read owed the resend to any press left on an older socket. Nothing else will send it now.
            if let liveConnectionID { prepared = prepared.filter { $0.value.connectionID == liveConnectionID } }
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
        // Confirm keeps the revision, so a read started before it can only be told apart by the flag.
        if old.confirmed, !room.confirmed { return false }
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
            // The first-choice signal can land before a read that started earlier, and a round cannot un-choose.
            if let previousView, previousView.opponentSubmitted == true, previousView.roundSeq == room.roundSeq,
               previousView.journal.count == room.journal.count { room.opponentSubmitted = true }
            views[room.battleId] = room
            // A room that stopped running has no next round for a kept move.
            if room.state != .running, presentation.heldChoice?.battleID == room.battleId { presentation.dropHeldChoice() }
            // A read that worked says nothing about a failing advance; only a room that moved does.
            if let previousView, previousView.state != room.state || previousView.roundSeq != room.roundSeq
                || previousView.journal.count != room.journal.count { battleBackoff[room.battleId] = nil }
            if let pending = fallback[room.battleId], room.state != .running || room.roundSeq > pending.work.seq {
                cancelFallback(room.battleId)
            }
            let key = try receiptKey(room, account: account)
            if [.void, .cancelled, .declined, .expired].contains(room.state) {
                try effects.releaseOnlineBattle(key: key)
                // No read follows on the socket path, and what this room held is free now.
                try rebuildRoster()
                resolvers.removeValue(forKey: room.battleId)?.close()
                presentation.announceEnded(room, previous: previousView?.state, l: localization())
                stagings.removeValue(forKey: room.battleId)?.skipToEnd()
                if room.state == .void {
                    resultByBattleID[room.battleId] = .init(kind: .void, effects: nil)
                }
                publish(); return
            }
            if room.state == .completed {
                // No read follows on the socket path, so the HP and the hold this settlement changed are taken here.
                try settle(room, account: account); try rebuildRoster(); resolvers.removeValue(forKey: room.battleId)?.close(); publish(); return
            }
            if let own = side == .p1 ? room.p1.snapshot : room.p2.snapshot {
                guard presentation.roster.contains(where: { $0.id == own.instanceId }) else { setAside(room.battleId); return }
                do { try effects.holdOnlineBattle(key: key, instanceID: own.instanceId) }
                // This save knows the pokemon, but fainted or in another room: the same room from another save's past.
                catch OnlineBattleEffectError.faintedIndividual, OnlineBattleEffectError.individualHeld { setAside(room.battleId); return }
            }
            if room.state == .accepted, room.confirmed, let resent = try await resendReady(room, account: account, api: api, epoch: epoch) {
                room = resent; continue
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
            if room.state == .ready, readyPressed(room), let connection {
                let snapshot = await connection.snapshot(); try current(epoch)
                guard snapshot.state == .connected, snapshot.trainerId == account.trainer.trainerId,
                      snapshot.groupId == account.group.groupId, let connectionID = snapshot.connectionId else { return }
                let acknowledgement = room.battleId + ":" + connectionID
                prepared[room.battleId] = .init(revision: room.revision, connectionID: connectionID)
                guard !acknowledgedStarts.contains(acknowledgement) else { return }
                let updated: OnlineBattleView
                do {
                    updated = try await api.start(id: room.battleId, revision: room.revision, connectionId: connectionID,
                                                  readyToken: room.config!.readyToken, engineHash: BattleEngineManifest.sha256)
                } catch {
                    // A refused start must not read as "I am ready": no other control retries it on this screen.
                    prepared[room.battleId] = nil
                    throw error
                }
                try current(epoch); acknowledgedStarts.insert(acknowledgement)
                guard updated != room else { return }
                room = updated; continue
            }
            guard room.state == .running || room.state == .reported else { return }
            if let report = try resolver.terminalReport() {
                if presentation.heldChoice?.battleID == room.battleId { presentation.dropHeldChoice() }
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
            if room.state == .running, room.mode == .manual, room.roundIsUnreleased, resolver.processedRoundSeq == room.journal.count {
                guard let answer = try await sendHeldChoice(room, resolver: resolver, api: api, epoch: epoch) else { return }
                room = answer; continue
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
    /// A round is open and a move was kept for it: send it there. nil when nothing went out. A refusal drops the move
    /// and answers with a fresh read, so the screen says what happened. Any other failure keeps the move for the next read.
    private func sendHeldChoice(_ room: OnlineBattleView, resolver: OnlineBattleResolver, api: OnlineBattleAPI, epoch: UInt64) async throws -> OnlineBattleView? {
        guard let held = presentation.heldChoice, held.battleID == room.battleId, !sendingHeld.contains(room.battleId) else { return nil }
        guard room.ownChoice == nil else { presentation.dropHeldChoice(); publish(); return nil }
        let request = resolver.request
        guard request.kind == "move", request.moves.contains(where: { $0.slot == held.slot && !$0.disabled && $0.pp > 0 }) else {
            let l = localization()
            let text = request.kind == "move" ? l.onlineHeldChoiceUnusable : l.onlineHeldChoiceForced
            presentation.dropHeldChoice()
            presentation.notice = text; presentation.stickyNotice = text
            publish(); return nil
        }
        sendingHeld.insert(room.battleId)
        defer { sendingHeld.remove(room.battleId) }
        let answer: OnlineBattleView
        do { answer = try await api.choose(id: room.battleId, roundSeq: room.roundSeq, slot: held.slot) }
        catch let refused as OnlineBattleServerError where [.staleRound, .invalidState, .choiceConflict].contains(refused.code) {
            try current(epoch)
            presentation.dropHeldChoice()
            await handle(refused.code == .choiceConflict ? OnlineBattleFailure.choiceAlreadyIn : OnlineBattleFailure.roundPassed, epoch: epoch, armsFullRead: false)
            let fresh = try await api.battle(id: room.battleId)
            try current(epoch)
            return fresh
        }
        try current(epoch)
        presentation.dropHeldChoice()
        return answer
    }
    /// A press left on an older socket no longer counts on the server, and the peer's ready does not
    /// complete the room without it. The person already pressed, so the new socket answers for them.
    /// Anything that stops it hands the choice back: the press is dropped and the button returns.
    private func resendReady(_ room: OnlineBattleView, account: OnlineBattleAccount, api: OnlineBattleAPI, epoch: UInt64) async throws -> OnlineBattleView? {
        guard readyPressed(room), let connection else { return nil }
        let snapshot = await connection.snapshot(); try current(epoch)
        guard snapshot.state == .connected, snapshot.trainerId == account.trainer.trainerId, snapshot.groupId == account.group.groupId,
              let connectionID = snapshot.connectionId, readyPressed(room), prepared[room.battleId]?.connectionID != connectionID else { return nil }
        let press = ReadyPress(revision: room.revision, connectionID: connectionID)
        prepared[room.battleId] = press
        do {
            try validateConsent(room, account: account)
            let updated = try await api.ready(id: room.battleId, revision: room.revision, connectionId: connectionID, engineHash: BattleEngineManifest.sha256, rulesVersion: BattleSnapshot.rules, policyVersion: BattleSnapshot.policy)
            try current(epoch)
            return updated
        } catch {
            try current(epoch)
            if error as? OnlineBattleFailure == .unauthorized { throw error }
            if prepared[room.battleId] == press { prepared[room.battleId] = nil }
            return nil
        }
    }
    /// A room entered with a pokemon this save cannot field cannot be played or held here. Only this room stops:
    /// no view means no arena, no deadline reads and no recovery loop. The next read looks at it again.
    private func setAside(_ id: String) {
        views[id] = nil
        resolvers.removeValue(forKey: id)?.close()
        stagings[id] = nil
        cancelFallback(id); battleRecovery[id] = nil
        guard otherSaveBattlesAnnounced.insert(id).inserted else { return }
        let text = localization().onlineOtherSaveBattle
        presentation.notice = text; presentation.stickyNotice = text
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
        // Fought with a pokemon this save does not have: a record, not an effect. No receipt is written, so a save that
        // brings the pokemon later still settles it, and one that brings the receipt with it does not settle it twice.
        let own = battle.side(for: account.trainer.trainerId) == .p1 ? battle.p1.snapshot : battle.p2.snapshot
        if let own, !presentation.roster.contains(where: { $0.id == own.instanceId }) {
            try effects.releaseOnlineBattle(key: key)
            resultByBattleID[battle.battleId] = .init(kind: .record, effects: nil)
            return
        }
        guard let hash = battle.config?.engineHash else { throw OnlineBattleFailure.invalidResponse }
        let resolver = try OnlineBattleResolver.completedResolver(battle: battle, localTrainerID: account.trainer.trainerId,
                                                                  engine: completedEngine(hash: hash))
        defer { resolver.close() }
        let proof = try resolver.verifyCompleted(battle)
        let outcome: OnlineBattleOutcome = proof.winner == .draw ? .draw : proof.winner.rawValue == proof.localSide.rawValue ? .win : .loss
        let receipt = try effects.applyVerifiedOnlineBattleEffect(.init(key: receiptKey(battle, account: account), resultHash: proof.resultHash,
            localInstanceID: proof.localInstanceID, remainingHPShare: proof.remainingHPShare, outcome: outcome))
        showResult(receipt, outcome: outcome)
    }
    private func showResult(_ receipt: OnlineBattleEffectReceipt, outcome: OnlineBattleOutcome) {
        resultByBattleID[receipt.key.battleID] = .init(
            kind: outcome == .win ? .win : outcome == .loss ? .loss : .draw,
            effects: .init(instanceID: receipt.localInstanceID, xp: Int64(receipt.grantedXP), hpShare: receipt.appliedHPShare))
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
              let hp = presentation.entryHP[selected], hp > 0 else { throw OnlineBattleFailure.entryChanged }
        if effects.isHeldForBattle(instanceID: selected) {
            guard let key, effects.companionState()?.state.onlineBattleHolds.contains(where: { $0.key == key && $0.instanceID == selected }) == true else { throw OnlineBattleEffectError.individualHeld }
        }
        return .init(snapshot: snapshot, hp: hp)
    }
    private func validateConsent(_ room: OnlineBattleView, account: OnlineBattleAccount) throws {
        let side = room.side(for: account.trainer.trainerId)
        guard let own = side == .p1 ? room.p1.snapshot : room.p2.snapshot,
              try selectedSnapshot(allow: receiptKey(room, account: account), id: own.instanceId) == own else { throw OnlineBattleFailure.entryChanged }
    }
    /// The live room on screen. Only processed live views can drive the live room/result; archive summaries cannot settle it.
    private func displayedRoom() -> OnlineBattleView? {
        guard !prefersLobby else { return nil }
        if let selected = selectedBattleID.flatMap({ views[$0] }) { return selected }
        // Only processed live views can drive the live room/result; archive summaries cannot settle it.
        let live = views.values.sorted { ($0.createdAt, $0.battleId) > ($1.createdAt, $1.battleId) }
        // A match in play or being verified outranks a newer request, so a relaunch returns to it.
        let inPlay = live.first(where: { $0.state == .running || $0.state == .reported })
        // It also outranks a waiting room, but never takes the screen from another match or its result.
        if let pinned = pinnedBattleID.flatMap({ views[$0] }),
           inPlay == nil || ![.pending, .accepted, .ready, .declined, .cancelled, .expired].contains(pinned.state) { return pinned }
        // A finished room is shown only as the pinned one above: a match watched ending here, not an old one found at launch.
        return inPlay ?? live.first(where: { $0.state.isActive })
    }
    private func publish() {
        syncStages()
        var listed = views
        for (id, room) in historyViews { listed[id] = room }
        presentation.battles = listed.values.sorted { ($0.createdAt, $0.battleId) > ($1.createdAt, $1.battleId) }
        let room = displayedRoom()
        // A first read publishes room by room; until it ends, an older request is not yet the one to keep.
        if let room, reconciled || room.state == .running || room.state == .reported { pinnedBattleID = room.battleId }
        let staging = room.flatMap { stagings[$0.battleId] }
        // Progress is already done when this holds; it only keeps the arena up until the last beat ends.
        let holdsArena = staging?.isPlaying == true
        presentation.stage = staging
        presentation.room = room
        // A kept move belongs to its room: moving to another one, or to the lobby, takes it along.
        if let held = presentation.heldChoice, held.battleID != room?.battleId { presentation.dropHeldChoice() }
        presentation.result = room.flatMap { resultByBattleID[$0.battleId] }
        presentation.arena = nil; presentation.request = nil; presentation.moveHints = [:]; presentation.deadline = nil
        presentation.choiceSubmitted = false
        presentation.localReady = room.map { readyHeld($0) } ?? false
        presentation.moveSlugs = [:]; presentation.abilitySlugs = [:]
        presentation.liveLogs = []
        guard let room, let account = presentation.account else { presentation.phase = authenticated ? .lobby : .setup; return }
        presentation.localSide = room.side(for: account.trainer.trainerId) ?? .p1
        presentation.deadline = room.deadline.map { Date(timeIntervalSince1970: $0 / 1000) }
        // A kept move going to the round that just opened reads as chosen, so no my-turn mark rises under it.
        presentation.choiceSubmitted = room.ownChoice != nil || (room.deadline != nil && presentation.heldChoice?.battleID == room.battleId)
        presentation.arena = resolvers[room.battleId]?.view ?? staging?.lastView
        presentation.request = resolvers[room.battleId]?.request ?? staging?.lastRequest
        // Hints belong to the resolver's live request; a staged request that outlived its resolver has none.
        presentation.moveHints = resolvers[room.battleId]?.moveHints() ?? [:]
        presentation.liveLogs = OnlineBattleHistoryText.logs(resolvers[room.battleId]?.logs ?? [], localSide: presentation.localSide)
        publishDisclosedNames(room)
        if room.state == .running { readOpponentStreakOnce(room, account: account) }
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
            && !presentation.showsHostPanel
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
            if side == presentation.localSide {
                ids.formUnion(presentation.request?.moves.map(\.id) ?? [])
                ids.formUnion(presentation.stage?.lastMoveRequest?.moves.map(\.id) ?? [])
            }
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
            if open { requestStandingsRefresh(); retryNow() } else { invalidateStandingsRead() }
            // The popover's views are released on close with no guaranteed onDisappear; the screen's onAppear sets it again.
            if !open { onlineScreenVisible = false }
            presentation.screenShown = popoverOpen && onlineScreenVisible
            refreshStageVisibility()
            await connection?.setPopoverOpen(open); return
        case .setOnlineScreenVisible(let visible):
            onlineScreenVisible = visible
            presentation.screenShown = popoverOpen && onlineScreenVisible
            // The bag sits one tab away and nothing reads the server on the way here: show the HP it just changed.
            if visible, (try? rebuildRoster()) != nil { publish() }
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
        case .deferRematch: return
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
        case .acknowledgeRecoveryCode: presentation.finishRecoveryScreen(copied: false); return
        case .dismissResult, .backToLobby: resetExtras(); clearHistory(); prefersLobby = true; navigationRevision &+= 1; selectedBattleID = nil; pinnedBattleID = nil; publish(); return
        case .openBattle(let id): selectBattle(id); return
        case .host(let hostAction): await performHost(hostAction); return
        // A lobby row cannot be pressed behind an overlay; an event can. The rematch draft's picks live outside its page.
        // A host code on screen is the only copy, so it stays on top until it is copied or hidden; the room waits behind it.
        case .followAttention(let id): resetExtras(keepingHostCode: true); clearHistory(); selectBattle(id); return
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
            // Between the press and here the round may have closed. Its number must not go out; the press waits for the next.
            if case .chooseMove(let slot) = action, let room = presentation.room, room.state == .running, room.mode == .manual, !room.roundIsUnreleased {
                presentation.holdChoice(slot: slot, battleID: room.battleId); publish(); return
            }
        default: break
        }
        guard onlineAllowed, !actionInFlight else { return }
        restartRetries()
        actionInFlight = true; presentation.isBusy = true; presentation.notice = nil
        let epoch = generation
        defer { if epoch == generation { actionInFlight = false; presentation.isBusy = false } }
        switch action {
        case .join(let code, let email): await join(inviteCode: code, email: email)
        case .recover(let code): await obtainGrant(usedCode: code) { try await $0.recover(recoveryCode: code) }
        case .reconnect(let code): await obtainGrant(usedCode: code) { try await $0.reconnect(reconnectCode: code) }
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
    private func selectBattle(_ id: String) {
        prefersLobby = false; navigationRevision &+= 1; selectedBattleID = id; publish()
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
        otherSaveBattlesAnnounced = []
        sendingHeld = []; presentation.dropHeldChoice()
        opponentStreakReads = []; presentation.opponentStreaks = [:]
        restartRetries()
    }
    private func resetExtras(keepingHostCode: Bool = false) {
        invalidateStandingsRead()
        presentation.showsStandings = false; presentation.standings = nil; presentation.standingsError = nil
        presentation.rematchSourceID = nil; rematchFromHistory = false
        if !(keepingHostCode && presentation.hostSecretShowing) { presentation.host.close() }
    }
    /// The arena's card says the other seat's streak, and the arena never opens the standings. Read when the match's
    /// room opens, kept apart from the overlay's value. A failed read leaves the line out and is not worth a banner.
    private func readOpponentStreakOnce(_ room: OnlineBattleView, account: OnlineBattleAccount) {
        guard let api, let side = room.side(for: account.trainer.trainerId),
              opponentStreakReads.insert(room.battleId).inserted else { return }
        let id = room.battleId, epoch = generation, group = account.group.groupId
        let foe = side == .p1 ? room.p2.trainerId : room.p1.trainerId
        Task { [weak self] in
            guard let value = try? await api.standings() else { return }
            guard let self, self.generation == epoch, value.groupId == group else { return }
            self.presentation.opponentStreaks[id] = value.rows.first(where: { $0.trainerId == foe })?.streak
        }
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
            throw OnlineBattleFailure.entryChanged
        }
        let staysOnSource = !rematchFromHistory && presentation.room?.battleId == sourceID
        challengeIntent = nil; presentation.rematchSourceID = nil; rematchFromHistory = false
        presentation.notice = nil
        clearHistory(); prefersLobby = false; selectedBattleID = staysOnSource ? sourceID : room.battleId
        return true
    }
    private func cancelChangedRematch(_ room: OnlineBattleView, account: OnlineBattleAccount,
                                      api: OnlineBattleAPI, epoch: UInt64) async throws {
        guard [.pending, .accepted, .ready].contains(room.state) else { throw OnlineBattleFailure.invalidRequest }
        try await withdrawConsent(room, account: account, api: api, epoch: epoch)
        challengeIntent = nil
        try rebuildRoster()
    }
    /// This app ends the room itself because the entry it agreed with changed. A failed cancel ended nothing, so later endings stay news.
    private func withdrawConsent(_ room: OnlineBattleView, account: OnlineBattleAccount, api: OnlineBattleAPI, epoch: UInt64) async throws {
        presentation.suppressEndedNotice(for: room.battleId)
        let cancelled: OnlineBattleView
        do { cancelled = try await api.cancel(id: room.battleId, revision: room.revision) }
        catch { presentation.allowEndedNotice(for: room.battleId); throw error }
        try current(epoch)
        try await process(cancelled, account: account, api: api, epoch: epoch)
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

    private func roomActionTarget(_ action: OnlineBattleUIAction) -> String? {
        switch action {
        case .accept(let id), .confirm(let id), .prepareBattle(let id), .decline(let id), .cancel(let id): id
        default: nil
        }
    }
    private func isEndingAction(_ action: OnlineBattleUIAction) -> Bool {
        switch action {
        case .decline, .cancel: true
        default: false
        }
    }
    private func battleAction(_ action: OnlineBattleUIAction, epoch: UInt64) async throws {
        let navigation = navigationRevision
        let isRematch: Bool
        if case .submitRematch = action { isRematch = true } else { isRematch = false }
        let isChallenge: Bool
        if case .challenge = action { isChallenge = true } else { isChallenge = false }
        let isAccept: Bool
        if case .accept = action { isAccept = true } else { isAccept = false }
        // New consent always reads first. Anything else reads first only when the last read failed:
        // one failed background read must not refuse a press that a fresh read would allow.
        if isChallenge || isRematch || isAccept || !reconciled { await refresh(); try current(epoch) }
        guard onlineAllowed, authenticated, reconciled, let api, let account = presentation.account else { throw OnlineBattleFailure.connectionUnavailable }
        var result: OnlineBattleView
        let shownID = presentation.room?.battleId
        // A rematch asked from a finished room's own result waits on that result; one asked from the archive opens its room.
        var staysOnSourceID: String?
        if isChallenge || isRematch {
            let sourceID = isRematch ? presentation.rematchSourceID : nil
            if isRematch, !rematchFromHistory, sourceID == shownID { staysOnSourceID = sourceID }
            if isRematch {
                guard let sourceID, let source = historyViews[sourceID] ?? views[sourceID], source.state == .completed,
                      let side = source.side(for: account.trainer.trainerId) else { throw OnlineBattleFailure.invalidRequest }
                let opponent = side == .p1 ? source.p2.trainerId : source.p1.trainerId
                guard presentation.selectedOpponentID == opponent, presentation.mode == source.mode,
                      presentation.members.contains(where: { $0.trainerId == opponent && $0.status == .active }) else { throw OnlineBattleFailure.invalidRequest }
                // The read above found their request for this same match. Asking back would cross it: answer it instead.
                if case .received(let asked)? = presentation.rematchOffer(for: source) {
                    presentation.deferredRematchIDs.remove(asked.battleId)
                    challengeIntent = nil; presentation.rematchSourceID = nil; rematchFromHistory = false; clearHistory()
                    if navigation == navigationRevision { prefersLobby = false; selectedBattleID = staysOnSourceID ?? asked.battleId }
                    try rebuildRoster(); publish(); return
                }
            }
            let previousRoom = challengeIntent.flatMap { intent in
                views.values.first { $0.state.isActive && $0.rematchOf == intent.sourceID && $0.p1.trainerId == account.trainer.trainerId && $0.p2.trainerId == intent.target && $0.p1.snapshot == intent.snapshot && $0.mode == intent.mode }
            }
            let snapshot = try selectedSnapshot(allow: previousRoom.map { try receiptKey($0, account: account) })
            guard let target = presentation.selectedOpponentID, target != account.trainer.trainerId else { throw OnlineBattleFailure.invalidRequest }
            if isRematch, let previousRoom, previousRoom.p1.snapshot != snapshot {
                try await cancelChangedRematch(previousRoom, account: account, api: api, epoch: epoch)
                throw OnlineBattleFailure.entryChanged
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
                try await withdrawConsent(result, account: account, api: api, epoch: epoch)
                throw OnlineBattleFailure.entryChanged
            }
            challengeIntent = nil
            if isRematch, navigation == navigationRevision {
                presentation.rematchSourceID = nil; rematchFromHistory = false; clearHistory()
            }
        } else {
            // Addressed by the battle the press was made on. It must still be the room on screen or, beside a
            // finished room's result, that room's open rematch: nothing else the person was not looking at.
            let room: OnlineBattleView
            if let target = roomActionTarget(action) {
                guard let found = presentation.actionRoom(target) else {
                    // A rematch request that ended while the result was open is told as what happened to it.
                    if case .accept = action, let gone = presentation.battles.first(where: { $0.battleId == target }),
                       gone.side(for: account.trainer.trainerId) == .p2 {
                        if gone.state == .cancelled { throw OnlineBattleFailure.peerCancelled }
                        if gone.state == .expired { throw OnlineBattleFailure.peerExpired }
                    }
                    throw OnlineBattleFailure.invalidRequest
                }
                room = found
            } else {
                guard let shown = presentation.room else { throw OnlineBattleFailure.invalidRequest }
                room = shown
            }
            // A press that ends the room is not news when its ending arrives, whichever way that comes first.
            let endsRoom = isEndingAction(action)
            if endsRoom { presentation.suppressEndedNotice(for: room.battleId) }
            do {
                switch action {
                case .accept:
                    if room.side(for: account.trainer.trainerId) == .p2 {
                        if room.state == .cancelled { throw OnlineBattleFailure.peerCancelled }
                        if room.state == .expired { throw OnlineBattleFailure.peerExpired }
                    }
                    guard room.state == .pending, room.side(for: account.trainer.trainerId) == .p2 else { throw OnlineBattleFailure.invalidRequest }
                    // Beside a result nobody picked a Pokémon for this request; the one the result named enters.
                    if room.battleId != shownID, let entry = presentation.answerEntry { presentation.selectedEntryID = entry.id }
                    let snapshot = try selectedSnapshot(allow: receiptKey(room, account: account))
                    result = try await api.accept(id: room.battleId, revision: room.revision, snapshot: snapshot)
                    try current(epoch)
                    guard (try? selectedSnapshot(allow: receiptKey(result, account: account), id: snapshot.instanceId)) == snapshot else {
                        try await withdrawConsent(result, account: account, api: api, epoch: epoch)
                        throw OnlineBattleFailure.entryChanged
                    }
                case .confirm:
                    guard room.state == .accepted, room.side(for: account.trainer.trainerId) == .p1 else { throw OnlineBattleFailure.invalidRequest }
                    try validateConsent(room, account: account)
                    result = try await api.confirm(id: room.battleId, revision: room.revision)
                case .decline:
                    guard room.state == .pending, room.side(for: account.trainer.trainerId) == .p2 else { throw OnlineBattleFailure.invalidRequest }
                    result = try await api.decline(id: room.battleId, revision: room.revision)
                case .cancel:
                    guard [.pending, .accepted, .ready].contains(room.state) else { throw OnlineBattleFailure.invalidRequest }
                    result = try await api.cancel(id: room.battleId, revision: room.revision)
                case .prepareBattle:
                    guard let connection else { throw OnlineBattleFailure.connectionUnavailable }
                    let connected = await connection.snapshot(); try current(epoch)
                    guard connected.state == .connected, let connectionID = connected.connectionId,
                          connected.trainerId == account.trainer.trainerId, connected.groupId == account.group.groupId else { throw OnlineBattleFailure.connectionUnavailable }
                    noteConnection(connected)
                    let press = ReadyPress(revision: room.revision, connectionID: connectionID)
                    if room.state == .accepted, room.confirmed {
                        try validateConsent(room, account: account)
                        prepared[room.battleId] = press
                        do {
                            result = try await api.ready(id: room.battleId, revision: room.revision, connectionId: connectionID, engineHash: BattleEngineManifest.sha256, rulesVersion: BattleSnapshot.rules, policyVersion: BattleSnapshot.policy)
                        } catch {
                            // A refused ready call must not read as "I am ready" on the room screen.
                            if prepared[room.battleId] == press { prepared[room.battleId] = nil }
                            throw error
                        }
                    } else if room.state == .ready {
                        // The frozen inputs stay valid through later local growth. process validates both sets.
                        prepared[room.battleId] = press
                        result = room
                    } else { throw OnlineBattleFailure.invalidRequest }
                case .chooseMove(let slot):
                    // The read above may have found the round closed.
                    if room.state == .running, room.mode == .manual, !room.roundIsUnreleased {
                        presentation.holdChoice(slot: slot, battleID: room.battleId); publish(); return
                    }
                    guard room.state == .running, room.mode == .manual, room.ownChoice == nil,
                          let request = resolvers[room.battleId]?.request, request.kind == "move",
                          request.moves.contains(where: { $0.slot == slot && !$0.disabled && $0.pp > 0 }) else { throw OnlineBattleFailure.invalidRequest }
                    result = try await api.choose(id: room.battleId, roundSeq: room.roundSeq, slot: slot)
                default: throw OnlineBattleFailure.invalidRequest
                }
            } catch {
                if endsRoom { presentation.allowEndedNotice(for: room.battleId) }
                guard let rejected = error as? OnlineBattleServerError,
                      [.invalidState, .staleRevision, .staleRound, .choiceConflict].contains(rejected.code) else { throw error }
                // The room moved before the press arrived. Read it, so the person hears what actually happened.
                try current(epoch); await refresh(); try current(epoch)
                guard reconciled else { throw OnlineBattleFailure.connectionUnavailable }
                // A read during the press had its ending suppressed, and that read cannot announce it again.
                if let latest = views[room.battleId] { presentation.announceEnded(latest, previous: room.state, l: localization()) }
                switch rejected.code {
                case .staleRound: throw OnlineBattleFailure.roundPassed
                case .choiceConflict: throw OnlineBattleFailure.choiceAlreadyIn
                default: throw OnlineBattleFailure.invalidRequest
                }
            }
            try current(epoch)
        }
        // Ending a rematch request beside the result leaves the result where it is.
        let endsBesideResult = isEndingAction(action) && result.battleId != shownID
        if navigation == navigationRevision, !endsBesideResult { prefersLobby = false; selectedBattleID = staysOnSourceID ?? result.battleId }
        try await process(result, account: account, api: api, epoch: epoch)
        try rebuildRoster(); publish()
    }
    func tick() async {
        guard onlineAllowed, authenticated else { return }
        let now = clock.now()
        for pending in Array(fallback.values) where now >= pending.due { await resumeFallback(pending.work) }
        let recovery = battleRecovery.filter { now >= $0.value }.map(\.key)
        for id in recovery { await readBattle(id, epoch: generation) }
        // A battle whose last read failed waits for its own retry: this beat is for healthy matches only.
        let due = views.values.filter { room in
            room.state == .running && !recovery.contains(room.battleId) && battleRecovery[room.battleId] == nil && !parkedBattles.contains(room.battleId)
                && room.deadline.map { now * 1000 >= $0 } == true && now >= (checkedDeadlines[room.battleId] ?? 0)
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
        presentation.canStart = false; presentation.phase = .setup; presentation.account = nil; presentation.restoringAccount = false
        resetBattleRuntime(); resetExtras(); clearHistory(); historyViews = [:]; presentation.battles = []; presentation.liveLogs = []
        dropStagings()
        presentation.connectionStatus = .connection(.revoked)
        ticker?.cancel(); ticker = nil
        await api?.setAccessKey(nil)
    }
    private func handle(_ error: Error, epoch: UInt64, armsFullRead: Bool = true) async {
        guard onlineAllowed, epoch == generation, !(error is CancellationError), error as? OnlineBattleFailure != .staleGeneration else { return }
        if armsFullRead, authenticated, Self.anotherReadCouldHelp(error),
           views.values.contains(where: { $0.state == .running || $0.state == .reported }) {
            nextRecoveryRead = clock.now() + recoveryBackoff.nextDelay()
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
        } else if error as? OnlineBattleFailure == .entryChanged {
            presentation.notice = l.onlineErrorEntryChanged
        } else if error as? OnlineBattleFailure == .invalidRequest {
            // The re-read inside the action may already have named the ending.
            if !presentation.noticeSurvivesRefresh {
                // It explains a press that did nothing, so the next background read must not wipe it unread.
                presentation.notice = l.onlineErrorRoomChanged; presentation.stickyNotice = l.onlineErrorRoomChanged
            }
        } else if error as? OnlineBattleFailure == .roundPassed {
            // It also explains a press that did nothing, and it never was the connection.
            presentation.notice = l.onlineErrorRoundPassed; presentation.stickyNotice = l.onlineErrorRoundPassed
        } else if error as? OnlineBattleFailure == .choiceAlreadyIn {
            presentation.notice = l.onlineErrorChoiceAlreadyIn; presentation.stickyNotice = l.onlineErrorChoiceAlreadyIn
        } else if error as? OnlineBattleFailure == .connectionUnavailable {
            // The failed read already said why, more exactly. A revoked account has its own status line.
            if authenticated, presentation.notice == nil { presentation.notice = l.onlineErrorGeneric }
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

// MARK: Host panel (T10)

/// The host's calls: invite codes, members, reconnect codes. Each runs under its own busy flag, so a host call never
/// blocks a battle action, and every result is dropped when the account changed or the panel is no longer on screen.
/// Codes are held only in `presentation.host.secret`; nothing here logs, prints or stores one.
extension OnlineBattleSession {
    private func performHost(_ action: OnlineBattleHostAction) async {
        guard onlineAllowed, authenticated, let api, presentation.isHost else { return }
        let epoch = generation
        switch action {
        case .open:
            presentation.host.visible = true
            guard beginHostCall() else { return }
            defer { endHostCall(epoch) }
            await readInvites(api: api, epoch: epoch)
        case .refreshInvites:
            guard beginHostCall() else { return }
            defer { endHostCall(epoch) }
            await readInvites(api: api, epoch: epoch)
        case .createInvite(let choice):
            guard beginHostCall() else { return }
            defer { endHostCall(epoch) }
            presentation.host.copied = nil
            do {
                let issued = try await api.createInvite(ttlSeconds: OnlineBattleHostInviteChoice.ttlSeconds, maxUses: choice.maxUses)
                guard epoch == generation, presentation.showsHostPanel else { return }
                presentation.host.secret = .init(kind: .invite(maxUses: issued.invite.maxUses), code: issued.inviteCode, expiresAt: issued.invite.expiresAt)
                // A list that was never read stays unread: a one-row list would pass for the whole.
                if let known = presentation.host.invites {
                    presentation.host.invites = [issued.invite] + known.filter { $0.inviteId != issued.invite.inviteId }
                }
            } catch { await hostFailed(error, epoch: epoch) }
        case .revokeInvite(let id):
            guard beginHostCall() else { return }
            defer { endHostCall(epoch) }
            do {
                let revoked = try await api.revokeInvite(inviteId: id)
                guard epoch == generation, presentation.showsHostPanel else { return }
                presentation.host.invites = presentation.host.invites?.map { $0.inviteId == revoked.inviteId ? revoked : $0 }
                presentation.host.notice = localization().onlineHostRevoked
            } catch { await hostFailed(error, epoch: epoch) }
        case .issueReconnect(let id):
            guard presentation.hostMembers.contains(where: { $0.trainerId == id }), beginHostCall() else { return }
            defer { endHostCall(epoch) }
            presentation.host.copied = nil
            do {
                let issued = try await api.issueReconnectCode(trainerId: id)
                guard epoch == generation, presentation.showsHostPanel else { return }
                presentation.host.secret = .init(kind: .reconnect(trainerId: issued.trainerId), code: issued.reconnectCode, expiresAt: issued.expiresAt)
            } catch { await hostFailed(error, epoch: epoch) }
        case .confirmRemove(let id):
            guard presentation.host.pendingRemoval == id, let member = presentation.hostMembers.first(where: { $0.trainerId == id }),
                  beginHostCall() else { return }
            defer { endHostCall(epoch) }
            let name = member.displayEmail ?? localization().onlineAnonymous
            presentation.host.pendingRemoval = nil
            do {
                let revokedInvites = try await api.removeMember(trainerId: id)
                try current(epoch)
                // The server revoked every open invite with the removal, so both lists change.
                await refresh()
                guard epoch == generation, presentation.showsHostPanel else { return }
                await readInvites(api: api, epoch: epoch)
                presentation.host.notice = localization().onlineHostRemoved(name: name, revokedInvites: revokedInvites)
            } catch { await hostFailed(error, epoch: epoch) }
        // Pure presentation: applied by the presentation and never sent here.
        case .close, .chooseInvite, .askRemove, .cancelRemove, .copied, .dismissSecret, .dismissNotice: return
        }
    }

    /// False while another host call runs or the panel is not on screen. Taking the flag clears the last notice.
    private func beginHostCall() -> Bool {
        guard presentation.showsHostPanel, !presentation.host.busy else { return false }
        presentation.host.busy = true; presentation.host.notice = nil
        return true
    }
    private func endHostCall(_ epoch: UInt64) {
        if epoch == generation { presentation.host.busy = false }
    }
    private func readInvites(api: OnlineBattleAPI, epoch: UInt64) async {
        do {
            let list = try await api.invites()
            guard epoch == generation, presentation.showsHostPanel else { return }
            presentation.host.invites = list.invites; presentation.host.invitesFailed = false
        } catch {
            guard epoch == generation, presentation.showsHostPanel else { return }
            if error as? OnlineBattleFailure == .unauthorized || (error as? OnlineBattleServerError)?.code == .forbidden {
                await hostFailed(error, epoch: epoch)
            } else if !(error is CancellationError), error as? OnlineBattleFailure != .staleGeneration {
                presentation.host.invitesFailed = true
            }
        }
    }
    /// A refusal the panel can word stays in the panel; anything else takes the general path (revocation included).
    private func hostFailed(_ error: Error, epoch: UInt64) async {
        guard epoch == generation, presentation.showsHostPanel else { return }
        if let server = error as? OnlineBattleServerError, let text = localization().onlineHostServerError(server) {
            presentation.host.notice = text
            // A refusal usually means the group changed under the host: read it again.
            if server.code == .forbidden || server.code == .notFound { requestRefresh() }
            return
        }
        await handle(error, epoch: epoch)
    }
}

private extension OnlineBattleView {
    /// The room's round has not been released yet. The journal, not the deadline, is what the server keys a choice on.
    var roundIsUnreleased: Bool { roundSeq == journal.count + 1 }
    func relayView(roundSeq: Int, deadline: Double?, ownChoice: String?, journal: [OnlineBattlePair]) -> Self {
        .init(battleId: battleId, state: state, revision: revision, mode: mode, p1: p1, p2: p2,
              createdAt: createdAt, expiresAt: expiresAt, startedAt: startedAt, reportedAt: reportedAt,
              confirmed: confirmed, config: config, roundSeq: roundSeq, deadline: deadline, ownChoice: ownChoice,
              journal: journal, result: result, reason: reason, rematchOf: rematchOf)
    }
}
