import XCTest
@testable import PokeTokenBar

@MainActor
final class PracticePlaybackTests: XCTestCase {
    private final class Clock { var now = 0.0 }

    private func parse(_ lines: [String]) -> [PracticeEvent] {
        var parser = PracticeEventParser()
        return parser.parse(lines)
    }
    private func makePlayback(_ clock: Clock) -> PracticePlayback { PracticePlayback(clock: { clock.now }) }

    private let seeded: [PracticeEvent] = [
        .switchIn(.player, hp: 100, maxHP: 100), .switchIn(.opponent, hp: 100, maxHP: 100), .turn(1),
    ]
    /// Volt Tackle KO with recoil, as the engine prints it (player HP in percent for round numbers).
    private let koTurn: [PracticeEvent] = [
        .move(.player, moveID: "volttackle"), .superEffective(.opponent),
        .damage(.opponent, hp: 0, maxHP: 100, cause: nil), .faint(.opponent),
        .damage(.player, hp: 72, maxHP: 100, cause: "recoil"), .end(winner: .player),
    ]

    // MARK: parser

    func testParsesTheRealVoltTackleKoLog() {
        let lines = [
            "|gametype|singles", "|player|p1|p1||", "|player|p2|p2||", "|gen|9", "|tier|[Gen 9] Custom Game",
            "|rule|Terastal Clause: You cannot Terastallize", "|raw|<div class=\"infobox\">x</div>", "|clearpoke",
            "|poke|p1|Pikachu, L50, M|", "|poke|p2|Magikarp, L50, M|", "|teampreview", "|",
            "|teamsize|p1|1", "|teamsize|p2|1", "|start",
            "|switch|p1a: Pikachu|Pikachu, L50, M|110/110", "|switch|p2a: Magikarp|Magikarp, L50, M|100/100",
            "|turn|1", "", "|move|p1a: Pikachu|Volt Tackle|p2a: Magikarp", "|-supereffective|p2a: Magikarp",
            "|-damage|p2a: Magikarp|0 fnt", "|faint|p2a: Magikarp", "|-damage|p1a: Pikachu|79/110|[from] Recoil",
            "|upkeep", "|debug|x", "|win|p1",
        ]
        XCTAssertEqual(parse(lines), [
            .switchIn(.player, hp: 110, maxHP: 110), .switchIn(.opponent, hp: 100, maxHP: 100), .turn(1),
            .move(.player, moveID: "volttackle"), .superEffective(.opponent),
            .damage(.opponent, hp: 0, maxHP: 100, cause: nil), .faint(.opponent),
            .damage(.player, hp: 79, maxHP: 110, cause: "recoil"), .end(winner: .player),
        ])
    }

    func testFaintHPUsesTheMaxHPRememberedFromTheSwitch() {
        var parser = PracticeEventParser()
        _ = parser.parse(["|switch|p1a: Pikachu|Pikachu, L50, M|110/110", "|switch|p2a: Magikarp|Magikarp, L50, M|100/100"])
        XCTAssertEqual(parser.parse(["|-damage|p1a: Pikachu|0 fnt"]), [.damage(.player, hp: 0, maxHP: 110, cause: nil)])
        XCTAssertEqual(parser.parse(["|-damage|p2a: Magikarp|0 fnt"]), [.damage(.opponent, hp: 0, maxHP: 100, cause: nil)])
        // A fresh parser has no memory of the other battle.
        var fresh = PracticeEventParser()
        XCTAssertEqual(fresh.parse(["|-damage|p1a: Pikachu|0 fnt"]), [.damage(.player, hp: 0, maxHP: 100, cause: nil)])
    }

    func testStatusSuffixOnHPAndResidualCause() {
        XCTAssertEqual(parse(["|-status|p2a: Lapras|psn", "|-damage|p2a: Lapras|73/100 psn|[from] psn", "|cant|p1a: Muk|frz"]), [
            .status(.opponent, code: "psn"), .damage(.opponent, hp: 73, maxHP: 100, cause: "psn"), .cant(.player, reason: "frz"),
        ])
    }

    func testCausePrefixesAreStrippedAndLowercased() {
        XCTAssertEqual(parse([
            "|-heal|p1a: X|90/110|[from] drain|[of] p2a: Y", "|-heal|p1a: X|100/110|[from] item: Leftovers",
            "|-damage|p2a: X|80/100|[from] ability: Rough Skin|[of] p1a: Y", "|-damage|p2a: X|70/100|[from] Sandstorm",
            "|-heal|p1a: X|110/110",
        ]), [
            .heal(.player, hp: 90, maxHP: 110, cause: "drain"), .heal(.player, hp: 100, maxHP: 110, cause: "leftovers"),
            .damage(.opponent, hp: 80, maxHP: 100, cause: "rough skin"), .damage(.opponent, hp: 70, maxHP: 100, cause: "sandstorm"),
            .heal(.player, hp: 110, maxHP: 110, cause: nil),
        ])
    }

    func testEffectivenessCritMissFailAndImmuneNameTheRightSide() {
        XCTAssertEqual(parse([
            "|-crit|p2a: Garchomp", "|-resisted|p2a: X", "|-immune|p1a: X", "|-miss|p1a: X|p2a: Y", "|-fail|p1a: X",
            "|-miss|p2a: X|p1a: Y",
        ]), [.critical(.opponent), .resisted(.opponent), .immune(.player), .miss(.player), .failed(.player), .miss(.opponent)])
    }

    func testStatusBoostAndWeatherLines() {
        XCTAssertEqual(parse([
            "|-curestatus|p1a: X|slp|[msg]", "|-boost|p1a: X|atk|1", "|-unboost|p2a: X|def|2",
            "|-weather|Sandstorm", "|-weather|none", "|-weather|Sandstorm|[upkeep]",
        ]), [
            .cureStatus(.player, code: "slp"), .boost(.player, stat: "atk", stages: 1), .boost(.opponent, stat: "def", stages: -2),
            .weather("sandstorm"), .weather(nil),
        ])
    }

    func testWinAndTieEndTheBattle() {
        XCTAssertEqual(parse(["|win|p1"]), [.end(winner: .player)])
        XCTAssertEqual(parse(["|win|p2"]), [.end(winner: .opponent)])
        XCTAssertEqual(parse(["|tie"]), [.end(winner: nil)])
    }

    func testUnmodeledAndBlankLinesProduceNothing() {
        XCTAssertEqual(parse(["", "|", "|upkeep", "|debug|x", "|raw|<b>", "|player|p1|p1||", "|poke|p1|Pikachu, L50|", "|teamsize|p1|1",
                              "|gen|9", "|tier|x", "|rule|y", "|start", "|-ability|p1a: X|Pressure", "|-activate|p1a: X|confusion"]), [])
    }

    func testMoveNamesBecomeShowdownIds() {
        XCTAssertEqual(parse(["|move|p2a: X|Will-O-Wisp|p1a: Y", "|move|p1a: X|U-turn|p2a: Y", "|move|p1a: X|Double Slap|p2a: Y"]), [
            .move(.opponent, moveID: "willowisp"), .move(.player, moveID: "uturn"), .move(.player, moveID: "doubleslap"),
        ])
    }

    // MARK: playback

    func testSwitchInSeedsTheDisplayWithoutABeat() {
        let clock = Clock(); let playback = makePlayback(clock)
        playback.enqueue([.switchIn(.player, hp: 110, maxHP: 110), .switchIn(.opponent, hp: 100, maxHP: 100), .turn(1)])
        XCTAssertEqual(playback.display[.player], PracticeDisplaySide(hp: 110, maxHP: 110, status: nil, fainted: false))
        XCTAssertEqual(playback.display[.opponent], PracticeDisplaySide(hp: 100, maxHP: 100, status: nil, fainted: false))
        XCTAssertNil(playback.beat); XCTAssertFalse(playback.isPlaying); XCTAssertTrue(playback.history.isEmpty)
    }

    func testFirstBeatStartsOnEnqueueAndTheDisplayChangesOnlyWhenItCompletes() throws {
        let clock = Clock(); let playback = makePlayback(clock)
        clock.now = 5
        playback.enqueue(seeded + koTurn)
        let beat = try XCTUnwrap(playback.beat)
        XCTAssertTrue(playback.isPlaying)
        XCTAssertEqual(beat.actor, .player); XCTAssertEqual(beat.moveID, "volttackle"); XCTAssertEqual(beat.turn, 1)
        XCTAssertEqual(playback.display[.opponent]?.hp, 100)
        clock.now = 5 + PracticePlayback.actionBeat - 0.01; playback.advance()
        XCTAssertEqual(playback.beat, beat); XCTAssertEqual(playback.display[.opponent]?.hp, 100)
        XCTAssertTrue(playback.history.isEmpty)
        clock.now = 5 + PracticePlayback.actionBeat; playback.advance()
        XCTAssertNil(playback.beat); XCTAssertFalse(playback.isPlaying)
        XCTAssertEqual(playback.display[.opponent]?.hp, 0); XCTAssertEqual(playback.display[.opponent]?.fainted, true)
        XCTAssertEqual(playback.display[.player]?.hp, 72)
        XCTAssertEqual(playback.history, [beat]); XCTAssertEqual(playback.recent, [beat])
        XCTAssertEqual(beat.after, playback.display)
    }

    func testRecoilStaysInTheAttackersBeatWithItsCallouts() throws {
        let clock = Clock(); let playback = makePlayback(clock)
        playback.enqueue(seeded + koTurn)
        playback.skipToEnd()
        XCTAssertEqual(playback.history.count, 1)
        let beat = try XCTUnwrap(playback.history.first)
        XCTAssertEqual(beat.callouts, [.superEffective(.opponent), .fainted(.opponent), .recoil(.player)])
        XCTAssertEqual(beat.hpDelta[.opponent], -100); XCTAssertEqual(beat.hpDelta[.player], -28)
    }

    func testPoisonIsAResidualBeatWithNoActor() throws {
        let clock = Clock(); let playback = makePlayback(clock)
        playback.enqueue(seeded + [
            .turn(2),
            .move(.player, moveID: "tackle"), .damage(.opponent, hp: 90, maxHP: 100, cause: nil),
            .move(.opponent, moveID: "splash"),
            .damage(.opponent, hp: 73, maxHP: 100, cause: "psn"),
            .turn(3),
        ])
        XCTAssertEqual(playback.beat?.actor, .player)
        clock.now = PracticePlayback.actionBeat; playback.advance()
        XCTAssertEqual(playback.beat?.actor, .opponent)
        clock.now += PracticePlayback.actionBeat; playback.advance()
        let residual = try XCTUnwrap(playback.beat), residualStart = clock.now
        XCTAssertNil(residual.actor); XCTAssertNil(residual.moveID); XCTAssertEqual(residual.hpDelta[.opponent], -17)
        clock.now = residualStart + PracticePlayback.residualBeat - 0.01; playback.advance()
        XCTAssertEqual(playback.beat, residual)
        clock.now = residualStart + PracticePlayback.residualBeat; playback.advance()
        XCTAssertFalse(playback.isPlaying)
        XCTAssertEqual(playback.history.map(\.actor), [.player, .opponent, nil])
        XCTAssertEqual(playback.history.map(\.turn), [2, 2, 2])
        XCTAssertEqual(playback.history.map { $0.hpDelta[.opponent] }, [-10, 0, -17])
        XCTAssertEqual(Set(playback.history.map(\.id)).count, 3)
    }

    func testDrainHealStaysInTheActionBeat() {
        let playback = makePlayback(Clock())
        playback.enqueue(seeded + [
            .move(.player, moveID: "gigadrain"), .damage(.opponent, hp: 70, maxHP: 100, cause: nil),
            .damage(.player, hp: 60, maxHP: 100, cause: "life orb"), .heal(.player, hp: 80, maxHP: 100, cause: "drain"),
        ])
        playback.skipToEnd()
        XCTAssertEqual(playback.history.count, 1)
        XCTAssertEqual(playback.history.first?.hpDelta[.player], -20)
    }

    func testCantStartsAnActorBeatWithAReasonCallout() {
        let playback = makePlayback(Clock())
        playback.enqueue(seeded + [.cant(.player, reason: "frz"), .move(.opponent, moveID: "tackle")])
        XCTAssertEqual(playback.beat?.actor, .player); XCTAssertNil(playback.beat?.moveID)
        XCTAssertEqual(playback.beat?.callouts, [.cant(.player, reason: "frz")])
    }

    func testWakeUpBeforeTheMoveBelongsToThatMovesBeat() {
        let playback = makePlayback(Clock())
        playback.enqueue(seeded + [
            .move(.opponent, moveID: "tackle"), .damage(.player, hp: 80, maxHP: 100, cause: nil),
            .cureStatus(.player, code: "slp"), .move(.player, moveID: "tackle"),
        ])
        playback.skipToEnd()
        XCTAssertEqual(playback.history.map(\.callouts), [[], [.cureStatus(.player, code: "slp")]])
    }

    func testWeatherEndJoinsAResidualBeat() {
        let playback = makePlayback(Clock())
        playback.enqueue(seeded + [.move(.player, moveID: "tackle"), .weather(nil)])
        playback.skipToEnd()
        XCTAssertEqual(playback.history.map(\.actor), [.player, nil])
        XCTAssertEqual(playback.history.last?.callouts, [.weather(nil)])
    }

    func testAbilityAtBattleStartRidesTheFirstActionBeatInsteadOfHoldingTheBattle() {
        let playback = makePlayback(Clock())
        playback.enqueue(seeded + [.abilityRevealed(.opponent, abilityID: "pressure")])
        XCTAssertFalse(playback.isPlaying)
        playback.enqueue([.move(.player, moveID: "tackle"), .damage(.opponent, hp: 90, maxHP: 100, cause: nil)])
        XCTAssertEqual(playback.beat?.callouts, [.abilityRevealed(.opponent, abilityID: "pressure")])
    }

    func testAbilityRevealedAfterTheEndJoinsTheLastBeat() {
        let playback = makePlayback(Clock())
        playback.enqueue(seeded + koTurn + [.abilityRevealed(.player, abilityID: "static")])
        playback.skipToEnd()
        XCTAssertEqual(playback.history.count, 1)
        XCTAssertEqual(playback.history.first?.callouts.last, .abilityRevealed(.player, abilityID: "static"))
    }

    func testConfusionSelfHitIsTheConfusedSidesOwnBeat() {
        let playback = makePlayback(Clock())
        playback.enqueue(seeded + [
            .move(.opponent, moveID: "tackle"), .damage(.player, hp: 90, maxHP: 100, cause: nil),
            .damage(.player, hp: 80, maxHP: 100, cause: "confusion"),
        ])
        playback.skipToEnd()
        XCTAssertEqual(playback.history.map(\.actor), [.opponent, .player])
        XCTAssertEqual(playback.history.map { $0.hpDelta[.player] }, [-10, -10])
    }

    func testEndAloneMakesNoBeat() {
        let playback = makePlayback(Clock())
        playback.enqueue(seeded + [.end(winner: nil)])
        XCTAssertFalse(playback.isPlaying); XCTAssertTrue(playback.history.isEmpty)
    }

    func testTimedOutBecomesACalloutOnThePlayersNextBeatOnly() {
        let playback = makePlayback(Clock())
        playback.enqueue(seeded + [
            .timedOut, .move(.opponent, moveID: "tackle"), .move(.player, moveID: "tackle"),
            .move(.player, moveID: "tackle"), .turn(2),
        ])
        playback.skipToEnd()
        XCTAssertEqual(playback.history.map(\.callouts), [[], [.timedOut], []])
        // The timeout belongs to that turn: a player who never acted does not carry it into the next turn.
        playback.enqueue([.timedOut, .move(.opponent, moveID: "tackle"), .turn(3), .move(.player, moveID: "tackle")])
        playback.skipToEnd()
        XCTAssertEqual(playback.history.suffix(2).map(\.callouts), [[], []])
    }

    func testRecentIsNewestFirstCappedAtFiveAndHistoryKeepsOrder() {
        let clock = Clock(); let playback = makePlayback(clock)
        let ids = (1...7).map { "m\($0)" }
        playback.enqueue(seeded + ids.map { .move(.player, moveID: $0) })
        for _ in ids { clock.now += PracticePlayback.actionBeat; playback.advance() }
        XCTAssertFalse(playback.isPlaying)
        XCTAssertEqual(playback.history.map(\.moveID), ids)
        XCTAssertEqual(playback.recent.map(\.moveID), ["m7", "m6", "m5", "m4", "m3"])
        XCTAssertEqual(playback.history.map(\.id), playback.history.map(\.id).sorted())
    }

    func testBatchesQueueBehindThePlayingBeatAndChainTheirHP() {
        let clock = Clock(); let playback = makePlayback(clock)
        playback.enqueue(seeded + [.move(.player, moveID: "a"), .damage(.opponent, hp: 60, maxHP: 100, cause: nil)])
        playback.enqueue([.move(.player, moveID: "b"), .damage(.opponent, hp: 20, maxHP: 100, cause: nil)])
        XCTAssertEqual(playback.beat?.moveID, "a"); XCTAssertTrue(playback.isPlaying)
        clock.now = PracticePlayback.actionBeat; playback.advance()
        XCTAssertEqual(playback.display[.opponent]?.hp, 60); XCTAssertEqual(playback.beat?.moveID, "b")
        XCTAssertEqual(playback.beat?.hpDelta[.opponent], -40)
        clock.now += PracticePlayback.actionBeat; playback.advance()
        XCTAssertEqual(playback.display[.opponent]?.hp, 20); XCTAssertFalse(playback.isPlaying)
    }

    func testStatusAndFaintShapeTheDisplay() {
        let playback = makePlayback(Clock())
        playback.enqueue(seeded + [
            .move(.player, moveID: "toxic"), .status(.opponent, code: "psn"),
            .move(.opponent, moveID: "tackle"), .damage(.player, hp: 0, maxHP: 100, cause: nil), .faint(.player),
        ])
        playback.skipToEnd()
        XCTAssertEqual(playback.display[.opponent]?.status, "psn")
        XCTAssertEqual(playback.display[.player]?.fainted, true); XCTAssertEqual(playback.display[.player]?.percent, 0)
    }

    func testSkipToEndCommitsEveryBeatAtOnce() {
        let clock = Clock(); let playback = makePlayback(clock)
        playback.enqueue(seeded + [
            .move(.player, moveID: "a"), .damage(.opponent, hp: 60, maxHP: 100, cause: nil),
            .move(.opponent, moveID: "b"), .damage(.player, hp: 70, maxHP: 100, cause: nil),
            .damage(.opponent, hp: 50, maxHP: 100, cause: "psn"),
        ])
        XCTAssertTrue(playback.isPlaying)
        playback.skipToEnd()
        XCTAssertFalse(playback.isPlaying); XCTAssertNil(playback.beat)
        XCTAssertEqual(playback.history.map(\.moveID), ["a", "b", nil])
        XCTAssertEqual(playback.recent.map(\.moveID), [nil, "b", "a"])
        XCTAssertEqual(playback.display[.opponent]?.hp, 50); XCTAssertEqual(playback.display[.player]?.hp, 70)
        clock.now = 100; playback.advance()
        XCTAssertEqual(playback.history.count, 3)
    }

    func testSummaryTotalsFromTheBeatsThatPlayed() {
        let playback = makePlayback(Clock())
        playback.enqueue(seeded + [
            .move(.player, moveID: "thunderbolt"), .critical(.opponent), .superEffective(.opponent),
            .damage(.opponent, hp: 55, maxHP: 100, cause: nil),
            .move(.opponent, moveID: "tackle"), .damage(.player, hp: 80, maxHP: 100, cause: nil),
            .turn(2),
            .move(.player, moveID: "volttackle"), .superEffective(.opponent),
            .damage(.opponent, hp: 0, maxHP: 100, cause: nil), .faint(.opponent),
            .damage(.player, hp: 52, maxHP: 100, cause: "recoil"), .end(winner: .player),
        ])
        XCTAssertEqual(playback.summary, PracticeSummary())
        playback.skipToEnd()
        XCTAssertEqual(playback.summary, PracticeSummary(turns: 2, damageDealtPercent: 100, damageTakenPercent: 48,
                                                         finishingMoveID: "volttackle", criticalHits: 1, superEffectiveHits: 2))
    }

    func testSummaryHasNoFinishingMoveForADrawOrAFaintFromPoison() {
        let draw = makePlayback(Clock())
        draw.enqueue(seeded + [
            .move(.player, moveID: "explosion"), .damage(.opponent, hp: 0, maxHP: 100, cause: nil), .faint(.opponent),
            .faint(.player), .end(winner: nil),
        ])
        draw.skipToEnd()
        XCTAssertNil(draw.summary.finishingMoveID)
        let poison = makePlayback(Clock())
        poison.enqueue(seeded + [
            .move(.player, moveID: "toxic"), .move(.opponent, moveID: "splash"),
            .damage(.opponent, hp: 0, maxHP: 100, cause: "psn"), .faint(.opponent), .end(winner: .player),
        ])
        poison.skipToEnd()
        XCTAssertNil(poison.summary.finishingMoveID); XCTAssertEqual(poison.summary.turns, 1)
    }

    func testSummaryDamageSumsOnlyTheNegativeDeltas() {
        let playback = makePlayback(Clock())
        playback.enqueue(seeded + [
            .move(.opponent, moveID: "tackle"), .damage(.player, hp: 70, maxHP: 100, cause: nil),
            .move(.player, moveID: "recover"), .heal(.player, hp: 90, maxHP: 100, cause: nil),
            .move(.opponent, moveID: "tackle"), .damage(.player, hp: 60, maxHP: 100, cause: nil),
        ])
        playback.skipToEnd()
        XCTAssertEqual(playback.summary.damageTakenPercent, 30 + 30)
        XCTAssertEqual(playback.summary.damageDealtPercent, 0)
    }

    func testSethpBecomesDamageOrHealFromTheSidesLastKnownHP() {
        XCTAssertEqual(parse([
            "|switch|p1a: Snorlax|Snorlax, L50, M|280/280", "|switch|p2a: Gengar|Gengar, L50, M|100/100",
            "|-damage|p1a: Snorlax|250/280", "|-sethp|p1a: Snorlax|219/280|[from] move: Pain Split|[silent]",
            "|-sethp|p1a: Snorlax|260/280|[from] move: Pain Split", "|-sethp|p2a: Gengar|60/100 psn|[from] move: Pain Split",
        ]), [
            .switchIn(.player, hp: 280, maxHP: 280), .switchIn(.opponent, hp: 100, maxHP: 100),
            .damage(.player, hp: 250, maxHP: 280, cause: nil),
            .damage(.player, hp: 219, maxHP: 280, cause: "pain split"),
            .heal(.player, hp: 260, maxHP: 280, cause: "pain split"),
            .damage(.opponent, hp: 60, maxHP: 100, cause: "pain split"),
        ])
    }

    func testIntroShownIsAScreenFlagThatPlaybackNeverTouches() {
        let playback = makePlayback(Clock())
        XCTAssertFalse(playback.introShown)
        playback.introShown = true
        playback.enqueue(seeded + koTurn)
        playback.skipToEnd()
        XCTAssertTrue(playback.introShown)
    }

    func testSetboostIsABoostWithItsAbsoluteStage() {
        XCTAssertEqual(parse(["|-setboost|p1a: Snorlax|atk|6|[from] move: Belly Drum"]), [.boost(.player, stat: "atk", stages: 6)])
    }

    func testPainSplitMovesBothBarsAndTheDeltasStayExact() throws {
        let playback = makePlayback(Clock())
        playback.enqueue(parse([
            "|switch|p1a: Snorlax|Snorlax, L50, M|280/280", "|switch|p2a: Gengar|Gengar, L50, M|100/100", "|turn|1",
            "|move|p1a: Snorlax|Pain Split|p2a: Gengar", "|-sethp|p2a: Gengar|60/100|[from] move: Pain Split|[silent]",
            "|-sethp|p1a: Snorlax|258/280|[from] move: Pain Split",
        ]))
        playback.skipToEnd()
        XCTAssertEqual(playback.history.map(\.actor), [.player])
        let beat = try XCTUnwrap(playback.history.first)
        XCTAssertEqual(beat.hpDelta[.opponent], -40); XCTAssertEqual(beat.hpDelta[.player], -8)
        XCTAssertEqual(playback.display[.player]?.hp, 258); XCTAssertEqual(playback.display[.opponent]?.hp, 60)
        XCTAssertEqual(playback.summary.damageTakenPercent, 8); XCTAssertEqual(playback.summary.damageDealtPercent, 40)
    }

    func testMoveSelfDamageStaysInTheActionBeatButMoveResidualsDoNot() {
        // Crash damage names the move the actor just used; so can a trap, a seed or the weather it set.
        let crash = makePlayback(Clock())
        crash.enqueue(seeded + [
            .move(.opponent, moveID: "splash"), .move(.player, moveID: "highjumpkick"),
            .damage(.player, hp: 60, maxHP: 100, cause: "highjumpkick"),
        ])
        crash.skipToEnd()
        XCTAssertEqual(crash.history.map(\.actor), [.opponent, .player])
        XCTAssertEqual(crash.history.last?.hpDelta[.player], -40)
        let jump = makePlayback(Clock())
        jump.enqueue(seeded + [.move(.player, moveID: "jumpkick"), .damage(.player, hp: 70, maxHP: 100, cause: "jumpkick")])
        jump.skipToEnd()
        XCTAssertEqual(jump.history.map(\.actor), [.player])
        for (move, cause) in [("leechseed", "leech seed"), ("wrap", "wrap"), ("firespin", "fire spin"), ("sandstorm", "sandstorm"),
                              ("curse", "curse"), ("nightmare", "nightmare")] {
            let residual = makePlayback(Clock())
            residual.enqueue(seeded + [.move(.player, moveID: move), .damage(.opponent, hp: 88, maxHP: 100, cause: cause)])
            residual.skipToEnd()
            XCTAssertEqual(residual.history.map(\.actor), [.player, nil], move)
        }
    }
}

// MARK: engine
// Everything below needs the real battle engine bundle.

@MainActor
final class PracticePlaybackEngineTests: XCTestCase {
    private func engine() throws -> BattleEngine {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try BattleEngine(url: root.appendingPathComponent("engine/dist/battle-engine.js"))
    }
    private func candidate(_ id: String, species: Int, ability: String, moves: [String], engine: BattleEngine) throws -> PracticeCandidate {
        var profile = PokemonProfile.generate(seed: 42, instanceID: id)
        profile.level = 50; profile.gender = .male; profile.abilityName = ability
        profile.moves = moves.map { PokemonKnownMove(name: $0, learnedAtLevel: 1) }
        let snapshot = try BattleSnapshot.make(speciesID: species, nature: .hardy, profile: profile, using: engine)
        return PracticeCandidate(id: id, name: id, snapshot: snapshot, blockedReason: nil)
    }

    func testSeededVoltTackleKoParsesFromTheRealEngineAndPlaysAsOneBeat() throws {
        let engine = try engine(); var now = 0.0
        let model = PracticeBattle(engine: engine, clock: { now })
        model.start(player: try candidate("pika", species: 25, ability: "static", moves: ["thunderbolt", "quick-attack", "iron-tail", "volt-tackle"], engine: engine),
                    opponent: try candidate("karp", species: 129, ability: "swift-swim", moves: ["splash", "tackle", "flail", "bounce"], engine: engine),
                    mode: .automatic, seed: [1, 2, 3, 4])
        now = 1; model.tick()
        XCTAssertEqual(model.phase, .finished); XCTAssertEqual(model.result?.winner, "p1")
        let events = model.events
        XCTAssertTrue(events.contains(.move(.player, moveID: "volttackle")), "\(events)")
        XCTAssertTrue(events.contains(.superEffective(.opponent)))
        XCTAssertTrue(events.contains(.faint(.opponent)))
        XCTAssertTrue(events.contains {
            if case .damage(let side, _, _, let cause) = $0 { return side == .player && cause == "recoil" }
            return false
        })
        XCTAssertEqual(events.last, .end(winner: .player))

        let playback = PracticePlayback(clock: { now })
        playback.enqueue(events)
        playback.skipToEnd()
        let beat = try XCTUnwrap(playback.history.first)
        XCTAssertEqual(playback.history.count, 1)
        XCTAssertEqual(beat.actor, .player); XCTAssertEqual(beat.moveID, "volttackle")
        XCTAssertTrue(beat.callouts.contains(.superEffective(.opponent)))
        XCTAssertTrue(beat.callouts.contains(.fainted(.opponent)))
        XCTAssertTrue(beat.callouts.contains(.recoil(.player)))
        XCTAssertEqual(beat.hpDelta[.opponent], -100)
        XCTAssertLessThan(beat.hpDelta[.player] ?? 0, 0)
        XCTAssertEqual(playback.summary.finishingMoveID, "volttackle")
        XCTAssertEqual(playback.display[.opponent]?.fainted, true)
    }

    func testMidBattleAbilityRevealIsStagedWithinTheTurnThatRevealedIt() throws {
        let engine = try engine(); var now = 0.0
        let model = PracticeBattle(engine: engine, clock: { now })
        model.start(player: try candidate("pika", species: 25, ability: "static", moves: ["thunderbolt"], engine: engine),
                    opponent: try candidate("lantern", species: 171, ability: "volt-absorb", moves: ["splash"], engine: engine),
                    mode: .automatic, seed: [1, 2, 3, 4])
        XCTAssertFalse(model.events.contains(.abilityRevealed(.opponent, abilityID: "voltabsorb")))
        now = 1; model.tick()
        let events = model.events
        let reveal = try XCTUnwrap(events.firstIndex(of: .abilityRevealed(.opponent, abilityID: "voltabsorb")), "\(events)")
        let nextTurn = try XCTUnwrap(events.firstIndex(of: .turn(2)), "\(events)")
        XCTAssertLessThan(reveal, nextTurn, "the reveal belongs to the turn that caused it")

        let playback = PracticePlayback(clock: { now })
        playback.enqueue(events)
        playback.skipToEnd()
        let revealing = playback.history.filter { $0.callouts.contains(.abilityRevealed(.opponent, abilityID: "voltabsorb")) }
        XCTAssertEqual(revealing.map(\.turn), [1])
    }

    func testCrashDamageFromTheRealEngineStaysInTheCrashingMovesBeat() throws {
        let engine = try engine(); var now = 0.0
        let model = PracticeBattle(engine: engine, clock: { now })
        model.start(player: try candidate("lee", species: 106, ability: "limber", moves: ["high-jump-kick"], engine: engine),
                    opponent: try candidate("gengar", species: 94, ability: "cursed-body", moves: ["splash"], engine: engine),
                    mode: .automatic, seed: [1, 2, 3, 4])
        now = 1; model.tick()
        XCTAssertTrue(model.events.contains { if case .damage(.player, _, _, "highjumpkick") = $0 { return true } else { return false } },
                      "\(model.events)")
        let playback = PracticePlayback(clock: { now })
        playback.enqueue(model.events)
        playback.skipToEnd()
        XCTAssertEqual(playback.history.map(\.actor), [.opponent, .player])
        XCTAssertLessThan(playback.history.last?.hpDelta[.player] ?? 0, 0)
    }
}
