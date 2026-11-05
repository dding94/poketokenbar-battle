import XCTest
@testable import PokeTokenBar

/// The arena board reads both sides through the seat frame and the staging, never `view.p1` / `view.p2`.
@MainActor
final class OnlineBattleArenaTests: XCTestCase {
    private func arenaView(_ model: OnlineBattlePresentation) -> OnlineBattleArena {
        // A store of its own: names other tests cached in the shared one must not change what a card is called.
        OnlineBattleArena(model: model, l: L(.ko), artwork: false, speciesNameProvider: OnlineBattleSyntheticNameProvider(),
                          speciesNameStore: PokemonNameDisplayStore())
    }
    private func foe(_ side: PracticeSide) -> PracticeSide { side == .player ? .opponent : .player }

    // MARK: footer

    func testFooterChoosesWhatTakesTheMovePickersPlace() {
        typealias Footer = OnlineBattleArena.Footer
        func footer(_ mode: OnlineBattleMode, _ submitted: Bool, _ kind: String, _ playing: Bool) -> Footer {
            OnlineBattleArena.footer(mode: mode, submitted: submitted, requestKind: kind, playing: playing)
        }
        XCTAssertEqual(footer(.auto, false, "none", false), .automatic)
        XCTAssertEqual(footer(.auto, true, "move", true), .automatic)
        XCTAssertEqual(footer(.manual, true, "move", false), .sent)
        XCTAssertEqual(footer(.manual, true, "none", true), .sent)
        // The picker never waits for the beats (D6): a move request shows moves while the turn plays.
        XCTAssertEqual(footer(.manual, false, "move", false), .moves)
        XCTAssertEqual(footer(.manual, false, "move", true), .moves)
        // A terminal round has no request while its last beats play: that is not a forced action.
        XCTAssertEqual(footer(.manual, false, "none", true), .waiting)
        XCTAssertEqual(footer(.manual, false, "none", false), .forced)
        XCTAssertEqual(footer(.manual, false, "switch", false), .forced)
    }

    func testSkipToResultOnlyForAnAutomaticBattleThatIsPlaying() {
        XCTAssertTrue(OnlineBattleArena.showsSkipToResult(mode: .auto, playing: true))
        XCTAssertFalse(OnlineBattleArena.showsSkipToResult(mode: .auto, playing: false))
        XCTAssertFalse(OnlineBattleArena.showsSkipToResult(mode: .manual, playing: true))
    }

    /// D6: a choice is never held back by the beats. It reaches the session while a beat is on screen.
    func testThePickerStaysOpenAndSendsAChoiceWhileTheBeatsPlay() throws {
        let fixture = try OnlineBattleArenaFixture.arena(seat: .p1); defer { fixture.close() }
        try fixture.play(rounds: 1)
        XCTAssertTrue(fixture.staging.isPlaying)
        var slots: [Int] = []
        fixture.model.onAction = { if case .chooseMove(let slot) = $0 { slots.append(slot) } }
        let arena = arenaView(fixture.model)
        XCTAssertEqual(fixture.model.request?.kind, "move")
        for move in fixture.model.request?.moves ?? [] { XCTAssertFalse(arena.movesLocked(move.slot), "slot \(move.slot)") }
        fixture.model.send(.chooseMove(2))
        XCTAssertEqual(slots, [2])
        XCTAssertTrue(fixture.model.choiceSubmitted)
        XCTAssertTrue(arena.movesLocked(1), "after the choice the picker locks until the next turn")
        XCTAssertTrue(fixture.staging.isPlaying, "choosing leaves the beats alone")
    }

    // MARK: cards follow the frame and the staging

    func testSecondSeatCardsShowOwnAndFoeFromTheFrame() throws {
        let fixture = try OnlineBattleArenaFixture.arena(seat: .p2); defer { fixture.close() }
        try fixture.play(rounds: 1)
        let view = try XCTUnwrap(fixture.model.arena), arena = arenaView(fixture.model)
        let own = arena.sideCard(.player, view: view), other = arena.sideCard(.opponent, view: view)
        XCTAssertTrue(own.own); XCTAssertFalse(other.own)
        XCTAssertEqual(own.side.speciesNum, view.p2.speciesNum, "the second seat's own card shows the second Pokémon")
        XCTAssertEqual(other.side.speciesNum, view.p1.speciesNum)
        XCTAssertNotEqual(own.side.speciesNum, other.side.speciesNum)
        XCTAssertEqual(own.snapshot?.set.speciesNum, view.p2.speciesNum, "my snapshot, never the other seat's")
        XCTAssertNil(other.snapshot, "the opponent's frozen set is never in the arena")
        XCTAssertEqual(own.display, fixture.staging.shown(.player))
        XCTAssertEqual(other.display, fixture.staging.shown(.opponent))
    }

    func testCardsCarryTheBeatsDeltaAndTheHitThatShakesTheSprite() throws {
        let fixture = try OnlineBattleArenaFixture.arena(seat: .p1); defer { fixture.close() }
        try fixture.play(rounds: 1)
        let beat = try XCTUnwrap(fixture.staging.playback.beat), view = try XCTUnwrap(fixture.model.arena)
        let arena = arenaView(fixture.model)
        var sawDelta = false
        for side in [PracticeSide.player, .opponent] {
            let card = arena.sideCard(side, view: view)
            XCTAssertEqual(card.beatID, beat.id)
            XCTAssertEqual(card.delta, beat.hpDelta[side])
            XCTAssertEqual(card.display, beat.after[side], "the card already shows the beat's outcome")
            if (beat.hpDelta[side] ?? 0) < 0 { XCTAssertEqual(card.hitTrigger, beat.id); sawDelta = true }
        }
        XCTAssertTrue(sawDelta, "the first round must hurt someone for this to prove anything")
        fixture.staging.skipToEnd(); fixture.publish()
        let rest = arena.sideCard(.opponent, view: view)
        XCTAssertNil(rest.beatID); XCTAssertNil(rest.delta)
        XCTAssertEqual(rest.display, fixture.staging.atRest(.opponent))
    }

    /// Between beats the card shows the engine's view; a missing stage must not turn a fainted side back to life.
    func testWithoutAStageTheCardsDrawFromTheViewAndKeepTheFaintedFlag() {
        let model = OnlineBattleScreenRenderingTests.model()
        OnlineBattleScreenRenderingTests.arena(model)
        model.localSide = .p2
        let view = BattleView(turn: 4, ended: true,
                              p1: .init(speciesNum: 25, species: "Pikachu", level: 50, types: ["Electric"], hp: 0, maxhp: 110, status: "par", moves: [], ability: nil),
                              p2: .init(speciesNum: 129, species: "Magikarp", level: 50, types: ["Water"], hp: 30, maxhp: 100, status: "", moves: [], ability: nil))
        model.arena = view
        let arena = arenaView(model)
        let other = arena.sideCard(.opponent, view: view), own = arena.sideCard(.player, view: view)
        XCTAssertEqual(other.side.species, "Pikachu"); XCTAssertEqual(own.side.species, "Magikarp")
        XCTAssertEqual(other.display?.fainted, true)
        XCTAssertEqual(other.display?.hp, 0)
        XCTAssertNil(other.display?.status, "a fainted side shows no status")
        XCTAssertEqual(own.display, PracticeDisplaySide(hp: 30, maxHP: 100, status: nil, fainted: false))
    }

    func testRestingDisplayMatchesWhatTheStagingShowsAtRest() throws {
        let fixture = try OnlineBattleArenaFixture.arena(seat: .p1); defer { fixture.close() }
        try fixture.play(rounds: 3); fixture.staging.skipToEnd()
        let view = try XCTUnwrap(fixture.model.arena)
        for side in [PracticeSide.player, .opponent] {
            XCTAssertEqual(OnlineBattleStaging.resting(fixture.staging.frame.pokemon(side, in: view)), fixture.staging.atRest(side))
        }
    }

    // MARK: what the opponent has shown so far

    func testStagedRevealStopsAtTheBeatOnScreen() {
        var now = 0.0
        let playback = PracticePlayback(clock: { now })
        playback.enqueue([.switchIn(.player, hp: 100, maxHP: 100), .switchIn(.opponent, hp: 100, maxHP: 100), .turn(1),
                          .move(.opponent, moveID: "tackle"), .damage(.player, hp: 80, maxHP: 100, cause: nil),
                          .abilityRevealed(.opponent, abilityID: "pressure"), .turn(2),
                          .move(.opponent, moveID: "splash"), .move(.opponent, moveID: "struggle"), .turn(3)])
        XCTAssertEqual(PracticeReveal(staged: playback), PracticeReveal(moves: ["tackle"], ability: "pressure"))
        now += PracticePlayback.actionBeat; playback.advance()
        XCTAssertEqual(PracticeReveal(staged: playback), PracticeReveal(moves: ["tackle", "splash"], ability: "pressure"),
                       "the next move shows once its beat starts")
        playback.skipToEnd()
        XCTAssertEqual(PracticeReveal(staged: playback).moves, ["tackle", "splash"], "Struggle is never a revealed move")
        XCTAssertEqual(PracticeReveal(staged: PracticePlayback(clock: { 0 })), PracticeReveal())
    }

    func testTheOpponentCardRevealsOnlyWhatTheBeatsShowedWhilePlayingAndTheViewAtRest() throws {
        let fixture = try OnlineBattleArenaFixture.arena(seat: .p1); defer { fixture.close() }
        try fixture.play(rounds: 1)
        XCTAssertTrue(fixture.staging.isPlaying)
        let view = try XCTUnwrap(fixture.model.arena), arena = arenaView(fixture.model)
        XCTAssertEqual(arena.sideCard(.opponent, view: view).reveal, PracticeReveal(staged: fixture.staging.playback))
        XCTAssertNil(arena.sideCard(.player, view: view).reveal, "my own moves are never hidden")
        fixture.staging.skipToEnd(); fixture.publish()
        XCTAssertNil(arena.sideCard(.opponent, view: view).reveal, "at rest the engine's view is the source")
    }

    // MARK: staged words

    func testShownTurnFollowsTheBeatThenTheView() throws {
        let fixture = try OnlineBattleArenaFixture.arena(seat: .p1); defer { fixture.close() }
        try fixture.play(rounds: 2)
        let arena = arenaView(fixture.model), view = try XCTUnwrap(fixture.model.arena)
        let beat = try XCTUnwrap(fixture.staging.playback.beat)
        XCTAssertEqual(arena.shownTurn(view), beat.turn)
        XCTAssertLessThan(beat.turn, view.turn, "the view is a turn ahead of the beat on screen")
        fixture.staging.skipToEnd(); fixture.publish()
        XCTAssertEqual(arena.shownTurn(view), view.turn)
    }

    /// The own moves come from my snapshot and the foe's from the slugs the session published, so no name
    /// reads as a raw engine id.
    func testWordingResolvesMoveNamesThroughSnapshotAndSlugs() throws {
        let fixture = try OnlineBattleArenaFixture.arena(seat: .p1); defer { fixture.close() }
        try fixture.play(rounds: 1)
        fixture.model.moveSlugs[.p2] = ["volttackle": "volt-tackle"]
        let wording = arenaView(fixture.model).wording
        XCTAssertEqual(wording.move(.player, "quickattack"), .resource(.init(kind: .move, name: "quick-attack")))
        XCTAssertEqual(wording.move(.opponent, "volttackle"), .resource(.init(kind: .move, name: "volt-tackle")))
        XCTAssertEqual(wording.move(.opponent, "tackle"), .resource(.init(kind: .move, name: "tackle")))
        XCTAssertEqual(wording.ability(.player, "static"), .resource(.init(kind: .ability, name: "static")))
    }

    func testWordingNamesFollowTheSeat() throws {
        let fixture = try OnlineBattleArenaFixture.arena(seat: .p2); defer { fixture.close() }
        try fixture.play(rounds: 1)
        let view = try XCTUnwrap(fixture.model.arena), wording = arenaView(fixture.model).wording
        XCTAssertEqual(wording.name(.player), view.p2.species)
        XCTAssertEqual(wording.name(.opponent), view.p1.species)
    }

    // MARK: sprites

    func testOwnSpriteKeepsShinyAndFormFromMySnapshot() throws {
        let set = BattleSet(speciesNum: 26, form: "alola", level: 50, gender: .male, nature: "Hardy", ability: "static",
                            moves: ["thunderbolt"], ivs: [:], shiny: true)
        let info = BattlePublicInfo(speciesNum: 26, species: "Raichu-Alola", level: 50, types: ["Electric", "Psychic"], stats: [:])
        let snapshot = OnlineBattleSnapshot(instanceId: "shiny-raichu", set: set, publicInfo: info, hp: 90)
        let display = snapshot.displaySnapshot
        XCTAssertEqual(display.set, set)
        XCTAssertEqual(display.instanceID, "shiny-raichu")
        XCTAssertEqual(display.publicInfo, info)
        let model = OnlineBattleScreenRenderingTests.model()
        OnlineBattleScreenRenderingTests.arena(model)
        let base = OnlineBattleScreenRenderingTests.room()
        model.room = .init(battleId: base.battleId, state: .running, revision: 1, mode: .manual,
                           p1: .init(trainerId: "synthetic-me", snapshot: snapshot, publicInfo: nil, hpPercent: nil), p2: base.p2,
                           createdAt: base.createdAt, expiresAt: base.expiresAt, startedAt: 0, reportedAt: nil, confirmed: true,
                           config: nil, roundSeq: 1, deadline: nil, ownChoice: nil, journal: [], result: nil, reason: nil, rematchOf: nil)
        let view = try XCTUnwrap(model.arena)
        let card = arenaView(model).sideCard(.player, view: view)
        XCTAssertEqual(card.snapshot?.set.shiny, true)
        XCTAssertEqual(card.snapshot?.set.form, "alola")
        XCTAssertNil(arenaView(model).sideCard(.opponent, view: view).snapshot)
    }
}
