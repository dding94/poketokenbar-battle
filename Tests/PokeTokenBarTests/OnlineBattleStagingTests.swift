import XCTest
@testable import PokeTokenBar

// MARK: - BattleSeatFrame

final class BattleSeatFrameTests: XCTestCase {
    private let host = BattleSeatFrame(local: .p1), guest = BattleSeatFrame(local: .p2)

    private func pokemon(_ species: String, hp: Int, maxhp: Int) -> BattleView.Pokemon {
        .init(speciesNum: 1, species: species, level: 50, types: ["Normal"], hp: hp, maxhp: maxhp, status: "", moves: [], ability: nil)
    }

    func testIdentsFollowTheLocalSeat() {
        XCTAssertEqual(host.side(ident: "p1a: Pikachu"), .player)
        XCTAssertEqual(host.side(ident: "p2a: Magikarp"), .opponent)
        XCTAssertEqual(guest.side(ident: "p1a: Pikachu"), .opponent)
        XCTAssertEqual(guest.side(ident: "p2a: Magikarp"), .player)
        XCTAssertEqual(guest.side(ident: "p2"), .player)
        XCTAssertNil(guest.side(ident: "sandstorm"))
        XCTAssertNil(guest.side(ident: ""))
    }

    func testSeatAndPokemonFollowTheLocalSeat() {
        XCTAssertEqual(host.seat(.player), .p1); XCTAssertEqual(host.seat(.opponent), .p2)
        XCTAssertEqual(guest.seat(.player), .p2); XCTAssertEqual(guest.seat(.opponent), .p1)
        let view = BattleView(turn: 1, ended: false, p1: pokemon("Pikachu", hp: 34, maxhp: 100), p2: pokemon("Magikarp", hp: 90, maxhp: 110))
        XCTAssertEqual(guest.pokemon(.player, in: view).species, "Magikarp")
        XCTAssertEqual(guest.pokemon(.opponent, in: view).species, "Pikachu")
        XCTAssertEqual(host.pokemon(.player, in: view).species, "Pikachu")
    }

    func testPracticeFrameIsTheFirstSeat() {
        XCTAssertEqual(BattleSeatFrame.practice.local, .p1)
    }

    /// The engine never flips identifiers for a p2 viewer; only the HP scale follows the viewer.
    func testParserGoldenLinesFromTheSecondSeat() {
        var parser = PracticeEventParser(frame: guest)
        let lines = [
            "|switch|p1a: Pikachu|Pikachu, L50, M|100/100", "|switch|p2a: Magikarp|Magikarp, L50, M|110/110", "|turn|1",
            "|move|p1a: Pikachu|Volt Tackle|p2a: Magikarp", "|-supereffective|p2a: Magikarp", "|-crit|p2a: Magikarp",
            "|-damage|p2a: Magikarp|0 fnt", "|faint|p2a: Magikarp", "|-damage|p1a: Pikachu|72/100|[from] Recoil",
            "|cant|p2a: Magikarp|par", "|-status|p1a: Pikachu|psn", "|win|p1",
        ]
        XCTAssertEqual(parser.parse(lines), [
            .switchIn(.opponent, hp: 100, maxHP: 100), .switchIn(.player, hp: 110, maxHP: 110), .turn(1),
            .move(.opponent, moveID: "volttackle"), .superEffective(.player), .critical(.player),
            .damage(.player, hp: 0, maxHP: 110, cause: nil), .faint(.player),
            .damage(.opponent, hp: 72, maxHP: 100, cause: "recoil"),
            .cant(.player, reason: "par"), .status(.opponent, code: "psn"), .end(winner: .opponent),
        ])
    }

    func testWinnerAndTieFollowTheLocalSeat() {
        var guestParser = PracticeEventParser(frame: guest), hostParser = PracticeEventParser(frame: host)
        XCTAssertEqual(guestParser.parse(["|win|p2"]), [.end(winner: .player)])
        XCTAssertEqual(guestParser.parse(["|win|p1"]), [.end(winner: .opponent)])
        XCTAssertEqual(hostParser.parse(["|win|p2"]), [.end(winner: .opponent)])
        XCTAssertEqual(guestParser.parse(["|tie"]), [.end(winner: nil)])
    }

    func testRevealsMergeThroughTheFrameBeforeTheClosingTurn() {
        let guestParser = PracticeEventParser(frame: guest)
        let during = BattleLogReveal(kind: "ability", side: "p1", id: "static", turn: 1)
        let own = BattleLogReveal(kind: "ability", side: "p2", id: "pressure", turn: 0)
        let move = BattleLogReveal(kind: "move", side: "p1", id: "tackle", turn: 1)
        XCTAssertEqual(guestParser.merging([during, move], into: [.move(.opponent, moveID: "tackle"), .turn(2)]),
                       [.move(.opponent, moveID: "tackle"), .abilityRevealed(.opponent, abilityID: "static"), .turn(2)])
        // Turn 0 is the start of the battle: it stays after the first turn marker, for the next beat's preamble.
        XCTAssertEqual(guestParser.merging([own], into: [.turn(1)]), [.turn(1), .abilityRevealed(.player, abilityID: "pressure")])
        // A terminal round ends without a turn marker.
        XCTAssertEqual(guestParser.merging([during], into: [.end(winner: .player)]),
                       [.end(winner: .player), .abilityRevealed(.opponent, abilityID: "static")])
        let practice = PracticeEventParser()
        XCTAssertEqual(practice.merging([during], into: [.turn(2)]), [.abilityRevealed(.player, abilityID: "static"), .turn(2)])
    }
}

// MARK: - OnlineBattleStagePlan

final class OnlineBattleStagePlanTests: XCTestCase {
    private typealias Plan = OnlineBattleStagePlan

    private func plan(_ skips: Bool, _ instant: Int, _ staged: Int) -> Plan { .init(skipsPlaying: skips, instantRounds: instant, stagedRounds: staged) }

    func testHiddenAppliesEverythingIncludingTheBeatOnScreen() {
        for mode in [OnlineBattleMode.manual, .auto] {
            for seconds in [nil, 2, 30] as [TimeInterval?] {
                XCTAssertEqual(Plan.decide(newRounds: 3, mode: mode, visible: false, secondsLeft: seconds, playing: true), plan(true, 3, 0))
                XCTAssertEqual(Plan.decide(newRounds: 1, mode: mode, visible: false, secondsLeft: seconds, playing: false), plan(false, 1, 0))
                XCTAssertEqual(Plan.decide(newRounds: 0, mode: mode, visible: false, secondsLeft: seconds, playing: true), plan(true, 0, 0))
            }
        }
    }

    func testManualUnderSixSecondsAppliesEverything() {
        XCTAssertEqual(Plan.decide(newRounds: 1, mode: .manual, visible: true, secondsLeft: 5.99, playing: false), plan(false, 1, 0))
        XCTAssertEqual(Plan.decide(newRounds: 2, mode: .manual, visible: true, secondsLeft: 1, playing: true), plan(true, 2, 0))
        XCTAssertEqual(Plan.decide(newRounds: 1, mode: .manual, visible: true, secondsLeft: -3, playing: false), plan(false, 1, 0))
    }

    func testManualOtherwiseStagesOnlyTheLastRound() {
        XCTAssertEqual(Plan.decide(newRounds: 1, mode: .manual, visible: true, secondsLeft: 6, playing: false), plan(false, 0, 1))
        XCTAssertEqual(Plan.decide(newRounds: 1, mode: .manual, visible: true, secondsLeft: 30, playing: true), plan(true, 0, 1))
        XCTAssertEqual(Plan.decide(newRounds: 4, mode: .manual, visible: true, secondsLeft: 30, playing: true), plan(true, 3, 1))
    }

    /// Right after a WebSocket round the deadline is nil until the next round opens: that counts as enough time.
    func testNoDeadlineCountsAsEnoughTime() {
        XCTAssertEqual(Plan.decide(newRounds: 1, mode: .manual, visible: true, secondsLeft: nil, playing: false), plan(false, 0, 1))
    }

    func testAutomaticLiveRoundJoinsTheQueue() {
        XCTAssertEqual(Plan.decide(newRounds: 1, mode: .auto, visible: true, secondsLeft: nil, playing: true), plan(false, 0, 1))
        XCTAssertEqual(Plan.decide(newRounds: 1, mode: .auto, visible: true, secondsLeft: nil, playing: false), plan(false, 0, 1))
        // Automatic rounds have no player deadline, so a stale small value must not skip them.
        XCTAssertEqual(Plan.decide(newRounds: 1, mode: .auto, visible: true, secondsLeft: 1, playing: true), plan(false, 0, 1))
    }

    func testAutomaticReturnStagesOnlyTheLastRound() {
        XCTAssertEqual(Plan.decide(newRounds: 2, mode: .auto, visible: true, secondsLeft: nil, playing: true), plan(true, 1, 1))
        XCTAssertEqual(Plan.decide(newRounds: 9, mode: .auto, visible: true, secondsLeft: nil, playing: false), plan(false, 8, 1))
    }

    /// A read that brings nothing new (the advance response, a refresh) must not disturb a beat being watched.
    func testNoNewRoundsKeepsTheBeatOnScreen() {
        for mode in [OnlineBattleMode.manual, .auto] {
            XCTAssertEqual(Plan.decide(newRounds: 0, mode: mode, visible: true, secondsLeft: 30, playing: true), plan(false, 0, 0))
            XCTAssertEqual(Plan.decide(newRounds: 0, mode: mode, visible: true, secondsLeft: nil, playing: false), plan(false, 0, 0))
        }
    }
}

// MARK: - OnlineBattleStaging with the real engine

@MainActor
final class OnlineBattleStagingEngineTests: XCTestCase {
    private final class Clock { var now = 100.0 }
    private struct Fixture: Decodable { let name: String; let battle: OnlineBattleView }

    private var engineURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("engine/dist/battle-engine.js")
    }
    private func fixtures() throws -> [Fixture] {
        try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "golden", withExtension: "json", subdirectory: "OnlineBattle"))))
    }
    private func fixture(_ name: String) throws -> OnlineBattleView { try XCTUnwrap(fixtures().first { $0.name == name }).battle }
    private func resolver(_ battle: OnlineBattleView, _ seat: OnlineBattleSide) throws -> OnlineBattleResolver {
        try OnlineBattleResolver(battle: battle, localTrainerID: seat == .p1 ? "trainer-one" : "trainer-two", engine: BattleEngine(url: engineURL))
    }
    private func foe(_ side: PracticeSide) -> PracticeSide { side == .player ? .opponent : .player }

    /// Plays a whole battle through one seat, a round at a time, with every beat committed.
    private func play(_ battle: OnlineBattleView, seat: OnlineBattleSide, clock: Clock = .init()) throws -> (OnlineBattleResolver, OnlineBattleStaging) {
        let owner = try resolver(battle, seat)
        let staging = OnlineBattleStaging(resolver: owner, clock: { clock.now })
        staging.ingest(owner, mode: battle.mode, visible: true, secondsLeft: nil)
        for count in 1...battle.journal.count {
            try owner.consume(journal: Array(battle.journal.prefix(count)))
            staging.ingest(owner, mode: .auto, visible: true, secondsLeft: nil)
            staging.skipToEnd()
        }
        return (owner, staging)
    }

    func testResolverRecordsOneLogBoundaryPerRoundPlusTheOpening() throws {
        let battle = try fixture("manual"), owner = try resolver(battle, .p2)
        defer { owner.close() }
        XCTAssertEqual(owner.roundLogEnds, [owner.logs.count])
        XCTAssertGreaterThan(owner.logs.count, 0)
        for count in 1...battle.journal.count {
            try owner.consume(journal: Array(battle.journal.prefix(count)))
            XCTAssertEqual(owner.roundLogEnds.count, owner.journal.count + 1)
            XCTAssertEqual(owner.roundReveals.count, owner.journal.count + 1)
            XCTAssertEqual(owner.roundLogEnds.last, owner.logs.count)
        }
        let duplicate = owner.roundLogEnds
        try owner.consume(journal: battle.journal)
        XCTAssertEqual(owner.roundLogEnds, duplicate)
    }

    /// Reveals are a display-only channel. A completed proof never drains them and neither path may change the hash.
    func testRevealCaptureLeavesLogHashAndReportUntouched() throws {
        for fixture in try fixtures() {
            let live = try resolver(fixture.battle, .p2)
            defer { live.close() }
            try live.consume(journal: fixture.battle.journal)
            XCTAssertEqual(try live.terminalReport(), fixture.battle.result, fixture.name)
            let proof = try OnlineBattleResolver.completedResolver(battle: fixture.battle, localTrainerID: "trainer-two", engine: BattleEngine(url: engineURL))
            defer { proof.close() }
            XCTAssertNoThrow(try proof.verifyCompleted(fixture.battle), fixture.name)
            XCTAssertTrue(proof.roundReveals.allSatisfy(\.isEmpty), fixture.name)
        }
        let manual = try fixture("manual"), live = try resolver(manual, .p1)
        defer { live.close() }
        XCTAssertTrue(live.roundReveals.joined().contains { $0.kind == "ability" }, "Pressure announces itself at the start")
    }

    /// The same seed through both seats: every beat is the same fact with the owners swapped.
    func testMirrorBothSeatsSeeTheSameBeatsWithOwnersSwapped() throws {
        var sawDamage = false
        for fixture in try fixtures() {
            let (ownerOne, one) = try play(fixture.battle, seat: .p1), (ownerTwo, two) = try play(fixture.battle, seat: .p2)
            defer { ownerOne.close(); ownerTwo.close() }
            let beatsOne = one.playback.history, beatsTwo = two.playback.history
            XCTAssertFalse(beatsOne.isEmpty, fixture.name)
            XCTAssertEqual(beatsOne.count, beatsTwo.count, fixture.name)
            XCTAssertEqual(Set(beatsOne.compactMap(\.actor)), [.player, .opponent], fixture.name)
            for (a, b) in zip(beatsOne, beatsTwo) {
                XCTAssertEqual(a.actor.map(foe), b.actor, "\(fixture.name) beat \(a.id)")
                XCTAssertEqual(a.moveID, b.moveID, "\(fixture.name) beat \(a.id)")
                XCTAssertEqual(a.turn, b.turn, "\(fixture.name) beat \(a.id)")
                for side in [PracticeSide.player, .opponent] {
                    // One seat reads exact HP and the other the shared percent, which round differently.
                    let mine = a.hpDelta[side] ?? 0, theirs = b.hpDelta[foe(side)] ?? 0
                    XCTAssertLessThanOrEqual(abs(mine - theirs), 1, "\(fixture.name) beat \(a.id)")
                    if abs(mine) > 1 { XCTAssertEqual(mine.signum(), theirs.signum(), "\(fixture.name) beat \(a.id)"); sawDamage = true }
                }
                let fainted = { (beat: PracticeBeat) in beat.callouts.compactMap { callout -> PracticeSide? in
                    if case .fainted(let side) = callout { return side } else { return nil } } }
                XCTAssertEqual(fainted(a).map(foe), fainted(b), "\(fixture.name) beat \(a.id)")
            }
            for (owner, staging) in [(ownerOne, one), (ownerTwo, two)] {
                let view = try XCTUnwrap(owner.view), own = staging.frame.pokemon(.player, in: view), shown = try XCTUnwrap(staging.playback.display[.player])
                XCTAssertEqual(shown.hp, own.hp, "\(fixture.name) \(owner.localSide)")
                XCTAssertEqual(shown.maxHP, own.maxhp, "\(fixture.name) \(owner.localSide)")
                let foeShown = try XCTUnwrap(staging.playback.display[.opponent]), other = staging.frame.pokemon(.opponent, in: view)
                XCTAssertEqual(foeShown.hp, other.hp, "\(fixture.name) \(owner.localSide)")
                XCTAssertEqual(foeShown.maxHP, 100, "\(fixture.name) \(owner.localSide)")
            }
        }
        XCTAssertTrue(sawDamage, "a mirror with no damage proves nothing about who owns it")
    }

    func testFrameComesFromTheResolverSeat() throws {
        let battle = try fixture("manual")
        for seat in [OnlineBattleSide.p1, .p2] {
            let owner = try resolver(battle, seat); defer { owner.close() }
            XCTAssertEqual(OnlineBattleStaging(resolver: owner, clock: { 0 }).frame.local, seat)
        }
    }

    func testTheOpeningSeedsWithoutABeatAndAbilitiesRideOnTheFirstBeat() throws {
        let battle = try fixture("manual"), owner = try resolver(battle, .p2), clock = Clock()
        defer { owner.close() }
        let staging = OnlineBattleStaging(resolver: owner, clock: { clock.now })
        staging.ingest(owner, mode: .manual, visible: true, secondsLeft: nil)
        XCTAssertFalse(staging.isPlaying)
        XCTAssertTrue(staging.playback.history.isEmpty)
        let own = try XCTUnwrap(owner.view).p2
        XCTAssertEqual(staging.playback.display[.player]?.hp, own.hp)
        XCTAssertEqual(staging.playback.display[.player]?.maxHP, own.maxhp)
        XCTAssertEqual(staging.playback.display[.opponent]?.maxHP, 100)
        try owner.consume(journal: Array(battle.journal.prefix(1)))
        staging.ingest(owner, mode: .manual, visible: true, secondsLeft: nil)
        XCTAssertTrue(try XCTUnwrap(staging.playback.beat).callouts.contains(.abilityRevealed(.player, abilityID: "pressure")),
                      "the second seat's Pressure is the viewer's own ability")
    }

    /// The first ingest of a restored battle finds several rounds and stages only the last.
    func testAReturningStagingPlaysOnlyTheLastRound() throws {
        let battle = try fixture("auto"), owner = try resolver(battle, .p1), clock = Clock()
        defer { owner.close() }
        try owner.consume(journal: Array(battle.journal.prefix(4)))
        let staging = OnlineBattleStaging(resolver: owner, clock: { clock.now })
        staging.ingest(owner, mode: .auto, visible: true, secondsLeft: nil)
        XCTAssertTrue(staging.isPlaying)
        let beat = try XCTUnwrap(staging.playback.beat)
        XCTAssertEqual(beat.turn, try XCTUnwrap(staging.playback.history.last).turn + 1)
        XCTAssertGreaterThan(staging.playback.history.count, 0)
    }

    func testHiddenRoundsLeaveNothingToPlayOnReturn() throws {
        let battle = try fixture("manual"), owner = try resolver(battle, .p2), clock = Clock()
        defer { owner.close() }
        let staging = OnlineBattleStaging(resolver: owner, clock: { clock.now })
        staging.ingest(owner, mode: .manual, visible: true, secondsLeft: nil)
        for count in 1...5 {
            try owner.consume(journal: Array(battle.journal.prefix(count)))
            staging.ingest(owner, mode: .manual, visible: false, secondsLeft: 30)
            XCTAssertFalse(staging.isPlaying)
            XCTAssertNil(staging.playback.beat)
        }
        let history = staging.playback.history.count
        XCTAssertGreaterThan(history, 0)
        staging.ingest(owner, mode: .manual, visible: true, secondsLeft: 30)
        XCTAssertFalse(staging.isPlaying)
        XCTAssertEqual(staging.playback.history.count, history)
        let own = try XCTUnwrap(owner.view).p2
        XCTAssertEqual(staging.playback.display[.player]?.hp, own.hp)
    }

    func testALocalTimeoutMarksTheLocalBeat() throws {
        let battle = try fixture("timeout")
        let index = try XCTUnwrap(battle.journal.firstIndex { $0.p1 == .timeout || $0.p2 == .timeout })
        let pair = battle.journal[index]
        for viewer in [OnlineBattleSide.p1, .p2] {
            let owner = try resolver(battle, viewer), clock = Clock()
            defer { owner.close() }
            let staging = OnlineBattleStaging(resolver: owner, clock: { clock.now })
            try owner.consume(journal: Array(battle.journal.prefix(index + 1)))
            staging.ingest(owner, mode: .auto, visible: true, secondsLeft: nil)
            staging.skipToEnd()
            let marked = staging.playback.history.filter { $0.callouts.contains(.timedOut) }
            XCTAssertEqual(!marked.isEmpty, (viewer == .p1 ? pair.p1 : pair.p2) == .timeout, "\(viewer)")
            XCTAssertTrue(marked.allSatisfy { $0.actor == .player }, "\(viewer)")
        }
    }

    /// A fresh resolver after a refetch replays the whole log. It must seed values, not stage the past again.
    func testResyncSeedsTheDisplayWithoutNewBeatsAndKeepsStagingLaterRounds() throws {
        let battle = try fixture("manual"), clock = Clock(), first = try resolver(battle, .p2)
        let staging = OnlineBattleStaging(resolver: first, clock: { clock.now })
        staging.ingest(first, mode: .manual, visible: true, secondsLeft: nil)
        try first.consume(journal: Array(battle.journal.prefix(2)))
        staging.ingest(first, mode: .manual, visible: true, secondsLeft: nil)
        XCTAssertTrue(staging.isPlaying)
        // Everything staged so far commits on the resync; nothing from the rebuilt log may join it.
        let beatsAlreadyStaged = staging.playback.history.count + 2
        first.close()
        staging.markResync()
        let rebuilt = try resolver(battle, .p2)
        defer { rebuilt.close() }
        try rebuilt.consume(journal: Array(battle.journal.prefix(4)))
        staging.ingest(rebuilt, mode: .manual, visible: true, secondsLeft: nil)
        XCTAssertFalse(staging.isPlaying, "a resync never plays")
        XCTAssertLessThanOrEqual(staging.playback.history.count, beatsAlreadyStaged)
        let view = try XCTUnwrap(rebuilt.view)
        XCTAssertEqual(staging.playback.display[.player]?.hp, view.p2.hp)
        XCTAssertEqual(staging.playback.display[.opponent]?.hp, view.p1.hp)
        try rebuilt.consume(journal: Array(battle.journal.prefix(5)))
        staging.ingest(rebuilt, mode: .auto, visible: true, secondsLeft: nil)
        XCTAssertTrue(staging.isPlaying, "the next real round stages as usual")
        staging.skipToEnd()
        XCTAssertEqual(staging.playback.display[.player]?.hp, try XCTUnwrap(rebuilt.view).p2.hp)
    }

    func testShownFollowsTheBeatThenTheAuthoritativeView() throws {
        let battle = try fixture("manual"), clock = Clock(), owner = try resolver(battle, .p1)
        defer { owner.close() }
        let staging = OnlineBattleStaging(resolver: owner, clock: { clock.now })
        staging.ingest(owner, mode: .manual, visible: true, secondsLeft: nil)
        XCTAssertEqual(staging.shown(.player)?.hp, owner.view?.p1.hp)
        XCTAssertEqual(staging.shown(.opponent)?.hp, owner.view?.p2.hp)
        try owner.consume(journal: battle.journal)
        staging.ingest(owner, mode: .auto, visible: false, secondsLeft: nil)
        let rest = try XCTUnwrap(staging.atRest(.opponent)), view = try XCTUnwrap(owner.view)
        XCTAssertEqual(rest.hp, view.p2.hp); XCTAssertEqual(rest.maxHP, view.p2.maxhp)
        XCTAssertTrue(rest.fainted, "the manual fixture ends with the second seat fainted")
        XCTAssertNil(rest.status, "a fainted side shows no status")
        XCTAssertEqual(staging.shown(.opponent), rest)
        XCTAssertEqual(staging.lastView?.turn, view.turn)
        XCTAssertEqual(staging.lastRequest?.kind, owner.request.kind)
    }

    func testAdvanceMovesTheOnScreenBeatOnTheClockAndShownReadsIt() throws {
        let battle = try fixture("manual"), clock = Clock(), owner = try resolver(battle, .p1)
        defer { owner.close() }
        let staging = OnlineBattleStaging(resolver: owner, clock: { clock.now })
        staging.ingest(owner, mode: .manual, visible: true, secondsLeft: nil)
        try owner.consume(journal: Array(battle.journal.prefix(1)))
        staging.ingest(owner, mode: .manual, visible: true, secondsLeft: 30)
        let first = try XCTUnwrap(staging.playback.beat)
        XCTAssertEqual(staging.shown(.opponent), first.after[.opponent])
        staging.advance()
        XCTAssertEqual(staging.playback.beat?.id, first.id, "the beat holds until its time is up")
        clock.now += PracticePlayback.actionBeat
        staging.advance()
        XCTAssertNotEqual(staging.playback.beat?.id, first.id)
        for _ in 0..<20 where staging.isPlaying { clock.now += PracticePlayback.actionBeat; staging.advance() }
        XCTAssertFalse(staging.isPlaying)
        XCTAssertEqual(staging.shown(.player)?.hp, owner.view?.p1.hp)
    }
}
