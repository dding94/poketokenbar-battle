import XCTest
@testable import PokeTokenBar

/// T18: the turn bar reads the server's deadline and never moves it, and the opening splash is shown once.
/// The bar's cases are pure, so every state the arena can be in has its own assertion.
@MainActor
final class OnlineBattleTurnClockTests: XCTestCase {
    private typealias Footer = OnlineBattleArena.Footer
    private typealias Clock = OnlineBattleTurnClock
    private let now = Date(timeIntervalSince1970: 1_000)
    private func at(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(seconds) }
    private func state(_ footer: Footer, mode: OnlineBattleMode = .manual, deadline: Date?, playing: Bool = false) -> Clock.State {
        Clock.state(mode: mode, footer: footer, deadline: deadline, playing: playing, now: now)
    }
    private func arenaView(_ model: OnlineBattlePresentation) -> OnlineBattleArena {
        OnlineBattleArena(model: model, l: L(.ko), artwork: false, speciesNameProvider: OnlineBattleSyntheticNameProvider(),
                          speciesNameStore: PokemonNameDisplayStore())
    }

    // MARK: choosing

    func testChoosingCountsDownFromTheServersDeadline() {
        XCTAssertEqual(state(.moves, deadline: at(30)), .counting(remaining: 30, fraction: 1, mine: true))
        // Quarter seconds are exact in a Date, so the fraction can be compared as it is.
        XCTAssertEqual(state(.moves, deadline: at(12.25)), .counting(remaining: 13, fraction: 12.25 / 30, mine: true))
        XCTAssertEqual(state(.moves, deadline: at(0.5)), .counting(remaining: 1, fraction: 0.5 / 30, mine: true))
    }

    func testAPastDeadlineEmptiesTheBarAndAFarOneNeverOverfillsIt() {
        XCTAssertEqual(state(.moves, deadline: at(-3)), .counting(remaining: 0, fraction: 0, mine: true))
        XCTAssertEqual(state(.moves, deadline: at(45)), .counting(remaining: 45, fraction: 1, mine: true))
    }

    /// Right after a WebSocket round the deadline is nil until the next round opens. That is not zero seconds left.
    func testNoDeadlineIsPreparingTheNextTurnNeverAnOrangeZero() {
        XCTAssertEqual(state(.moves, deadline: nil), .preparing)
        XCTAssertEqual(state(.sent, deadline: nil), .preparing)
        XCTAssertFalse(state(.moves, deadline: nil).isUrgent)
        XCTAssertNil(OnlineBattleArena.remainingSeconds(deadline: nil, now: now), "no deadline is not 0 seconds")
    }

    func testTheLastFiveSecondsAreUrgentOnlyWhileIAmTheOneChoosing() {
        XCTAssertFalse(state(.moves, deadline: at(5.5)).isUrgent, "6 seconds left")
        XCTAssertTrue(state(.moves, deadline: at(5)).isUrgent, "5 seconds left")
        XCTAssertTrue(state(.moves, deadline: at(0.2)).isUrgent)
        XCTAssertTrue(state(.moves, deadline: at(-1)).isUrgent, "a deadline that passed before the server answered")
        // After my choice the clock still runs, for the other side; the auto-pick is not mine to fear.
        XCTAssertEqual(state(.sent, deadline: at(3)), .counting(remaining: 3, fraction: 3 / 30, mine: false))
        XCTAssertFalse(state(.sent, deadline: at(3)).isUrgent)
    }

    // MARK: beats playing, forced turns, automatic battles, waiting

    /// D6: a beat playing neither pauses nor restarts the clock. The state is the same with or without it.
    func testBeatsPlayingDoNotTouchTheClock() {
        for footer in [Footer.moves, .sent, .waiting, .forced, .automatic] {
            for deadline in [at(30), at(4), at(-1), nil] {
                XCTAssertEqual(state(footer, deadline: deadline, playing: true), state(footer, deadline: deadline, playing: false),
                               "\(footer) \(String(describing: deadline))")
            }
        }
        XCTAssertEqual(state(.moves, deadline: at(20), playing: true), .counting(remaining: 20, fraction: 20 / 30, mine: true))
    }

    func testNobodyIsWaitedOnInAnAutomaticBattleAForcedActionOrTheLastBeatsOfARound() {
        for deadline in [at(30), at(4), nil] {
            XCTAssertEqual(state(.automatic, mode: .auto, deadline: deadline), .idle, "automatic")
            XCTAssertEqual(state(.moves, mode: .auto, deadline: deadline), .idle, "automatic whatever the footer says")
            XCTAssertEqual(state(.forced, deadline: deadline), .idle, "the engine takes the action itself")
            XCTAssertEqual(state(.waiting, deadline: deadline), .idle, "a terminal round's last beats")
        }
    }

    func testOnlyACountingBarTicksAndItsTicksEndAtTheDeadline() {
        XCTAssertTrue(state(.moves, deadline: at(20)).ticks)
        XCTAssertTrue(state(.sent, deadline: at(20)).ticks)
        XCTAssertFalse(Clock.State.idle.ticks, "an idle bar draws no timeline at all")
        XCTAssertFalse(Clock.State.preparing.ticks, "the deadline arriving redraws the view; nothing needs to wake up for it")
        XCTAssertFalse(state(.moves, deadline: at(-1)).ticks, "a deadline that passed has nothing left to count")
        let dates = Clock.tickDates(deadline: at(3.5), now: now)
        XCTAssertEqual(dates, [now, at(0.5), at(1.5), at(2.5), at(3.5)].map { $0 }, "now, then each whole second left, ending at the deadline")
        XCTAssertEqual(Clock.tickDates(deadline: at(0.25), now: now), [now, at(0.25)])
        XCTAssertEqual(Clock.tickDates(deadline: at(-2), now: now), [now])
        XCTAssertLessThanOrEqual(Clock.tickDates(deadline: at(900), now: now).count, 32, "a far deadline never makes a long schedule")
        XCTAssertEqual(Clock.tickDates(deadline: at(900), now: now).last, at(900))
    }

    // MARK: pulse

    func testThePulseAlternatesBySecondOnlyWhenUrgentAndMotionIsAllowed() {
        let urgent = Clock.State.counting(remaining: 4, fraction: 4 / 30, mine: true)
        let next = Clock.State.counting(remaining: 3, fraction: 3 / 30, mine: true)
        XCTAssertNotEqual(urgent.pulseDim(reduceMotion: false), next.pulseDim(reduceMotion: false), "one second later the bar swaps")
        XCTAssertFalse(urgent.pulseDim(reduceMotion: true)); XCTAssertFalse(next.pulseDim(reduceMotion: true))
        let calm = Clock.State.counting(remaining: 20, fraction: 20 / 30, mine: true)
        XCTAssertFalse(calm.pulseDim(reduceMotion: false))
        XCTAssertFalse(Clock.State.counting(remaining: 3, fraction: 0.1, mine: false).pulseDim(reduceMotion: false))
        XCTAssertFalse(Clock.State.idle.pulseDim(reduceMotion: false))
    }

    // MARK: words

    func testTheClockTextSaysTurnAndSecondsAndNamesTheAutoPickOnlyWhenItIsMine() {
        let l = L(.ko), en = L(.en)
        XCTAssertEqual(l.onlineClockText(.counting(remaining: 28, fraction: 0.9, mine: true), turn: 3), "3턴 · 28초")
        XCTAssertEqual(en.onlineClockText(.counting(remaining: 28, fraction: 0.9, mine: true), turn: 3), "Turn 3 · 28s")
        let urgent = Clock.State.counting(remaining: 4, fraction: 0.1, mine: true)
        XCTAssertEqual(l.onlineClockText(urgent, turn: 3), "3턴 · 4초 · 시간 초과 시 자동 선택")
        XCTAssertTrue(en.onlineClockText(urgent, turn: 3).lowercased().contains("auto-pick"))
        let sent = Clock.State.counting(remaining: 4, fraction: 0.1, mine: false)
        XCTAssertEqual(l.onlineClockText(sent, turn: 3), "3턴 · 4초")
        XCTAssertTrue(l.onlineClockText(.preparing, turn: 3).contains("준비"))
        XCTAssertTrue(en.onlineClockText(.preparing, turn: 3).lowercased().contains("preparing"))
        XCTAssertFalse(l.onlineClockText(.preparing, turn: 3).contains("초"), "no seconds are made up")
        XCTAssertEqual(l.onlineClockText(.idle, turn: 3), "3턴"); XCTAssertEqual(en.onlineClockText(.idle, turn: 3), "Turn 3")
    }

    // MARK: the arena reads it from the model

    func testTheArenaDerivesTheStateFromItsModelAndTheShownTurnFollowsTheClockedTurn() throws {
        let fixture = try OnlineBattleArenaFixture.arena(seat: .p1); defer { fixture.close() }
        try fixture.play(rounds: 1)
        XCTAssertTrue(fixture.staging.isPlaying)
        let arena = arenaView(fixture.model)
        fixture.model.deadline = at(18)
        XCTAssertEqual(arena.turnClock(now: now), .counting(remaining: 18, fraction: 18 / 30, mine: true))
        let view = try XCTUnwrap(fixture.model.arena), beat = try XCTUnwrap(fixture.staging.playback.beat)
        XCTAssertLessThan(beat.turn, view.turn)
        XCTAssertEqual(arena.clockTurn(view, state: arena.turnClock(now: now)), view.turn, "the seconds belong to the turn being chosen")
        XCTAssertEqual(arena.clockTurn(view, state: .idle), beat.turn, "with no clock the turn on screen is the beat's")
        fixture.model.choiceSubmitted = true
        XCTAssertEqual(arena.turnClock(now: now), .counting(remaining: 18, fraction: 18 / 30, mine: false))
        fixture.model.choiceSubmitted = false; fixture.model.deadline = nil
        XCTAssertEqual(arena.turnClock(now: now), .preparing)
        fixture.model.request = .init(kind: "none", moves: [])
        fixture.model.deadline = at(18)
        XCTAssertEqual(arena.turnClock(now: now), .idle, "a terminal round: nobody chooses")
    }

    func testAnAutomaticBattleHasNoBar() throws {
        let fixture = try OnlineBattleArenaFixture.arena(seat: .p2, name: "auto"); defer { fixture.close() }
        try fixture.play(rounds: 1, mode: .auto, secondsLeft: nil)
        fixture.model.room = try OnlineBattleArenaFixture.liveRoom("auto", seat: .p2, deadline: 1_000_000)
        fixture.model.deadline = at(25)
        XCTAssertEqual(arenaView(fixture.model).turnClock(now: now), .idle)
    }

    // MARK: no always-on animation

    /// Defect log, always-on animation: the bar moves by a one-second timeline that exists only while it counts.
    /// A repeating animation would keep drawing for a popover nobody is looking at.
    func testNothingInTheBarOrTheArenaRepeatsForever() throws {
        let ui = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PokeTokenBar/UI")
        for file in ["OnlineBattleScreenArena.swift", "OnlineBattleTurnClock.swift", "OnlineBattleVersus.swift"] {
            let source = try String(contentsOf: ui.appendingPathComponent(file), encoding: .utf8)
            XCTAssertFalse(source.contains("repeatForever"), "\(file) must not animate forever")
            XCTAssertFalse(source.contains("Timer.publish"), "\(file) must not own a timer")
        }
        let clock = try String(contentsOf: ui.appendingPathComponent("OnlineBattleTurnClock.swift"), encoding: .utf8)
        XCTAssertFalse(clock.contains(".periodic"), "a periodic timeline never ends; the schedule is the finite one up to the deadline")
        XCTAssertTrue(clock.contains("TimelineView(.explicit("), "the finite timeline is the bar's only clock")
        XCTAssertEqual(clock.components(separatedBy: "TimelineView(").count - 1, 1)
        let arena = try String(contentsOf: ui.appendingPathComponent("OnlineBattleScreenArena.swift"), encoding: .utf8)
        XCTAssertFalse(arena.contains("TimelineView"), "the arena's header has no clock of its own any more")
    }

    // MARK: splash

    func testTheSplashIsDueOnlyBeforeAnythingHasPlayedOnTheFirstTurn() {
        XCTAssertTrue(OnlineBattleArena.splashDue(turn: 1, introShown: false, played: false))
        XCTAssertFalse(OnlineBattleArena.splashDue(turn: 1, introShown: true, played: false), "once per battle")
        XCTAssertFalse(OnlineBattleArena.splashDue(turn: 1, introShown: false, played: true), "a battle that already played")
        XCTAssertFalse(OnlineBattleArena.splashDue(turn: 2, introShown: false, played: false), "returning to a battle already under way")
        XCTAssertFalse(OnlineBattleArena.splashDue(turn: nil, introShown: false, played: false))
    }

    func testTheSplashIsClaimedOnceAndAReopenedScreenDoesNotShowItAgain() throws {
        let fixture = try OnlineBattleArenaFixture.arena(seat: .p1, splash: true); defer { fixture.close() }
        XCTAssertEqual(fixture.model.arena?.turn, 1)
        XCTAssertFalse(fixture.staging.playback.introShown)
        XCTAssertTrue(arenaView(fixture.model).claimSplash())
        XCTAssertTrue(fixture.staging.playback.introShown, "the staging remembers it, since the popover's views do not outlive a close")
        XCTAssertFalse(arenaView(fixture.model).claimSplash(), "the popover was closed and opened: a new view, the same battle")
    }

    func testABattleAlreadyUnderWayShowsNoSplashWhateverTheFlagSays() throws {
        let fixture = try OnlineBattleArenaFixture.arena(seat: .p1, splash: true); defer { fixture.close() }
        try fixture.play(rounds: 1)
        XCTAssertFalse(arenaView(fixture.model).claimSplash())
        fixture.staging.skipToEnd(); fixture.publish()
        XCTAssertFalse(arenaView(fixture.model).claimSplash())
    }

    /// The splash is drawn state of the view. Progress and the picker read the model, so nothing there can wait for it.
    func testTheSplashNeverLocksTheMovePicker() throws {
        let fixture = try OnlineBattleArenaFixture.arena(seat: .p1, splash: true); defer { fixture.close() }
        let arena = arenaView(fixture.model)
        XCTAssertTrue(arena.claimSplash())
        for move in fixture.model.request?.moves ?? [] { XCTAssertFalse(arena.movesLocked(move.slot), "slot \(move.slot)") }
        var slots: [Int] = []
        fixture.model.onAction = { if case .chooseMove(let slot) = $0 { slots.append(slot) } }
        fixture.model.send(.chooseMove(1))
        XCTAssertEqual(slots, [1])
    }

    func testTheSplashWordsNameTheOpponentInBothLanguagesAndFallBackToNothingWithoutAName() {
        XCTAssertEqual(L(.ko).onlineSplashLine("연습친구"), "연습친구님과 대전 시작!")
        XCTAssertEqual(L(.en).onlineSplashLine("Misty"), "Battle with Misty")
        XCTAssertNil(L(.ko).onlineSplashLine(nil)); XCTAssertNil(L(.en).onlineSplashLine(""))
        XCTAssertEqual(L(.ko).onlineSplashSkip, "건너뛰기"); XCTAssertEqual(L(.en).onlineSplashSkip, "Skip")
    }
}

// MARK: - Review C, F4 items 5 and 6

extension OnlineBattleTurnClockTests {
    /// A forced turn still runs on the server's clock. The seconds show, and nobody is hurried.
    func testAForcedTurnShowsTheSecondsLeftWithoutHurryingAnyone() {
        XCTAssertEqual(state(.forced, deadline: at(18)), .counting(remaining: 18, fraction: 18 / 30, mine: false))
        let last = state(.forced, deadline: at(3))
        XCTAssertFalse(last.isUrgent, "no orange and no auto-pick line: nothing here is the person's to do")
        for l in [L(.ko), L(.en)] {
            XCTAssertEqual(l.onlineClockText(last, turn: 9), l.onlineTurn(9, seconds: 3))
        }
        XCTAssertFalse(OnlineBattleSpoken.clock(l: L(.ko), state: last, turn: 9).contains("자동 선택"))
    }

    /// The last round's beats read like any other round's: the clock does not go quiet ahead of them.
    func testTheLastBeatsLookLikeAnyRoundsBeats() {
        XCTAssertEqual(state(.waiting, deadline: nil), state(.moves, deadline: nil))
        XCTAssertEqual(state(.waiting, deadline: nil), .preparing)
        XCTAssertEqual(state(.forced, deadline: nil), .preparing)
    }
}
