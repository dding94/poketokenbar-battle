import Foundation

/// Consumes only the server's closed relay tokens. The session refetches and rebuilds on prefix failure.
@MainActor
final class OnlineBattleResolver {
    enum Failure: Error, Equatable { case invalidConfiguration, needsRefetch, invalidJournal, resolutionFailed, resultMismatch }
    init(battle: OnlineBattleView, localTrainerID: String, engine: BattleEngine) throws { }
    func consume(journal: [OnlineBattlePair]) throws { }
    func terminalReport() throws -> OnlineBattleReport? { nil }
}
