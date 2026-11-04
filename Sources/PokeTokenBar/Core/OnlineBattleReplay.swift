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
        guard battle.state == .completed, let config = battle.config, battle.result != nil, battle.startedAt != nil,
              !battle.journal.isEmpty, battle.p1.snapshot != nil, battle.p2.snapshot != nil else {
            throw Failure.incompleteRecord
        }
        guard let entry = BattleEngineArchive.entry(for: config.engineHash), entry.accepts(config) else {
            throw Failure.unavailableEngine
        }
        guard battle.journal.count <= 200 else { throw Failure.verificationFailed }
        let engine: BattleEngine
        do {
            engine = try engineFactory?(config.engineHash) ?? BattleEngineArchive.engine(hash: config.engineHash)
        } catch BattleEngine.Failure.missingBundle {
            throw Failure.unavailableEngine
        } catch Failure.unavailableEngine {
            throw Failure.unavailableEngine
        } catch {
            throw Failure.verificationFailed
        }
        do {
            let resolver = try OnlineBattleResolver.completedResolver(battle: battle, localTrainerID: localTrainerID, engine: engine)
            defer { resolver.close() }
            var frames: [Frame] = []
            func appendFrame() throws {
                guard let view = resolver.view else { throw Failure.verificationFailed }
                frames.append(Frame(view: view, logs: OnlineBattleHistoryText.logs(resolver.logs, localSide: resolver.localSide),
                                    roundSeq: resolver.processedRoundSeq))
            }
            try appendFrame()
            for count in 1...battle.journal.count {
                try resolver.consume(journal: Array(battle.journal.prefix(count)))
                try appendFrame()
            }
            // Discard the effect proof. A replay retains only verified presentation values, no effect capability.
            _ = try resolver.verifyCompleted(battle)
            self.battleID = battle.battleId
            self.localSide = resolver.localSide
            self.frames = frames
            self.verified = true
        } catch {
            throw Failure.verificationFailed
        }
    }
}
