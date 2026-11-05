import XCTest
import CryptoKit
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
        // A round where only one seat ran out of time tells the two viewers apart.
        let index = try XCTUnwrap(battle.journal.firstIndex { ($0.p1 == .timeout) != ($0.p2 == .timeout) })
        let pair = battle.journal[index]
        for viewer in [OnlineBattleSide.p1, .p2] {
            let owner = try resolver(battle, viewer), clock = Clock()
            defer { owner.close() }
            let staging = OnlineBattleStaging(resolver: owner, clock: { clock.now })
            try owner.consume(journal: Array(battle.journal.prefix(index)))
            staging.ingest(owner, mode: .manual, visible: false, secondsLeft: nil)
            let before = staging.playback.history.count
            try owner.consume(journal: Array(battle.journal.prefix(index + 1)))
            staging.ingest(owner, mode: .manual, visible: false, secondsLeft: nil)
            let marked = staging.playback.history.dropFirst(before).filter { $0.callouts.contains(.timedOut) }
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

// MARK: - The session keeps progress at network speed and only the display follows

private final class StageClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double = 31
    func now() -> Double { lock.withLock { value } }
    func advance(_ seconds: Double) { lock.withLock { value += seconds } }
}
private actor StageCredentials: OnlineBattleCredentialStoring {
    var key: String? = "test-key"
    func load(scope: OnlineBattleCredentialScope) -> String? { key }
    func save(_ accessKey: String, scope: OnlineBattleCredentialScope) { key = accessKey }
    func remove(scope: OnlineBattleCredentialScope) { key = nil }
}
private actor StageHTTP: OnlineBattleHTTPTransport {
    private var requests: [URLRequest] = []
    private var routes: [String: OnlineBattleHTTPResponse] = [:]
    private var queues: [String: [OnlineBattleHTTPResponse]] = [:]
    func route(_ path: String, _ data: Data, status: Int = 200) { routes[path] = .init(status: status, body: data) }
    func queue(_ path: String, _ values: [OnlineBattleHTTPResponse]) { queues[path] = values }
    func bodies(_ path: String) -> [Data] { requests.filter { $0.url?.path == path }.compactMap(\.httpBody) }
    func count(_ path: String) -> Int { requests.filter { $0.url?.path == path }.count }
    func send(_ request: URLRequest) async throws -> OnlineBattleHTTPResponse {
        requests.append(request)
        let path = request.url!.path
        if var queue = queues[path], !queue.isEmpty {
            let value = queue.removeFirst(); queues[path] = queue; return value
        }
        guard let response = routes[path] else { throw OnlineBattleFailure.transport }
        return response
    }
}
private actor StageConnection: OnlineBattleConnecting {
    private let trainer: String
    init(trainer: String) { self.trainer = trainer }
    func configure(origin: OnlineBattleOrigin?, accessKey: String?) {}
    func setPopoverOpen(_ open: Bool) {}
    func snapshot() -> OnlineBattleConnectionSnapshot { .init(state: .connected, generation: 1, connectionId: "connection", trainerId: trainer, groupId: "group") }
    func authenticationFailed(generation: UInt64) {}
    func stop() {}
}
@MainActor
private final class StageEffects: OnlineBattleEffects {
    var state = CompanionState()
    var applications = 0
    func healthShare(of instanceID: String) -> Double { state.battleHealth[instanceID] ?? 1 }
    func setHealthShare(_ share: Double, of instanceID: String) { state.battleHealth[instanceID] = share }
    func grantBattleXP(_ xp: Int) -> Bool { false }
    func setInBattle(_ instanceID: String?) {}
    func companionState() -> (state: CompanionState, activeName: String?)? { (state, nil) }
    func isHeldForBattle(instanceID: String) -> Bool { state.onlineBattleHolds.contains { $0.instanceID == instanceID } }
    func holdOnlineBattle(key: OnlineBattleReceiptKey, instanceID: String) throws {
        if !state.onlineBattleHolds.contains(where: { $0.key == key }) { state.onlineBattleHolds.append(.init(key: key, instanceID: instanceID)) }
    }
    func releaseOnlineBattle(key: OnlineBattleReceiptKey) { state.onlineBattleHolds.removeAll { $0.key == key } }
    func applyVerifiedOnlineBattleEffect(_ effect: VerifiedOnlineBattleEffect) throws -> OnlineBattleEffectReceipt {
        if let old = state.onlineBattleReceipts.first(where: { $0.key == effect.key }) { return old }
        applications += 1
        let result = OnlineBattleLedger.commit(effect, to: state, on: Date(timeIntervalSince1970: 0))
        state = result.state; return result.receipt
    }
}

@MainActor
final class OnlineBattleStagingSessionTests: XCTestCase {
    private struct Fixture: Decodable { let battle: OnlineBattleView }
    private struct Harness {
        let session: OnlineBattleSession, http: StageHTTP, effects: StageEffects, clock: StageClock
        @MainActor var model: OnlineBattlePresentation { session.presentation }
    }
    private var engineURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("engine/dist/battle-engine.js")
    }
    private func changed(_ room: OnlineBattleView, _ updates: [String: Any]) throws -> OnlineBattleView {
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(room)) as? [String: Any])
        for (key, update) in updates { value[key] = update }
        return try JSONDecoder().decode(OnlineBattleView.self, from: JSONSerialization.data(withJSONObject: value))
    }
    /// A golden battle in the server's id namespace, with the journal hash that id implies.
    private func battle(_ index: Int = 0) throws -> OnlineBattleView {
        let fixture = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "golden", withExtension: "json", subdirectory: "OnlineBattle"))))[index].battle
        let id = "bt_" + fixture.battleId.replacingOccurrences(of: "-", with: "_")
        let bytes = try OnlineBattleResolver.journalBytes(battleID: id, readyToken: fixture.config!.readyToken, journal: fixture.journal)
        var result = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture.result)) as? [String: Any])
        result["journalHash"] = SHA256Hex.of(bytes)
        return try changed(fixture, ["battleId": id, "result": result])
    }
    private func journal(_ pairs: ArraySlice<OnlineBattlePair>) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(Array(pairs))) }
    private func running(_ final: OnlineBattleView, rounds: Int, _ extra: [String: Any] = [:]) throws -> OnlineBattleView {
        var updates: [String: Any] = ["state": "RUNNING", "result": NSNull(), "roundSeq": rounds, "journal": try journal(final.journal.prefix(rounds))]
        for (key, value) in extra { updates[key] = value }
        return try changed(final, updates)
    }
    private func roster(_ battle: OnlineBattleView) -> [PracticeCandidate] {
        [battle.p1.snapshot!, battle.p2.snapshot!].map { value in
            .init(id: value.instanceId, name: value.publicInfo.species, snapshot: .init(schemaVersion: 1, instanceID: value.instanceId, engineHash: BattleEngineManifest.sha256, rulesVersion: BattleSnapshot.rules, policyVersion: BattleSnapshot.policy, set: value.set, publicInfo: value.publicInfo), blockedReason: nil)
        }
    }
    private func setup(_ battles: [OnlineBattleView], trainer: String = "trainer-one", roomForRoster: OnlineBattleView) async throws -> Harness {
        let http = StageHTTP(), effects = StageEffects(), clock = StageClock()
        let group = OnlineBattleGroup(groupId: "group", name: "Test", hostTrainerId: "trainer-two")
        let account = OnlineBattleAccount(trainer: .init(trainerId: trainer, displayEmail: "synthetic@example.invalid", role: .member, status: .active), group: group)
        await http.route("/v1/me", try JSONEncoder().encode(account))
        await http.route("/v1/group", try JSONEncoder().encode(OnlineBattleGroupMembers(group: group, members: [])))
        await http.route("/v1/battles", try JSONEncoder().encode(OnlineBattlePage(battles: battles, before: nil)))
        let candidates = roster(roomForRoster), url = engineURL
        let session = OnlineBattleSession(settings: .init(profileID: UUID().uuidString, serverURL: "https://battle.example.invalid"), credentials: StageCredentials(), transport: http, effects: effects, engineFactory: { try BattleEngine(url: url) }, connectionFactory: { _ in StageConnection(trainer: trainer) }, rosterProvider: { candidates }, clock: .init(now: { clock.now() }), automaticTicks: false)
        return Harness(session: session, http: http, effects: effects, clock: clock)
    }
    private func showScreen(_ h: Harness) async {
        await h.session.perform(.setPopoverVisible(true))
        await h.session.perform(.setOnlineScreenVisible(true))
    }
    private func list(_ h: Harness, _ rooms: [OnlineBattleView]) async throws {
        await h.http.route("/v1/battles", try JSONEncoder().encode(OnlineBattlePage(battles: rooms, before: nil)))
    }
    private func drainBeats(_ h: Harness) {
        for _ in 0..<2000 where h.model.stage?.isPlaying == true { h.clock.advance(1); h.session.tickStage() }
    }

    // MARK: Progress never waits (D6)

    func testAdvanceAndMoveChoicesDoNotWaitForTheBeat() async throws {
        let final = try battle(), first = try running(final, rounds: 1)
        let opened = try changed(first, ["roundSeq": 2, "deadline": 61000]), submitted = try changed(opened, ["ownChoice": "move 1"])
        let advance = "/v1/battles/\(final.battleId)/advance", choices = "/v1/battles/\(final.battleId)/choices"
        let h = try await setup([first], roomForRoster: final)
        await h.http.route(advance, try JSONEncoder().encode(opened))
        await h.http.route(choices, try JSONEncoder().encode(submitted))
        await showScreen(h)
        await h.session.bootstrap()
        let stage = try XCTUnwrap(h.model.stage)
        XCTAssertTrue(stage.isPlaying, "the visible round stages")
        let beat = stage.playback.beat?.id
        let advances = await h.http.count(advance); XCTAssertEqual(advances, 1, "the first seat advances as soon as it has consumed the round")
        XCTAssertEqual(h.model.deadline, Date(timeIntervalSince1970: 61), "the server clock is what the screen shows")
        XCTAssertEqual(h.model.phase, .arena)
        XCTAssertTrue(h.model.canChooseMove(1), "moves stay open during a beat")
        await h.session.perform(.chooseMove(1))
        let posted = await h.http.count(choices); XCTAssertEqual(posted, 1)
        XCTAssertTrue(h.model.choiceSubmitted)
        XCTAssertEqual(stage.playback.beat?.id, beat, "a response with no new round leaves the beat alone")
    }

    func testSecondSeatFallbackAdvanceRunsOnItsOwnClockDuringABeat() async throws {
        let final = try battle(), first = try running(final, rounds: 1)
        let advance = "/v1/battles/\(final.battleId)/advance"
        let h = try await setup([first], trainer: "trainer-two", roomForRoster: final)
        await h.http.route(advance, try JSONEncoder().encode(try changed(first, ["roundSeq": 2, "deadline": 63000])))
        await showScreen(h)
        await h.session.bootstrap()
        let stage = try XCTUnwrap(h.model.stage)
        XCTAssertEqual(stage.frame.local, .p2)
        XCTAssertTrue(stage.isPlaying)
        h.clock.advance(2); await h.session.tick()
        let advances = await h.http.count(advance); XCTAssertEqual(advances, 1)
        XCTAssertTrue(stage.isPlaying, "only the stage driver moves beats")
        drainBeats(h)
        let view = try XCTUnwrap(h.model.arena)
        XCTAssertEqual(stage.shown(.player)?.hp, view.p2.hp, "the second seat's own card is the second seat")
        XCTAssertEqual(stage.shown(.player)?.maxHP, view.p2.maxhp)
        XCTAssertEqual(stage.shown(.opponent)?.hp, view.p1.hp)
    }

    func testDeadlineDecidesWhetherAManualRoundStages() async throws {
        let final = try battle()
        for (deadline, stages) in [(61000, true), (37000, true), (36999, false), (34000, false)] {
            let opened = try running(final, rounds: 1, ["roundSeq": 2, "deadline": deadline])
            let h = try await setup([opened], roomForRoster: final)
            await showScreen(h)
            await h.session.bootstrap()
            XCTAssertEqual(h.model.stage?.isPlaying, stages, "deadline \(deadline)")
        }
    }

    func testAutomaticRoundsQueueWhileProgressFinishesAtNetworkSpeed() async throws {
        let final = try battle(1), first = try running(final, rounds: 1)
        let steps = try (2...final.journal.count).map { count in
            OnlineBattleHTTPResponse(status: 200, body: try JSONEncoder().encode(try running(final, rounds: count)))
        }
        let h = try await setup([first], roomForRoster: final)
        await h.http.queue("/v1/battles/\(final.battleId)/advance", steps)
        await h.http.route("/v1/battles/\(final.battleId)/report", try JSONEncoder().encode(final))
        await showScreen(h)
        await h.session.bootstrap()
        XCTAssertEqual(h.effects.applications, 1, "settlement does not wait for the display")
        let reports = await h.http.bodies("/v1/battles/\(final.battleId)/report")
        XCTAssertEqual(reports.count, 1)
        if let body = reports.first { XCTAssertEqual(try JSONDecoder().decode(OnlineBattleReport.self, from: body), final.result) }
        let stage = try XCTUnwrap(h.model.stage)
        XCTAssertTrue(stage.isPlaying)
        XCTAssertEqual(h.model.phase, .arena)
        XCTAssertLessThan(stage.playback.history.count, 2, "the rounds are queued, not played")
        drainBeats(h)
        XCTAssertEqual(h.model.phase, .result)
        XCTAssertEqual(Set(stage.playback.history.map(\.turn)).count, final.journal.count, "every live round played in turn")
        XCTAssertEqual(stage.playback.history.map(\.turn), stage.playback.history.map(\.turn).sorted())
    }

    func testSkipStagePlaysTheQueueAtOnceAndReleasesTheHold() async throws {
        let final = try battle(1), first = try running(final, rounds: 1)
        let steps = try (2...final.journal.count).map { count in
            OnlineBattleHTTPResponse(status: 200, body: try JSONEncoder().encode(try running(final, rounds: count)))
        }
        let h = try await setup([first], roomForRoster: final)
        await h.http.queue("/v1/battles/\(final.battleId)/advance", steps)
        await h.http.route("/v1/battles/\(final.battleId)/report", try JSONEncoder().encode(final))
        await showScreen(h)
        await h.session.bootstrap()
        XCTAssertEqual(h.model.phase, .arena)
        await h.session.perform(.skipStage)
        XCTAssertEqual(h.model.stage?.isPlaying, false)
        XCTAssertEqual(h.model.phase, .result)
    }

    func testSpeedSettingAppliesToTheBeatAndInstantNeverStages() async throws {
        let final = try battle(), first = try running(final, rounds: 1, ["roundSeq": 2, "deadline": 61000])
        let h = try await setup([first], roomForRoster: final)
        await showScreen(h)
        await h.session.perform(.setStageSpeed(.fast))
        XCTAssertEqual(h.model.stageSpeed, .fast)
        await h.session.bootstrap()
        let stage = try XCTUnwrap(h.model.stage), beat = stage.playback.beat?.id
        XCTAssertEqual(stage.playback.timeScale, 0.5)
        h.clock.advance(PracticePlayback.actionBeat / 2); h.session.tickStage()
        XCTAssertNotEqual(stage.playback.beat?.id, beat, "the fast setting halves a beat")
        await h.session.perform(.setStageSpeed(.instant))
        XCTAssertFalse(stage.isPlaying, "instant asks for no staging, like a hidden screen")
        await h.session.perform(.setStageSpeed(.normal))
        XCTAssertEqual(stage.playback.timeScale, 1)
    }

    // MARK: The phase holds only the display

    func testTerminalRoundKeepsTheArenaUntilItsBeatsEndThoughProgressIsDone() async throws {
        let final = try battle(), terminal = try running(final, rounds: final.journal.count)
        let reported = try changed(final, ["state": "REPORTED", "result": NSNull()])
        let h = try await setup([terminal], roomForRoster: final)
        await h.http.route("/v1/battles/\(final.battleId)/report", try JSONEncoder().encode(reported))
        await showScreen(h)
        await h.session.bootstrap()
        let reports = await h.http.bodies("/v1/battles/\(final.battleId)/report")
        XCTAssertEqual(reports.count, 1, "the report does not wait for the beats")
        if let body = reports.first { XCTAssertEqual(try JSONDecoder().decode(OnlineBattleReport.self, from: body), final.result) }
        let stage = try XCTUnwrap(h.model.stage)
        XCTAssertTrue(stage.isPlaying)
        XCTAssertEqual(h.model.room?.state, .reported)
        XCTAssertEqual(h.model.phase, .arena, "reported holds the arena while the last round plays")
        try await list(h, [final])
        await h.session.refresh()
        XCTAssertEqual(h.effects.applications, 1, "settlement does not wait for the beats")
        XCTAssertEqual(h.model.room?.state, .completed)
        XCTAssertTrue(stage.isPlaying)
        XCTAssertEqual(h.model.phase, .arena, "completed holds the arena while the last round plays")
        XCTAssertEqual(h.model.arena?.ended, true, "the closed resolver's last view still draws")
        XCTAssertEqual(h.model.request?.kind, "none")
        drainBeats(h)
        XCTAssertEqual(h.model.phase, .result)
        XCTAssertEqual(h.effects.applications, 1)
        XCTAssertNotNil(h.model.stage, "completion keeps the stage until the result is dismissed")
        await h.session.perform(.dismissResult)
        XCTAssertNil(h.model.stage)
        XCTAssertEqual(h.model.phase, .lobby)
        await h.session.perform(.openBattle(final.battleId))
        XCTAssertEqual(h.model.phase, .result)
        XCTAssertNil(h.model.stage, "dismissing released the finished battle's stage")
    }

    /// A completion ahead of the resolver is not consumed, so verification keeps its own path. The beats on
    /// screen still finish before the result.
    func testCompletionAheadOfTheResolverFinishesTheBeatsWithoutStagingTheRest() async throws {
        let final = try battle(), first = try running(final, rounds: 1, ["roundSeq": 2, "deadline": 61000])
        let h = try await setup([first], roomForRoster: final)
        await showScreen(h)
        await h.session.bootstrap()
        let stage = try XCTUnwrap(h.model.stage)
        XCTAssertTrue(stage.isPlaying)
        try await list(h, [final])
        await h.session.refresh()
        XCTAssertEqual(h.effects.applications, 1)
        XCTAssertEqual(h.model.phase, .arena)
        XCTAssertEqual(h.model.arena?.turn, stage.lastView?.turn)
        XCTAssertEqual(h.model.arena?.ended, false, "the last consumed view, not the unconsumed end")
        drainBeats(h)
        XCTAssertEqual(h.model.phase, .result)
        XCTAssertEqual(h.effects.applications, 1)
        XCTAssertLessThan(Set(stage.playback.history.map(\.turn)).count, final.journal.count)
    }

    func testReportedGoesToVerifyingOnceTheBeatsEnd() async throws {
        let final = try battle(), terminal = try running(final, rounds: final.journal.count)
        let h = try await setup([terminal], roomForRoster: final)
        await h.http.route("/v1/battles/\(final.battleId)/report", try JSONEncoder().encode(try changed(final, ["state": "REPORTED", "result": NSNull()])))
        await showScreen(h)
        await h.session.bootstrap()
        XCTAssertEqual(h.model.phase, .arena)
        drainBeats(h)
        XCTAssertEqual(h.model.phase, .verifying)
    }

    func testVoidNeverHoldsAndDropsTheStage() async throws {
        let final = try battle(), first = try running(final, rounds: 1, ["roundSeq": 2, "deadline": 61000])
        let h = try await setup([first], roomForRoster: final)
        await showScreen(h)
        await h.session.bootstrap()
        XCTAssertEqual(h.model.stage?.isPlaying, true)
        try await list(h, [try running(final, rounds: 1, ["roundSeq": 2, "state": "VOID"])])
        await h.session.refresh()
        XCTAssertEqual(h.model.phase, .result)
        XCTAssertNil(h.model.stage)
    }

    // MARK: The gate

    func testClosingThePopoverPlaysEverythingAndReleasesTheHold() async throws {
        let final = try battle(), terminal = try running(final, rounds: final.journal.count)
        let h = try await setup([terminal], roomForRoster: final)
        await h.http.route("/v1/battles/\(final.battleId)/report", try JSONEncoder().encode(try changed(final, ["state": "REPORTED", "result": NSNull()])))
        await showScreen(h)
        await h.session.bootstrap()
        let stage = try XCTUnwrap(h.model.stage)
        XCTAssertTrue(stage.isPlaying)
        XCTAssertEqual(h.session.stagingHeldBattleIDs(), [final.battleId], "the attention mark waits for the last beat")
        await h.session.perform(.setPopoverVisible(false))
        XCTAssertFalse(stage.isPlaying)
        XCTAssertEqual(h.session.stagingHeldBattleIDs(), [], "a closed popover holds nothing back, so a notice can go out")
        XCTAssertEqual(h.model.phase, .verifying)
        let played = stage.playback.history.count
        await showScreen(h)
        XCTAssertFalse(stage.isPlaying)
        XCTAssertNil(stage.playback.beat)
        XCTAssertEqual(stage.playback.history.count, played, "nothing replays on reopening")
    }

    func testRoundsWhileHiddenNeverPlayOnReopening() async throws {
        let final = try battle(), first = try running(final, rounds: 1)
        let advance = "/v1/battles/\(final.battleId)/advance"
        let h = try await setup([first], roomForRoster: final)
        await h.http.route(advance, try JSONEncoder().encode(first))
        await showScreen(h)
        await h.session.bootstrap()
        let stage = try XCTUnwrap(h.model.stage)
        XCTAssertTrue(stage.isPlaying)
        await h.session.perform(.setPopoverVisible(false))
        XCTAssertFalse(stage.isPlaying)
        for count in 2...6 {
            let next = try running(final, rounds: count)
            await h.http.route(advance, try JSONEncoder().encode(next))
            try await list(h, [next])
            await h.session.refresh()
            XCTAssertFalse(stage.isPlaying, "round \(count) arrived hidden")
        }
        let advances = await h.http.count(advance); XCTAssertEqual(advances, 6, "hidden battles keep advancing")
        let played = stage.playback.history.count
        await showScreen(h)
        h.session.tickStage()
        XCTAssertFalse(stage.isPlaying)
        XCTAssertNil(stage.playback.beat)
        XCTAssertEqual(stage.playback.history.count, played)
        let view = try XCTUnwrap(h.model.arena)
        XCTAssertEqual(stage.playback.display[.player]?.hp, view.p1.hp)
    }

    func testLeavingTheOnlineScreenSkipsAndAReopenedPopoverWaitsForTheScreen() async throws {
        let final = try battle(), first = try running(final, rounds: 1)
        let advance = "/v1/battles/\(final.battleId)/advance"
        let h = try await setup([first], roomForRoster: final)
        await h.http.route(advance, try JSONEncoder().encode(first))
        await showScreen(h)
        await h.session.bootstrap()
        let stage = try XCTUnwrap(h.model.stage)
        XCTAssertTrue(stage.isPlaying)
        await h.session.perform(.setOnlineScreenVisible(false))
        XCTAssertFalse(stage.isPlaying)
        await h.session.perform(.setOnlineScreenVisible(true))
        // The popover's views go away without a guaranteed onDisappear, so closing counts as leaving the screen.
        await h.session.perform(.setPopoverVisible(false))
        await h.session.perform(.setPopoverVisible(true))
        let next = try running(final, rounds: 2)
        await h.http.route(advance, try JSONEncoder().encode(next))
        try await list(h, [next])
        await h.session.refresh()
        XCTAssertFalse(stage.isPlaying, "the home screen is open, not the battle")
    }

    func testOverlaysAndNavigationSkipTheStage() async throws {
        let final = try battle(), first = try running(final, rounds: 1, ["roundSeq": 2, "deadline": 61000])
        let h = try await setup([first], roomForRoster: final)
        await showScreen(h)
        await h.session.bootstrap()
        let stage = try XCTUnwrap(h.model.stage)
        XCTAssertTrue(stage.isPlaying)
        await h.session.perform(.showHistory)
        h.session.tickStage()
        XCTAssertFalse(stage.isPlaying, "an overlay hides the arena")
        await h.session.perform(.closeReplay)
        await h.session.perform(.backToLobby)
        XCTAssertNil(h.model.stage, "only the shown room's stage is exposed")
        await h.session.perform(.openBattle(final.battleId))
        XCTAssertTrue(h.model.stage === stage, "a running battle keeps its stage across navigation")
        XCTAssertFalse(stage.isPlaying)
    }

    func testAnotherRoomOnScreenSkipsThisOne() async throws {
        let final = try battle(), first = try running(final, rounds: 1, ["roundSeq": 2, "deadline": 61000])
        let h = try await setup([first], roomForRoster: final)
        await showScreen(h)
        await h.session.bootstrap()
        let stage = try XCTUnwrap(h.model.stage)
        XCTAssertTrue(stage.isPlaying)
        let other = try changed(battle(), ["battleId": "bt_other", "state": "PENDING", "config": NSNull(), "result": NSNull(), "roundSeq": 0, "journal": [], "createdAt": 5])
        try await list(h, [first, other])
        await h.session.refresh()
        await h.session.perform(.openBattle("bt_other"))
        XCTAssertFalse(stage.isPlaying)
        XCTAssertNil(h.model.stage)
    }

    // MARK: Reconstruction and release

    func testRefetchedResolverSeedsWithoutReplayingTheBattle() async throws {
        let final = try battle(), first = try running(final, rounds: 2, ["roundSeq": 3, "deadline": 61000])
        let h = try await setup([first], roomForRoster: final)
        await showScreen(h)
        await h.session.bootstrap()
        let stage = try XCTUnwrap(h.model.stage)
        XCTAssertTrue(stage.isPlaying)
        // A rewritten journal prefix poisons the resolver; the room's authoritative read rebuilds it.
        let rewritten = final.journal.prefix(3).map { OnlineBattlePair(roundSeq: $0.roundSeq, p1: $0.p1, p2: $0.p2, releasedAt: $0.releasedAt + 1) }
        let rejected = try changed(first, ["roundSeq": 4, "journal": try JSONSerialization.jsonObject(with: JSONEncoder().encode(rewritten))])
        try await list(h, [rejected])
        await h.http.route("/v1/battles/\(final.battleId)", try JSONEncoder().encode(rejected))
        await h.session.refresh()
        XCTAssertTrue(h.model.stage === stage, "the stage survives a new resolver")
        XCTAssertFalse(stage.isPlaying, "the rebuilt log is not staged again")
        XCTAssertEqual(stage.playback.history.map(\.id), Array(Set(stage.playback.history.map(\.id))).sorted())
        let view = try XCTUnwrap(h.model.arena)
        XCTAssertEqual(stage.playback.display[.player]?.hp, view.p1.hp)
        XCTAssertEqual(stage.playback.display[.opponent]?.hp, view.p2.hp)
    }

    func testGenerationResetsDropTheStage() async throws {
        let final = try battle(), first = try running(final, rounds: 1, ["roundSeq": 2, "deadline": 61000])
        let group = OnlineBattleGroup(groupId: "group", name: "Test", hostTrainerId: "trainer-two")
        let trainer = OnlineBattleTrainer(trainerId: "trainer-one", displayEmail: "synthetic@example.invalid", role: .member, status: .active)
        for reset in 0..<3 {
            let h = try await setup([first], roomForRoster: final)
            await showScreen(h)
            await h.session.bootstrap()
            let old = try XCTUnwrap(h.model.stage)
            XCTAssertTrue(old.isPlaying)
            switch reset {
            case 0: await h.session.setEnabled(false)
            case 1: await h.session.configureServer("https://new-battle.example.invalid")
            default:
                let grant = try JSONSerialization.data(withJSONObject: ["trainer": JSONSerialization.jsonObject(with: JSONEncoder().encode(trainer)), "group": JSONSerialization.jsonObject(with: JSONEncoder().encode(group)), "accessKey": "new-synthetic-key", "recoveryCode": "new-synthetic-code"])
                await h.http.route("/v1/join", grant)
                try await list(h, [])
                await h.session.perform(.join(inviteCode: "SYNTHETIC", email: "synthetic@example.invalid"))
            }
            // The mock server still lists the room after a server change, so a new stage may follow; never the old one.
            XCTAssertFalse(h.model.stage === old, "reset \(reset)")
            if reset != 1 { XCTAssertNil(h.model.stage, "reset \(reset)") }
        }
    }
}

private enum SHA256Hex {
    static func of(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
}
