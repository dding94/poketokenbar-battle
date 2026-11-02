import Foundation

/// App-lifetime online coordinator. Its injectable boundaries never require a live account in tests.
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
    private var pendingGrant: OnlineBattleGrant?

    init(settings: OnlineBattleSettings, credentials: any OnlineBattleCredentialStoring,
         transport: any OnlineBattleHTTPTransport, effects: any OnlineBattleEffects,
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
    }
    func bootstrap() async {
        guard !bootstrapped else { return }
        bootstrapped = true
        do {
            try rebuildRoster()
            guard let address = settings.serverURL else { return }
            let origin = try OnlineBattleOrigin(address)
            self.origin = origin
            let api = OnlineBattleAPI(origin: origin, transport: transport); self.api = api
            let key = try await credentials.load(scope: .init(profileID: settings.profileID, origin: origin))
            guard let key else { return }
            await activate(key)
            await refresh()
        } catch { show(error) }
    }
    func join(inviteCode: String, email: String) async {
        guard let api, pendingGrant == nil else { return }
        do {
            pendingGrant = try await api.join(inviteCode: inviteCode, displayEmail: email)
            await retryCredentialSave()
        } catch { show(error) }
    }
    func retryCredentialSave() async {
        guard let grant = pendingGrant, let origin else { return }
        do {
            try await credentials.save(grant.accessKey, scope: .init(profileID: settings.profileID, origin: origin))
            pendingGrant = nil
            presentation.account = grant.account
            presentation.recoveryCode = grant.recoveryCode
            presentation.notice = nil
            await activate(grant.accessKey)
            await refresh()
        } catch { show(error) }
    }
    private func activate(_ key: String) async {
        await api?.setAccessKey(key)
        let connection = connectionFactory { _ in }; self.connection = connection
        await connection.configure(origin: origin, accessKey: key)
    }
    func refresh() async {
        guard let api else { return }
        do {
            let account = try await api.me()
            let group = try await api.group()
            let battles = try await api.listBattles()
            presentation.account = account; presentation.members = group.members; presentation.battles = battles
            presentation.phase = .lobby
            try rebuildRoster()
            for battle in battles where battle.state == .completed {
                try settle(battle, account: account)
            }
        } catch { show(error) }
    }
    private func settle(_ battle: OnlineBattleView, account: OnlineBattleAccount) throws {
        guard let origin else { throw OnlineBattleFailure.invalidSettings }
        let resolver = try OnlineBattleResolver(battle: battle, localTrainerID: account.trainer.trainerId, engine: engineFactory())
        defer { resolver.close() }
        let proof = try resolver.verifyCompleted(battle)
        guard presentation.roster.contains(where: { $0.id == proof.localInstanceID }) else { throw OnlineBattleFailure.invalidResponse }
        let outcome: OnlineBattleOutcome = proof.winner == .draw ? .draw : proof.winner.rawValue == proof.localSide.rawValue ? .win : .loss
        let key = OnlineBattleReceiptKey(scope: .init(originHash: origin.hash, groupID: account.group.groupId, trainerID: account.trainer.trainerId), battleID: battle.battleId)
        let receipt = try effects.applyVerifiedOnlineBattleEffect(.init(key: key, resultHash: proof.resultHash,
            localInstanceID: proof.localInstanceID, remainingHPShare: proof.remainingHPShare, outcome: outcome))
        presentation.phase = .result
        presentation.result = .init(title: outcome == .win ? "승리" : outcome == .loss ? "패배" : "무승부",
            detail: "양쪽의 전투 결과가 일치해 반영했어요.", xpAwarded: Int64(receipt.grantedXP), hpApplied: true, isVoid: false)
    }
    private func rebuildRoster() throws {
        if let rosterProvider { presentation.roster = try rosterProvider(); return }
        guard let source = effects.companionState() else { presentation.roster = []; return }
        presentation.roster = PracticeRoster(state: source.state, activeName: source.activeName, engine: try engineFactory()).candidates
    }
    private func show(_ error: Error) {
        presentation.notice = error as? OnlineBattleFailure == .credentialsUnavailable
            ? "접속키를 안전하게 저장하지 못했어요. 저장을 다시 시도해 주세요."
            : "온라인 정보를 확인하지 못했어요. 연결을 확인하고 다시 시도해 주세요."
    }
    func configureServer(_ value: String) async {}
}
