import Foundation

/// App-lifetime online coordinator. Its injectable boundaries never require a live account in tests.
@MainActor
final class OnlineBattleSession {
    let presentation = OnlineBattlePresentation()
    init(settings: OnlineBattleSettings, credentials: any OnlineBattleCredentialStoring,
         transport: any OnlineBattleHTTPTransport, effects: any OnlineBattleEffects,
         engineFactory: @escaping () throws -> BattleEngine,
         connectionFactory: @escaping (OnlineBattleConnection.Observer) -> any OnlineBattleConnecting,
         saveSettings: @escaping (OnlineBattleSettings) throws -> Void = { _ in },
         rosterProvider: (() throws -> [PracticeCandidate])? = nil,
         clock: OnlineBattleConnectionClock = .init(), automaticTicks: Bool = true) {}
    func bootstrap() async {}
    func join(inviteCode: String, email: String) async {}
    func retryCredentialSave() async {}
    func refresh() async {}
    func configureServer(_ value: String) async {}
}
