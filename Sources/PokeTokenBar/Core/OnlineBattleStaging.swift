import Foundation
import Observation

/// What to do with the rounds a read just brought. Pure, so the whole table has a test.
///
/// | Condition                      | Applied at once                  | Staged           |
/// |--------------------------------|----------------------------------|------------------|
/// | Hidden                         | everything, beat on screen too   | nothing          |
/// | Manual, under six seconds left | everything, beat on screen too   | nothing          |
/// | Manual otherwise               | all but the last, beat on screen | the last round   |
/// | Automatic, one new round       | nothing                          | joins the queue  |
/// | Automatic, two or more         | all but the last, beat on screen | the last round   |
///
/// No deadline counts as enough time: right after a WebSocket round it is nil until the next round opens.
struct OnlineBattleStagePlan: Equatable, Sendable {
    /// Finish the beat on screen and everything queued first.
    let skipsPlaying: Bool
    /// The first new rounds that apply without staging.
    let instantRounds: Int
    /// The new rounds after those, which stage.
    let stagedRounds: Int

    static let manualStagingMinimumSeconds: TimeInterval = 6

    static func decide(newRounds: Int, mode: OnlineBattleMode, visible: Bool, secondsLeft: TimeInterval?, playing: Bool) -> Self {
        let rounds = max(0, newRounds)
        let shortOfTime = mode == .manual && secondsLeft.map { $0 < manualStagingMinimumSeconds } == true
        if !visible || shortOfTime { return .init(skipsPlaying: playing, instantRounds: rounds, stagedRounds: 0) }
        // A read with nothing new (the advance response, a refresh) leaves the beat being watched alone.
        if rounds == 0 { return .init(skipsPlaying: false, instantRounds: 0, stagedRounds: 0) }
        if mode == .auto, rounds == 1 { return .init(skipsPlaying: false, instantRounds: 0, stagedRounds: 1) }
        return .init(skipsPlaying: playing, instantRounds: rounds - 1, stagedRounds: 1)
    }
}

/// The display side of one online battle. Progress (replay, advance, report, settlement) runs at network speed
/// in `OnlineBattleSession`; this only follows it with the practice playback, so a beat never holds an advance,
/// a move choice or the server's clock. The session owns one per battle because the popover's views do not
/// outlive a close.
@MainActor @Observable
final class OnlineBattleStaging {
    let playback: PracticePlayback
    /// Always from `resolver.localSide`; the arena reads combatants through it, never `view.p1`/`view.p2`.
    let frame: BattleSeatFrame
    /// The newest view and request. They outlive the resolver, so a final beat still draws after a completion.
    private(set) var lastView: BattleView?
    private(set) var lastRequest: BattleRequest?
    var isPlaying: Bool { playback.isPlaying }

    @ObservationIgnored private var parser: PracticeEventParser
    /// Rounds handed to the playback; the opening (segment 0) is tracked by `seeded`.
    @ObservationIgnored private var stagedRounds = 0
    @ObservationIgnored private var seeded = false
    @ObservationIgnored private var needsResync = false

    init(resolver: OnlineBattleResolver, clock: @escaping () -> TimeInterval) {
        frame = BattleSeatFrame(local: resolver.localSide)
        parser = PracticeEventParser(frame: frame)
        playback = PracticePlayback(clock: clock)
    }

    /// Takes every round the resolver has consumed since the last call.
    func ingest(_ resolver: OnlineBattleResolver, mode: OnlineBattleMode, visible: Bool, secondsLeft: TimeInterval?) {
        lastView = resolver.view; lastRequest = resolver.request
        if needsResync { resync(resolver); return }
        if !seeded {
            // The opening never plays: `switch` seeds the display, and abilities wait for the next beat.
            seeded = true
            playback.enqueue(events(ofSegment: 0, in: resolver))
            playback.skipToEnd()
        }
        let plan = OnlineBattleStagePlan.decide(newRounds: resolver.journal.count - stagedRounds, mode: mode, visible: visible,
                                                secondsLeft: secondsLeft, playing: playback.isPlaying)
        if plan.skipsPlaying { playback.skipToEnd() }
        if plan.instantRounds > 0 {
            for _ in 0..<plan.instantRounds { enqueueNextRound(from: resolver) }
            playback.skipToEnd()
        }
        for _ in 0..<plan.stagedRounds { enqueueNextRound(from: resolver) }
        checkRestingDisplay()
    }

    /// The resolver was replaced after a refetch. The next `ingest` seeds values instead of staging its log.
    func markResync() { needsResync = true }

    /// Moves the beat on screen along the clock. The session's driver calls it.
    func advance() {
        playback.advance()
        checkRestingDisplay()
    }

    /// Plays everything queued at once: the screen is hidden, or the user asked for the result.
    func skipToEnd() {
        playback.skipToEnd()
        checkRestingDisplay()
    }

    /// What a card shows between beats. It comes from the engine's view rather than the parsed display, so a
    /// parsing gap can never outlive the beat that showed it. The display would not do either: passing nil
    /// to the practice card leaves `fainted` false.
    func atRest(_ side: PracticeSide) -> PracticeDisplaySide? {
        guard let lastView else { return nil }
        let pokemon = frame.pokemon(side, in: lastView), fainted = pokemon.hp == 0
        return PracticeDisplaySide(hp: pokemon.hp, maxHP: pokemon.maxhp,
                                   status: fainted || pokemon.status.isEmpty ? nil : pokemon.status, fainted: fainted)
    }

    /// What a card shows now: a beat's outcome while it plays, otherwise the authoritative view.
    func shown(_ side: PracticeSide) -> PracticeDisplaySide? { playback.beat?.after[side] ?? atRest(side) }

    private func enqueueNextRound(from resolver: OnlineBattleResolver) {
        stagedRounds += 1
        var events = events(ofSegment: stagedRounds, in: resolver)
        let pair = resolver.journal[stagedRounds - 1]
        if (frame.seat(.player) == .p1 ? pair.p1 : pair.p2) == .timeout { events.insert(.timedOut, at: 0) }
        playback.enqueue(events)
    }

    /// Segment 0 is the opening; segment `i` is what round `i` wrote to the log.
    private func events(ofSegment index: Int, in resolver: OnlineBattleResolver) -> [PracticeEvent] {
        let start = index == 0 ? 0 : resolver.roundLogEnds[index - 1]
        let parsed = parser.parse(Array(resolver.logs[start..<resolver.roundLogEnds[index]]))
        return parser.merging(resolver.roundReveals[index], into: parsed)
    }

    /// Commits what was staged, then seeds from the fresh view. No beat is made, so the history keeps no copy
    /// of the rounds the rebuilt log repeats. The parser still reads them for each side's remembered HP.
    private func resync(_ resolver: OnlineBattleResolver) {
        needsResync = false; seeded = true
        playback.skipToEnd()
        _ = parser.parse(resolver.logs)
        stagedRounds = resolver.journal.count
        guard let view = resolver.view else { return }
        let own = frame.pokemon(.player, in: view), foe = frame.pokemon(.opponent, in: view)
        playback.enqueue([.switchIn(.player, hp: own.hp, maxHP: own.maxhp), .switchIn(.opponent, hp: foe.hp, maxHP: foe.maxhp), .turn(view.turn)])
    }

    /// Between beats the parsed display and the engine's view must agree on HP. Only HP: a resync seeds no
    /// status and some lines that change a status are not modelled, and neither reaches a card at rest.
    private func checkRestingDisplay() {
        guard !playback.isPlaying else { return }
        for side in [PracticeSide.player, .opponent] {
            guard let shown = playback.display[side], let rest = atRest(side) else { continue }
            if shown.hp != rest.hp || shown.maxHP != rest.maxHP {
                assertionFailure("Staged \(side) HP \(shown.hp)/\(shown.maxHP) disagrees with the view's \(rest.hp)/\(rest.maxHP)")
            }
        }
    }
}
