import Foundation
import Observation

struct OnlineBattleStagePlan: Equatable, Sendable {
    let skipsPlaying: Bool
    let instantRounds: Int
    let stagedRounds: Int
    static func decide(newRounds: Int, mode: OnlineBattleMode, visible: Bool, secondsLeft: TimeInterval?, playing: Bool) -> Self {
        .init(skipsPlaying: false, instantRounds: 0, stagedRounds: 0)
    }
}

@MainActor @Observable
final class OnlineBattleStaging {
    let playback: PracticePlayback
    let frame: BattleSeatFrame
    private(set) var lastView: BattleView?
    private(set) var lastRequest: BattleRequest?
    var isPlaying: Bool { playback.isPlaying }
    init(resolver: OnlineBattleResolver, clock: @escaping () -> TimeInterval) {
        playback = PracticePlayback(clock: clock); frame = BattleSeatFrame(local: .p1)
    }
    func ingest(_ resolver: OnlineBattleResolver, mode: OnlineBattleMode, visible: Bool, secondsLeft: TimeInterval?) {}
    func markResync() {}
    func advance() {}
    func skipToEnd() {}
    func atRest(_ side: PracticeSide) -> PracticeDisplaySide? { nil }
    func shown(_ side: PracticeSide) -> PracticeDisplaySide? { nil }
}
