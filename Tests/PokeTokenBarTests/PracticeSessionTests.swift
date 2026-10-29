import XCTest
@testable import PokeTokenBar

@MainActor
final class PracticeSessionTests: XCTestCase {
    private final class Clock { var now = 0.0 }
    private var engineURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("engine/dist/battle-engine.js")
    }
    private func profile(_ id: String, moves: [String] = ["tackle"]) -> PokemonProfile {
        var p = PokemonProfile.generate(seed: 42, instanceID: id)
        p.level = 50; p.gender = .male; p.abilityName = "pressure"
        p.moves = moves.map { PokemonKnownMove(name: $0, learnedAtLevel: 1) }
        return p
    }
    /// Specs are (instance id, species, moves). Blissey with tackle never finishes within a test;
    /// Pikachu with thunderbolt against Magikarp with splash always does.
    private func state(_ specs: [(String, Int, [String])]) -> CompanionState {
        var state = CompanionState()
        state.dex = specs.map { id, species, moves in
            DexEntry(baseID: species, finalID: species, chainOrder: [species], rarity: .common, caughtAt: nil,
                     nature: .hardy, profile: profile(id, moves: moves))
        }
        return state
    }
    private func slowState() -> CompanionState { state([("a", 242, ["tackle"]), ("b", 242, ["tackle"]), ("c", 242, ["tackle"])]) }
    private func fastState() -> CompanionState {
        state([("p", 25, ["thunderbolt"]), ("m", 129, ["splash"]), ("c", 242, ["tackle"])])
    }
    private func makeSession(_ clock: Clock, _ state: CompanionState) -> PracticeSession {
        let session = PracticeSession(engineURL: engineURL, clock: { clock.now }, drivesAutomatically: false)
        session.prepare(state: state, activeName: nil)
        return session
    }
    private func finish(_ session: PracticeSession, _ clock: Clock) {
        for _ in 0..<300 where session.battle?.phase == .running { clock.now += 1; session.tick() }
    }
    private func timedOut(_ session: PracticeSession) -> Bool {
        session.battle?.messages.contains { $0.contains("시간 초과") } == true
    }

    func testPrepareBuildsRosterDefaultSelectionAndKeepsOrDropsIt() throws {
        let session = makeSession(Clock(), slowState())
        XCTAssertNil(session.loadError)
        XCTAssertEqual(session.roster?.eligible.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(session.playerID, "a"); XCTAssertEqual(session.opponentID, "b")
        XCTAssertEqual(session.player?.id, "a"); XCTAssertEqual(session.opponent?.id, "b")
        session.opponentID = "c"
        session.prepare(state: slowState(), activeName: nil)
        XCTAssertEqual(session.playerID, "a"); XCTAssertEqual(session.opponentID, "c")
        // "c" disappeared: the opponent falls back to the next candidate.
        session.prepare(state: state([("a", 242, ["tackle"]), ("b", 242, ["tackle"])]), activeName: nil)
        XCTAssertEqual(session.playerID, "a"); XCTAssertEqual(session.opponentID, "b")
        // Nothing selected survives: defaults start over. Blocked individuals are skipped.
        session.prepare(state: state([("blocked", 242, []), ("x", 242, ["tackle"]), ("y", 242, ["tackle"])]), activeName: nil)
        XCTAssertEqual(session.roster?.eligible.map(\.id), ["x", "y"])
        XCTAssertEqual(session.playerID, "x"); XCTAssertEqual(session.opponentID, "y")
        // A single eligible individual has no opponent.
        session.prepare(state: state([("solo", 242, ["tackle"])]), activeName: nil)
        XCTAssertEqual(session.playerID, "solo"); XCTAssertNil(session.opponentID); XCTAssertNil(session.opponent)
    }

    func testPrepareWithoutUsableEngineReportsLoadErrorAndNoRoster() throws {
        let broken = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).js")
        try Data("not an engine".utf8).write(to: broken); defer { try? FileManager.default.removeItem(at: broken) }
        for url in [nil, URL(fileURLWithPath: "/nonexistent/battle-engine.js"), broken] {
            let session = PracticeSession(engineURL: url, clock: { 0 }, drivesAutomatically: false)
            session.prepare(state: slowState(), activeName: nil)
            XCTAssertNotNil(session.loadError, "\(String(describing: url))")
            XCTAssertNil(session.roster); XCTAssertNil(session.player); XCTAssertNil(session.battle)
            session.start()
            XCTAssertNil(session.battle); XCTAssertFalse(session.isActive)
        }
    }

    func testManualPauseFreezesDeadlineAndResumeRestoresRemainingTime() throws {
        let clock = Clock(); let session = makeSession(clock, slowState())
        session.start()
        XCTAssertEqual(session.battle?.phase, .running); XCTAssertEqual(session.battle?.view?.turn, 1)
        clock.now = 5; session.setPaused(true, reason: .popoverClosed)
        XCTAssertEqual(session.battle?.remainingSeconds, 10)
        XCTAssertEqual(session.battle?.isPaused, true)
        clock.now = 500; session.tick()
        XCTAssertEqual(session.battle?.view?.turn, 1); XCTAssertFalse(timedOut(session))
        session.setPaused(false, reason: .popoverClosed)
        XCTAssertEqual(session.battle?.isPaused, false)
        clock.now = 509.9; session.tick()
        XCTAssertEqual(session.battle?.view?.turn, 1); XCTAssertFalse(timedOut(session))
        clock.now = 510; session.tick()
        XCTAssertEqual(session.battle?.view?.turn, 2); XCTAssertTrue(timedOut(session))
    }

    func testManualHoldsUntilEveryReasonIsLifted() throws {
        let clock = Clock(); let session = makeSession(clock, slowState())
        session.start()
        session.setPaused(true, reason: .popoverClosed); session.setPaused(true, reason: .screenHidden)
        session.setPaused(false, reason: .popoverClosed)
        XCTAssertEqual(session.pauseReasons, [.screenHidden]); XCTAssertEqual(session.battle?.isPaused, true)
        clock.now = 100; session.tick(); XCTAssertEqual(session.battle?.view?.turn, 1)
        session.setPaused(false, reason: .screenHidden)
        XCTAssertEqual(session.battle?.isPaused, false)
    }

    func testAutomaticKeepsPlayingExceptWhileDisplayAsleep() throws {
        let clock = Clock(); let session = makeSession(clock, slowState())
        session.mode = .automatic; session.start()
        session.setPaused(true, reason: .popoverClosed); session.setPaused(true, reason: .screenHidden)
        XCTAssertEqual(session.battle?.isPaused, false)
        clock.now = 1; session.tick(); XCTAssertEqual(session.battle?.view?.turn, 2)
        session.setPaused(true, reason: .displayAsleep)
        XCTAssertEqual(session.battle?.isPaused, true)
        clock.now = 2; session.tick(); clock.now = 100; session.tick()
        XCTAssertEqual(session.battle?.view?.turn, 2)
        session.setPaused(false, reason: .displayAsleep)
        clock.now = 100.5; session.tick(); XCTAssertEqual(session.battle?.view?.turn, 2)
        clock.now = 101; session.tick(); XCTAssertEqual(session.battle?.view?.turn, 3)
        XCTAssertFalse(timedOut(session))
    }

    func testSwitchingModeWhileHeldReevaluatesThePause() throws {
        let clock = Clock(); let session = makeSession(clock, slowState())
        session.start()
        clock.now = 1; session.setPaused(true, reason: .popoverClosed)
        clock.now = 5; session.tick(); XCTAssertEqual(session.battle?.view?.turn, 1)
        session.mode = .automatic
        XCTAssertEqual(session.battle?.mode, .automatic); XCTAssertEqual(session.battle?.isPaused, false)
        session.tick(); XCTAssertEqual(session.battle?.view?.turn, 2); XCTAssertFalse(timedOut(session))
        session.mode = .manual
        XCTAssertEqual(session.battle?.mode, .manual); XCTAssertEqual(session.battle?.isPaused, true)
        clock.now = 600; session.tick(); XCTAssertEqual(session.battle?.view?.turn, 2)
    }

    func testChooseForwardsOnlyWhileRunningManualAndNotPaused() throws {
        let clock = Clock(); let session = makeSession(clock, slowState())
        session.choose(slot: 1)
        XCTAssertNil(session.battle)
        session.start()
        session.setPaused(true, reason: .screenHidden); session.choose(slot: 1)
        XCTAssertEqual(session.battle?.view?.turn, 1)
        session.setPaused(false, reason: .screenHidden); session.choose(slot: 1)
        XCTAssertEqual(session.battle?.view?.turn, 2)
        session.mode = .automatic; session.choose(slot: 1)
        XCTAssertEqual(session.battle?.view?.turn, 2)
    }

    func testActiveResultSeenAndBadgeThroughRunningAndFinished() throws {
        let clock = Clock(); let session = makeSession(clock, fastState())
        session.playerID = "p"; session.opponentID = "m"; session.mode = .automatic
        XCTAssertFalse(session.isActive); XCTAssertTrue(session.resultSeen); XCTAssertNil(session.statusBadge)
        session.start()
        XCTAssertEqual(session.battle?.phase, .running)
        XCTAssertTrue(session.isActive); XCTAssertTrue(session.resultSeen)
        XCTAssertEqual(session.statusBadge, "\u{2694}\u{FE0E}")
        finish(session, clock)
        XCTAssertEqual(session.battle?.phase, .finished)
        XCTAssertFalse(session.resultSeen); XCTAssertTrue(session.isActive)
        XCTAssertEqual(session.statusBadge, "\u{2691}")
        clock.now += 1; session.tick()
        XCTAssertFalse(session.resultSeen)
        session.markResultSeen()
        XCTAssertTrue(session.resultSeen); XCTAssertFalse(session.isActive); XCTAssertNil(session.statusBadge)
        clock.now += 1; session.tick()
        XCTAssertTrue(session.resultSeen)
    }

    func testManualFinishThroughChooseMarksTheResultUnseen() throws {
        let clock = Clock(); let session = makeSession(clock, fastState())
        session.playerID = "p"; session.opponentID = "m"
        session.start()
        for _ in 0..<50 where session.battle?.phase == .running { clock.now += 1; session.choose(slot: 1) }
        XCTAssertEqual(session.battle?.phase, .finished); XCTAssertFalse(session.resultSeen)
        XCTAssertEqual(session.statusBadge, "\u{2691}")
    }

    func testChangingSelectionDropsFinishedBattleButNeverARunningOne() throws {
        let clock = Clock(); let session = makeSession(clock, fastState())
        session.playerID = "p"; session.opponentID = "m"; session.start()
        let running = session.battle
        session.opponentID = "c"
        XCTAssertNotNil(session.battle); XCTAssertTrue(session.battle === running)
        XCTAssertEqual(session.battle?.phase, .running)
        session.playerID = "m"
        XCTAssertTrue(session.battle === running); XCTAssertEqual(session.battle?.phase, .running)
        session.forfeit()
        session.playerID = "p"; session.opponentID = "m"; session.mode = .automatic; session.start()
        finish(session, clock)
        XCTAssertEqual(session.battle?.phase, .finished)
        session.opponentID = "m"
        XCTAssertNotNil(session.battle, "assigning the same value is not a change")
        session.opponentID = "c"
        XCTAssertNil(session.battle); XCTAssertTrue(session.resultSeen); XCTAssertFalse(session.isActive)
        session.start(); finish(session, clock)
        XCTAssertEqual(session.battle?.phase, .finished)
        session.playerID = "m"
        XCTAssertNil(session.battle)
    }

    func testForfeitAndBackToSelectionLeaveNoBattle() throws {
        let clock = Clock(); let session = makeSession(clock, fastState())
        session.playerID = "p"; session.opponentID = "m"; session.mode = .automatic
        session.start()
        let running = session.battle
        session.backToSelection()
        XCTAssertTrue(session.battle === running); XCTAssertEqual(session.battle?.phase, .running)
        session.forfeit()
        XCTAssertNil(session.battle); XCTAssertEqual(running?.phase, .cancelled)
        XCTAssertFalse(session.isActive); XCTAssertNil(session.statusBadge)
        clock.now += 100; session.tick(); XCTAssertNil(session.battle)
        session.start(); finish(session, clock)
        XCTAssertEqual(session.battle?.phase, .finished); XCTAssertFalse(session.resultSeen)
        session.backToSelection()
        XCTAssertNil(session.battle); XCTAssertTrue(session.resultSeen); XCTAssertNil(session.statusBadge)
    }

    func testStartNeedsRosterAndDistinctSelectionAndStartsFresh() throws {
        let clock = Clock(); let session = makeSession(clock, slowState())
        session.opponentID = session.playerID
        session.start(); XCTAssertNil(session.battle)
        session.opponentID = nil
        session.start(); XCTAssertNil(session.battle)
        session.opponentID = "b"; session.start()
        let first = session.battle
        XCTAssertEqual(first?.phase, .running)
        session.start()
        XCTAssertFalse(session.battle === first); XCTAssertEqual(first?.phase, .cancelled)
        XCTAssertEqual(session.battle?.phase, .running); XCTAssertEqual(session.battle?.view?.turn, 1)
    }

    func testReleaseIfIdleDropsRosterOnlyWhenNothingIsActive() throws {
        let clock = Clock(); let session = makeSession(clock, fastState())
        session.playerID = "p"; session.opponentID = "m"; session.mode = .automatic
        session.releaseIfIdle()
        XCTAssertNil(session.roster); XCTAssertNil(session.player); XCTAssertNil(session.battle)
        session.prepare(state: fastState(), activeName: nil)
        XCTAssertNotNil(session.roster); XCTAssertEqual(session.playerID, "p"); XCTAssertEqual(session.opponentID, "m")
        session.start(); session.releaseIfIdle()
        XCTAssertNotNil(session.roster); XCTAssertEqual(session.battle?.phase, .running)
        finish(session, clock)
        session.releaseIfIdle()
        XCTAssertNotNil(session.roster); XCTAssertEqual(session.battle?.phase, .finished)
        session.markResultSeen(); session.releaseIfIdle()
        XCTAssertNil(session.roster); XCTAssertNil(session.battle)
        session.prepare(state: fastState(), activeName: nil)
        session.start()
        XCTAssertEqual(session.battle?.phase, .running)
    }

    func testPrepareLeavesARunningBattleUntouched() throws {
        let clock = Clock(); let session = makeSession(clock, slowState())
        session.start()
        let running = session.battle, roster = session.roster?.eligible.map(\.id)
        session.prepare(state: state([("x", 242, ["tackle"]), ("y", 242, ["tackle"])]), activeName: nil)
        XCTAssertTrue(session.battle === running); XCTAssertEqual(session.roster?.eligible.map(\.id), roster)
        XCTAssertEqual(session.playerID, "a"); XCTAssertEqual(session.opponentID, "b")
    }

    func testStatusBadgeTable() {
        let rows: [(PracticeBattle.Phase?, Bool, String?)] = [
            (nil, true, nil), (nil, false, nil),
            (.ready, true, nil), (.ready, false, nil),
            (.running, true, "\u{2694}\u{FE0E}"), (.running, false, "\u{2694}\u{FE0E}"),
            (.finished, false, "\u{2691}"), (.finished, true, nil),
            (.failed, true, nil), (.failed, false, nil),
            (.cancelled, true, nil), (.cancelled, false, nil),
        ]
        for (phase, seen, expected) in rows {
            XCTAssertEqual(PracticeStatusBadge.text(phase: phase, resultSeen: seen), expected, "\(String(describing: phase)) \(seen)")
        }
    }

    func testSessionNeverWritesTheSyntheticSave() throws {
        let clock = Clock(); let initial = fastState()
        let bytes = try BattleJSON.encoder().encode(initial)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: file); defer { try? FileManager.default.removeItem(at: file) }
        let session = makeSession(clock, initial)
        session.playerID = "p"; session.opponentID = "m"; session.mode = .automatic
        session.start(); finish(session, clock)
        XCTAssertEqual(session.battle?.phase, .finished)
        session.markResultSeen(); session.releaseIfIdle()
        XCTAssertEqual(try BattleJSON.encoder().encode(initial), bytes)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testDriverTicksWhileRunningAndStopsWhileHeld() async throws {
        let clock = Clock()
        let session = PracticeSession(engineURL: engineURL, clock: { clock.now })
        session.prepare(state: slowState(), activeName: nil)
        session.mode = .automatic; session.start()
        // The turn's beats play on the injected clock, so it moves a second per poll.
        func waitForTurn(_ turn: Int) async throws {
            for _ in 0..<40 where (session.battle?.view?.turn ?? 0) < turn {
                try await Task.sleep(for: .milliseconds(100)); clock.now += 1
            }
        }
        XCTAssertEqual(session.battle?.view?.turn, 1)
        clock.now = 1; try await waitForTurn(2)
        XCTAssertEqual(session.battle?.view?.turn, 2)
        // Let the turn finish playing first, so only display sleep can be what holds the next one.
        for _ in 0..<40 where session.playback?.isPlaying == true {
            try await Task.sleep(for: .milliseconds(100))
            if session.playback?.isPlaying == true { clock.now += 1 }
        }
        XCTAssertEqual(session.playback?.isPlaying, false); XCTAssertEqual(session.pauseReasons, [])
        session.setPaused(true, reason: .displayAsleep)
        XCTAssertEqual(session.pauseReasons, [.displayAsleep])
        clock.now = 100; try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(session.battle?.view?.turn, 2)
        session.setPaused(false, reason: .displayAsleep)
        clock.now = 101; try await waitForTurn(3)
        XCTAssertEqual(session.battle?.view?.turn, 3)
        session.forfeit()
        clock.now = 200; try await Task.sleep(for: .milliseconds(600))
        XCTAssertNil(session.battle)
    }

    /// Ticks one second at a time until the staged turn has finished playing.
    private func playOut(_ session: PracticeSession, _ clock: Clock) {
        for _ in 0..<30 where session.playback?.isPlaying == true { clock.now += 1; session.tick() }
    }

    func testStartSeedsAFreshPlaybackWithoutHoldingTheBattle() throws {
        let clock = Clock(); let session = makeSession(clock, slowState())
        XCTAssertNil(session.playback)
        session.start()
        let first = try XCTUnwrap(session.playback)
        XCTAssertNotNil(first.display[.player]); XCTAssertNotNil(first.display[.opponent])
        XCTAssertFalse(first.isPlaying); XCTAssertFalse(session.pauseReasons.contains(.playback))
        XCTAssertEqual(session.battle?.isPaused, false)
        session.start()
        XCTAssertFalse(session.playback === first); XCTAssertTrue(session.playback?.history.isEmpty == true)
    }

    func testManualDeadlineWaitsForTheTurnToPlayAndThenGetsTheFullFifteenSeconds() throws {
        let clock = Clock(); let session = makeSession(clock, slowState())
        session.start()
        let playback = try XCTUnwrap(session.playback)
        clock.now = 5; session.choose(slot: 1)
        XCTAssertEqual(session.battle?.view?.turn, 2)
        XCTAssertTrue(playback.isPlaying); XCTAssertTrue(session.pauseReasons.contains(.playback))
        XCTAssertEqual(session.battle?.isPaused, true)
        session.choose(slot: 1); XCTAssertEqual(session.battle?.view?.turn, 2, "no new turn while the last one plays")
        // Past the old deadline (5 + 15) the turn is still playing or has only just finished.
        clock.now = 21; session.tick()
        XCTAssertEqual(session.battle?.view?.turn, 2); XCTAssertFalse(timedOut(session))
        playOut(session, clock)
        let finished = clock.now
        XCTAssertFalse(playback.isPlaying); XCTAssertFalse(session.pauseReasons.contains(.playback))
        XCTAssertEqual(session.battle?.isPaused, false); XCTAssertEqual(session.battle?.remainingSeconds, 15)
        XCTAssertEqual(session.battle?.view?.turn, 2); XCTAssertFalse(timedOut(session))
        clock.now = finished + 14.9; session.tick()
        XCTAssertEqual(session.battle?.view?.turn, 2); XCTAssertFalse(timedOut(session))
        clock.now = finished + 15; session.tick()
        XCTAssertEqual(session.battle?.view?.turn, 3); XCTAssertTrue(timedOut(session))
    }

    func testAutomaticTurnsNeverOverlapThePlayback() throws {
        let clock = Clock(); let session = makeSession(clock, slowState())
        session.mode = .automatic; session.start()
        let playback = try XCTUnwrap(session.playback)
        clock.now = 1; session.tick()
        XCTAssertEqual(session.battle?.view?.turn, 2); XCTAssertTrue(playback.isPlaying)
        XCTAssertTrue(session.pauseReasons.contains(.playback)); XCTAssertEqual(session.battle?.isPaused, true)
        // A long gap between ticks does not start the next turn while a beat is on screen.
        clock.now = 50; session.tick()
        XCTAssertEqual(session.battle?.view?.turn, 2)
        playOut(session, clock)
        XCTAssertFalse(playback.isPlaying); XCTAssertEqual(session.battle?.isPaused, false)
        XCTAssertEqual(session.battle?.view?.turn, 2)
        let finished = clock.now
        clock.now = finished + 0.5; session.tick(); XCTAssertEqual(session.battle?.view?.turn, 2)
        clock.now = finished + 1; session.tick(); XCTAssertEqual(session.battle?.view?.turn, 3)
        XCTAssertFalse(timedOut(session))
    }

    func testHiddenScreenSkipsThePlaybackInsteadOfHoldingTheBattle() throws {
        let clock = Clock(); let session = makeSession(clock, slowState())
        session.mode = .automatic; session.start()
        let playback = try XCTUnwrap(session.playback)
        session.setPaused(true, reason: .screenHidden)
        clock.now = 1; session.tick()
        XCTAssertEqual(session.battle?.view?.turn, 2)
        XCTAssertFalse(playback.isPlaying); XCTAssertFalse(session.pauseReasons.contains(.playback))
        XCTAssertFalse(playback.history.isEmpty)
        let played = playback.history.count
        clock.now = 2; session.tick()
        XCTAssertEqual(session.battle?.view?.turn, 3, "automatic play goes on without waiting for beats nobody sees")
        session.setPaused(false, reason: .screenHidden)
        XCTAssertNil(playback.beat); XCTAssertGreaterThan(playback.history.count, played)
    }

    func testClosingThePopoverMidPlaybackSkipsToTheEndAndKeepsTheFullDeadline() throws {
        let clock = Clock(); let session = makeSession(clock, slowState())
        session.start()
        let playback = try XCTUnwrap(session.playback)
        clock.now = 5; session.choose(slot: 1)
        XCTAssertTrue(playback.isPlaying)
        session.setPaused(true, reason: .popoverClosed)
        XCTAssertFalse(playback.isPlaying); XCTAssertFalse(session.pauseReasons.contains(.playback))
        XCTAssertEqual(session.battle?.isPaused, true)
        let history = playback.history.count
        clock.now = 500; session.tick()
        XCTAssertEqual(session.battle?.view?.turn, 2)
        session.setPaused(false, reason: .popoverClosed)
        XCTAssertNil(playback.beat); XCTAssertEqual(playback.history.count, history, "nothing replays")
        XCTAssertEqual(session.battle?.isPaused, false)
        clock.now = 514.9; session.tick(); XCTAssertEqual(session.battle?.view?.turn, 2)
        clock.now = 515; session.tick(); XCTAssertEqual(session.battle?.view?.turn, 3)
    }

    func testFinishingBattlePlaysItsLastBeatsThenTheResultIsReady() throws {
        let clock = Clock(); let session = makeSession(clock, fastState())
        session.playerID = "p"; session.opponentID = "m"; session.mode = .automatic
        session.start()
        let playback = try XCTUnwrap(session.playback)
        for _ in 0..<5 where session.battle?.phase == .running { clock.now += 1; session.tick() }
        XCTAssertEqual(session.battle?.phase, .finished); XCTAssertFalse(session.resultSeen)
        XCTAssertTrue(playback.isPlaying, "the knockout is still being staged")
        XCTAssertTrue(session.pauseReasons.contains(.playback)); XCTAssertTrue(session.isActive)
        XCTAssertNil(playback.summary.finishingMoveID)
        playOut(session, clock)
        XCTAssertFalse(playback.isPlaying); XCTAssertFalse(session.pauseReasons.contains(.playback))
        XCTAssertEqual(session.battle?.phase, .finished); XCTAssertFalse(session.resultSeen)
        XCTAssertEqual(playback.summary.finishingMoveID, "thunderbolt")
        XCTAssertEqual(playback.display[.opponent]?.fainted, true)
        let history = playback.history.count
        clock.now += 10; session.tick()
        XCTAssertEqual(playback.history.count, history); XCTAssertFalse(session.resultSeen)
        session.markResultSeen(); clock.now += 10; session.tick()
        XCTAssertTrue(session.resultSeen, "ticking a finished battle never un-sees the result")
    }

    func testForfeitAndBackToSelectionDropThePlaybackWithTheBattle() throws {
        let clock = Clock(); let session = makeSession(clock, slowState())
        session.mode = .automatic; session.start()
        clock.now = 1; session.tick()
        XCTAssertTrue(session.pauseReasons.contains(.playback))
        session.forfeit()
        XCTAssertNil(session.playback); XCTAssertFalse(session.pauseReasons.contains(.playback))
        session.start(); XCTAssertNotNil(session.playback)
        session.releaseIfIdle()
        XCTAssertNotNil(session.playback, "a running battle keeps its playback")
        session.forfeit()
        session.prepare(state: fastState(), activeName: nil)
        session.playerID = "p"; session.opponentID = "m"; session.start(); finish(session, clock)
        XCTAssertEqual(session.battle?.phase, .finished); XCTAssertNotNil(session.playback)
        session.backToSelection()
        XCTAssertNil(session.battle); XCTAssertNil(session.playback); XCTAssertFalse(session.pauseReasons.contains(.playback))
        session.start(); finish(session, clock); session.markResultSeen(); session.releaseIfIdle()
        XCTAssertNil(session.battle); XCTAssertNil(session.playback)
    }
}
