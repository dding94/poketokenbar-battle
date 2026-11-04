import Foundation

/// Immutable, locally verified playback; never owns a live session or applies completion effects.
@MainActor
struct OnlineBattleReplay {
    struct Frame {
        let view: BattleView
        let logs: [String]
        let roundSeq: Int
    }
    enum Failure: Error, Equatable { case unavailableEngine, incompleteRecord, verificationFailed }
    let battleID: String
    let localSide: OnlineBattleSide
    let frames: [Frame]
    let verified: Bool

    init(battle: OnlineBattleView, localTrainerID: String,
         engineFactory: ((String) throws -> BattleEngine)? = nil) throws {
        throw Failure.incompleteRecord
    }
}
