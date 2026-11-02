import Foundation

/// App-lifetime owner: closing a popover never stops the server clock, replay, or settlement.
@MainActor
final class OnlineBattleSession {
    let presentation = OnlineBattlePresentation()
    private var settings: OnlineBattleSettings
    private let credentials: any OnlineBattleCredentialStoring
    private let transport: any OnlineBattleHTTPTransport
    private let effects: any OnlineBattleEffects
    private let engineFactory: () throws -> BattleEngine
    private let connectionFactory: (OnlineBattleConnection.Observer) -> any OnlineBattleConnecting
    private let saveSettings: (OnlineBattleSettings) throws -> Void
    private let rosterProvider: (() throws -> [PracticeCandidate])?
    private let clock: OnlineBattleConnectionClock
    private let automaticTicks: Bool
    private var api: OnlineBattleAPI?
    private var origin: OnlineBattleOrigin?
    private var connection: (any OnlineBattleConnecting)?
    private var bootstrapped = false
    private var authenticated = false
    private var generation: UInt64 = 0
    private var pendingGrant: OnlineBattleGrant?
    private var refreshTask: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var actionInFlight = false
    private var reconciled = false
    private var popoverOpen = false
    private var views: [String: OnlineBattleView] = [:]
    private var resolvers: [String: OnlineBattleResolver] = [:]
    private var selectedBattleID: String?
    private var checkedDeadlines: [String: Double] = [:]
    private struct ChallengeIntent {
        let requestID: String
        let target: String
        let mode: OnlineBattleMode
        let snapshot: OnlineBattleSnapshot
    }
    private var challengeIntent: ChallengeIntent?

    init(settings: OnlineBattleSettings, credentials: any OnlineBattleCredentialStoring,
         transport: any OnlineBattleHTTPTransport = OnlineBattleURLSessionTransport(), effects: any OnlineBattleEffects,
         engineFactory: @escaping () throws -> BattleEngine,
         connectionFactory: @escaping (OnlineBattleConnection.Observer) -> any OnlineBattleConnecting,
         saveSettings: @escaping (OnlineBattleSettings) throws -> Void = { _ in },
         rosterProvider: (() throws -> [PracticeCandidate])? = nil,
         clock: OnlineBattleConnectionClock = .init(), automaticTicks: Bool = true) {
        self.settings = settings; self.credentials = credentials; self.transport = transport
        self.effects = effects; self.engineFactory = engineFactory; self.connectionFactory = connectionFactory
        self.saveSettings = saveSettings; self.rosterProvider = rosterProvider
        self.clock = clock; self.automaticTicks = automaticTicks
        presentation.serverAddress = settings.serverURL ?? ""
        presentation.onAction = { [weak self] action in Task { await self?.perform(action) } }
    }
    func bootstrap() async {
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
            resolvers = [:]; views = [:]; selectedBattleID = nil; checkedDeadlines = [:]
            api = nil; origin = nil; pendingGrant = nil; challengeIntent = nil
            authenticated = false; reconciled = false; actionInFlight = false
            settings = next; bootstrapped = false
            presentation.serverAddress = next.serverURL ?? ""
            presentation.account = nil; presentation.members = []; presentation.battles = []
            presentation.room = nil; presentation.arena = nil; presentation.request = nil
            presentation.result = nil; presentation.recoveryCode = nil; presentation.notice = nil
            presentation.canRetryCredentialSave = false; presentation.canStart = false
            presentation.phase = .setup; presentation.isBusy = false
            await old?.stop()
            await bootstrap()
        } catch { await handle(error, epoch: generation) }
    }
    private func current(_ epoch: UInt64) throws {
        guard epoch == generation, !Task.isCancelled else { throw OnlineBattleFailure.staleGeneration }
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
            guard authenticated else { return }
            await refresh()
        }
    }
    func join(inviteCode: String, email: String) async {
        await obtainGrant { try await $0.join(inviteCode: inviteCode, displayEmail: email) }
    }
    private func obtainGrant(_ request: (OnlineBattleAPI) async throws -> OnlineBattleGrant) async {
        guard let api, pendingGrant == nil else { return }
        let epoch = generation
        do {
            let grant = try await request(api); try current(epoch)
            pendingGrant = grant; presentation.canRetryCredentialSave = true
            await retryCredentialSave()
        } catch { await handle(error, epoch: epoch) }
    }
    func retryCredentialSave() async {
        guard let grant = pendingGrant, let origin else { return }
        let epoch = generation
        do {
            try await credentials.save(grant.accessKey, scope: .init(profileID: settings.profileID, origin: origin))
            try current(epoch)
            pendingGrant = nil; presentation.canRetryCredentialSave = false
            presentation.account = grant.account; presentation.recoveryCode = grant.recoveryCode; presentation.notice = nil
            try await activate(grant.accessKey, epoch: epoch)
            await refresh()
        } catch { await handle(error, epoch: epoch) }
    }
    /// One shared read owns reconciliation. Notifications never apply effects directly.
    func refresh() async {
        guard authenticated, let api else { return }
        if let refreshTask { await refreshTask.value; return }
        let epoch = generation
        let task = Task { [weak self] in await self?.readAll(api: api, epoch: epoch) }
        let joined = Task { _ = await task.value }
        refreshTask = joined
        await joined.value
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
            presentation.account = account; presentation.members = group.members
            presentation.notice = nil; try rebuildRoster()
            // Old unapplied completions are reconciled before accepting new entries or acquiring newer holds.
            for room in battles.sorted(by: { ($0.state == .completed ? 0 : 1, $0.createdAt) < ($1.state == .completed ? 0 : 1, $1.createdAt) }) {
                try current(epoch)
                try await process(room, account: account, api: api, epoch: epoch)
            }
            try current(epoch); reconciled = true
            try rebuildRoster(); publish()
            if let connection { let snapshot = await connection.snapshot(); try current(epoch); presentation.canStart = snapshot.state == .connected }
        } catch { reconciled = false; await handle(error, epoch: epoch) }
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
    private func process(_ initial: OnlineBattleView, account: OnlineBattleAccount, api: OnlineBattleAPI, epoch: UInt64) async throws {
        var room = initial
        // An automatic battle has at most 200 public pairs. Each response must make progress.
        for _ in 0..<202 {
            try current(epoch)
            guard accepts(room) else { return }
            guard let side = room.side(for: account.trainer.trainerId) else { throw OnlineBattleFailure.invalidResponse }
            views[room.battleId] = room
            let key = try receiptKey(room, account: account)
            if [.void, .cancelled, .declined, .expired].contains(room.state) {
                try effects.releaseOnlineBattle(key: key)
                resolvers.removeValue(forKey: room.battleId)?.close()
                if room.state == .void {
                    presentation.result = .init(title: "경기 무효", detail: "체력과 경험치는 바뀌지 않았어요.", xpAwarded: 0, hpApplied: false, isVoid: true)
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
                resolver.close(); resolvers[room.battleId] = nil
                // One authoritative refetch and a fresh engine, then fail closed if the server remains invalid.
                let fresh = try await api.battle(id: room.battleId); try current(epoch)
                let rebuilt = try OnlineBattleResolver(battle: fresh, localTrainerID: account.trainer.trainerId, engine: engineFactory())
                do { try rebuilt.consume(journal: fresh.journal) } catch { rebuilt.close(); throw error }
                resolvers[room.battleId] = rebuilt; room = fresh; continue
            }
            publish()
            guard room.state == .running || room.state == .reported else { return }
            if let report = try resolver.terminalReport() {
                // Sending the identical deterministic report is safe after a response was lost.
                let updated = try await api.report(id: room.battleId, report: report); try current(epoch)
                if updated == room { return }
                room = updated
                if room.state == .reported { views[room.battleId] = room; publish(); return }
                continue
            }
            guard room.state == .running, resolver.processedRoundSeq == room.roundSeq, room.roundSeq > 0 else { return }
            let updated = try await api.advance(id: room.battleId, processedRoundSeq: resolver.processedRoundSeq); try current(epoch)
            guard updated != room else { return }
            room = updated
        }
        throw OnlineBattleFailure.invalidResponse
    }
    private func settle(_ battle: OnlineBattleView, account: OnlineBattleAccount) throws {
        let resolver = try OnlineBattleResolver(battle: battle, localTrainerID: account.trainer.trainerId, engine: engineFactory())
        defer { resolver.close() }
        let proof = try resolver.verifyCompleted(battle)
        guard presentation.roster.contains(where: { $0.id == proof.localInstanceID }) else { throw OnlineBattleFailure.invalidResponse }
        let outcome: OnlineBattleOutcome = proof.winner == .draw ? .draw : proof.winner.rawValue == proof.localSide.rawValue ? .win : .loss
        let receipt = try effects.applyVerifiedOnlineBattleEffect(.init(key: receiptKey(battle, account: account), resultHash: proof.resultHash,
            localInstanceID: proof.localInstanceID, remainingHPShare: proof.remainingHPShare, outcome: outcome))
        presentation.result = .init(title: outcome == .win ? "승리" : outcome == .loss ? "패배" : "무승부",
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
              let snapshot = presentation.roster.first(where: { $0.id == selected })?.snapshot,
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
    private func publish() {
        presentation.battles = views.values.sorted { $0.createdAt > $1.createdAt }
        let room = selectedBattleID.flatMap { views[$0] } ?? presentation.battles.first(where: { $0.state.isActive }) ?? presentation.battles.first
        presentation.room = room
        guard let room, let account = presentation.account else { presentation.phase = authenticated ? .lobby : .setup; return }
        presentation.localSide = room.side(for: account.trainer.trainerId) ?? .p1
        presentation.deadline = room.deadline.map { Date(timeIntervalSince1970: $0 / 1000) }
        presentation.choiceSubmitted = room.ownChoice != nil
        presentation.arena = resolvers[room.battleId]?.view; presentation.request = resolvers[room.battleId]?.request
        switch room.state {
        case .pending, .accepted, .ready: presentation.phase = .room
        case .running: presentation.phase = .arena
        case .reported: presentation.phase = .verifying
        case .completed, .void: presentation.phase = .result
        case .declined, .cancelled, .expired: presentation.phase = .lobby
        }
    }
    func perform(_ action: OnlineBattleUIAction) async {
        switch action {
        case .setPopoverVisible(let open): popoverOpen = open; await connection?.setPopoverOpen(open); return
        case .selectEntry(let id): presentation.selectedEntryID = id; challengeIntent = nil; return
        case .selectOpponent(let id): presentation.selectedOpponentID = id; challengeIntent = nil; return
        case .setMode(let mode): presentation.mode = mode; challengeIntent = nil; return
        case .acknowledgeRecoveryCode: presentation.recoveryCode = nil; return
        case .dismissResult: selectedBattleID = nil; presentation.result = nil; presentation.phase = .lobby; return
        case .configureServer(let value): await configureServer(value); return
        default: break
        }
        guard !actionInFlight else { return }
        actionInFlight = true; presentation.isBusy = true
        let epoch = generation
        defer { if epoch == generation { actionInFlight = false; presentation.isBusy = false } }
        switch action {
        case .join(let code, let email): await join(inviteCode: code, email: email)
        case .recover(let code): await obtainGrant { try await $0.recover(recoveryCode: code) }
        case .reconnect(let code): await obtainGrant { try await $0.reconnect(reconnectCode: code) }
        case .retryCredentialSave: await retryCredentialSave()
        case .refresh: await refresh()
        case .openBattle(let id): selectedBattleID = id; publish()
        default:
            do { try await battleAction(action, epoch: epoch) }
            catch { publish(); await handle(error, epoch: epoch) }
        }
    }
    private func battleAction(_ action: OnlineBattleUIAction, epoch: UInt64) async throws {
        guard authenticated, reconciled, let api, let account = presentation.account else { throw OnlineBattleFailure.invalidRequest }
        var result: OnlineBattleView
        if case .challenge = action {
            let snapshot = try selectedSnapshot()
            guard let target = presentation.selectedOpponentID, target != account.trainer.trainerId else { throw OnlineBattleFailure.invalidRequest }
            if challengeIntent?.snapshot != snapshot || challengeIntent?.target != target || challengeIntent?.mode != presentation.mode {
                challengeIntent = .init(requestID: UUID().uuidString, target: target, mode: presentation.mode, snapshot: snapshot)
            }
            let intent = challengeIntent!
            result = try await api.createBattle(requestId: intent.requestID, targetTrainerId: intent.target, mode: intent.mode, snapshot: intent.snapshot)
            try current(epoch)
            // A local evolution, heal, or practice entry during the request invalidates consent.
            guard (try? selectedSnapshot()) == snapshot else {
                let cancelled = try await api.cancel(id: result.battleId, revision: result.revision); try current(epoch)
                try await process(cancelled, account: account, api: api, epoch: epoch)
                throw OnlineBattleFailure.invalidRequest
            }
            challengeIntent = nil
        } else {
            guard let room = presentation.room else { throw OnlineBattleFailure.invalidRequest }
            switch action {
            case .accept:
                guard room.state == .pending, room.side(for: account.trainer.trainerId) == .p2 else { throw OnlineBattleFailure.invalidRequest }
                let snapshot = try selectedSnapshot(allow: receiptKey(room, account: account))
                result = try await api.accept(id: room.battleId, revision: room.revision, snapshot: snapshot); try current(epoch)
                guard (try? selectedSnapshot(allow: receiptKey(result, account: account), id: snapshot.instanceId)) == snapshot else {
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
                result = try await api.decline(id: room.battleId, revision: room.revision)
            case .cancel:
                guard [.pending, .accepted, .ready].contains(room.state) else { throw OnlineBattleFailure.invalidRequest }
                result = try await api.cancel(id: room.battleId, revision: room.revision)
            case .prepareBattle:
                guard let connection else { throw OnlineBattleFailure.invalidRequest }
                let connected = await connection.snapshot(); try current(epoch)
                guard connected.state == .connected, let connectionID = connected.connectionId,
                      connected.trainerId == account.trainer.trainerId, connected.groupId == account.group.groupId else { throw OnlineBattleFailure.invalidRequest }
                try validateConsent(room, account: account)
                if room.state == .accepted, room.confirmed {
                    result = try await api.ready(id: room.battleId, revision: room.revision, connectionId: connectionID, engineHash: BattleEngineManifest.sha256, rulesVersion: BattleSnapshot.rules, policyVersion: BattleSnapshot.policy)
                } else if room.state == .ready {
                    // Construction validates both frozen sets before the acknowledgement is sent.
                    let verifier = try OnlineBattleResolver(battle: room, localTrainerID: account.trainer.trainerId, engine: engineFactory()); verifier.close()
                    result = try await api.start(id: room.battleId, revision: room.revision, connectionId: connectionID, readyToken: room.config!.readyToken, engineHash: BattleEngineManifest.sha256)
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
        selectedBattleID = result.battleId
        try await process(result, account: account, api: api, epoch: epoch)
        try rebuildRoster(); publish()
    }
    func tick() async {
        guard authenticated else { return }
        let now = clock.now() * 1000
        let due = views.values.filter { $0.state == .running && $0.deadline.map { now >= $0 && checkedDeadlines[$0.description] == nil } == true }
        guard !due.isEmpty else { return }
        for room in due { if let deadline = room.deadline { checkedDeadlines[deadline.description] = deadline } }
        await refresh()
    }
    private func revoke(epoch: UInt64) async {
        guard epoch == generation else { return }
        authenticated = false; reconciled = false
        presentation.canStart = false; presentation.phase = .setup; presentation.account = nil
        presentation.connectionStatus = "접속키가 만료되었어요. 복구코드로 다시 연결해 주세요"
        ticker?.cancel(); ticker = nil
        await api?.setAccessKey(nil)
    }
    private func handle(_ error: Error, epoch: UInt64) async {
        guard epoch == generation, !(error is CancellationError), error as? OnlineBattleFailure != .staleGeneration else { return }
        if error as? OnlineBattleFailure == .unauthorized {
            if let connection { let snapshot = await connection.snapshot(); guard epoch == generation else { return }; await connection.authenticationFailed(generation: snapshot.generation) }
            await revoke(epoch: epoch); return
        }
        if error as? OnlineBattleFailure == .credentialsUnavailable {
            presentation.notice = "접속키를 안전하게 저장하지 못했어요. 저장을 다시 시도해 주세요."
        } else if error as? OnlineBattleFailure == .credentialsDisabled {
            presentation.notice = "접속키 저장이 꺼져 있어요. 설정을 확인해 주세요."
        } else if error as? OnlineBattleFailure == .invalidRequest {
            presentation.notice = "출전 정보가 바뀌었어요. 최신 정보를 확인하고 다시 동의해 주세요."
        } else if error is OnlineBattleResolver.Failure {
            presentation.notice = "전투 결과를 확인하지 못해 체력과 경험치를 반영하지 않았어요."
        } else {
            presentation.notice = "온라인 정보를 확인하지 못했어요. 연결을 확인하고 다시 시도해 주세요."
        }
    }
}
