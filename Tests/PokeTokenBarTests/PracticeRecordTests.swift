import XCTest
@testable import PokeTokenBar

// MARK: Fixtures

private let recordEngineURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("engine/dist/battle-engine.js")

/// (instance id, species, moves, ability), all Lv.50.
private typealias RecordSpec = (String, Int, [String], String)
/// Pikachu's Thunderbolt knocks Magikarp's Splash out in one turn on every seed, so "p" against "m" always wins and
/// "m" against "p" always loses. Two Splash-only Blissey last the 200-turn cap (Natural Cure: no Pressure, so their
/// PP never runs out). Blissey with Tackle report HP far from 100.
private let recordFast: [RecordSpec] = [("p", 25, ["thunderbolt"], "static"), ("m", 129, ["splash"], "swift-swim")]
private let recordStall: [RecordSpec] = [("s1", 242, ["splash", "growl", "tail-whip", "defense-curl"], "natural-cure"),
                                         ("s2", 242, ["splash", "growl", "tail-whip", "defense-curl"], "natural-cure")]
private let recordTackle: [RecordSpec] = [("b", 242, ["tackle"], "natural-cure"), ("c", 242, ["tackle"], "natural-cure")]

private func recordState(_ specs: [RecordSpec]) -> CompanionState {
    var state = CompanionState()
    state.dex = specs.map { id, species, moves, ability in
        var profile = PokemonProfile.generate(seed: 42, instanceID: id)
        profile.level = 50; profile.gender = .male; profile.abilityName = ability
        profile.moves = moves.map { PokemonKnownMove(name: $0, learnedAtLevel: 1) }
        return DexEntry(baseID: species, finalID: species, chainOrder: [species], rarity: .common, caughtAt: nil,
                        nature: .hardy, profile: profile)
    }
    return state
}

private final class RecordClock { var now = 0.0 }

@MainActor
private func recordSession(_ specs: [RecordSpec], clock: RecordClock = RecordClock(),
                           store: PracticeRecordStore = PracticeRecordStore(fileURL: nil)) -> PracticeSession {
    let session = PracticeSession(engineURL: recordEngineURL, clock: { clock.now }, drivesAutomatically: false,
                                  recordStore: store)
    session.prepare(state: recordState(specs), activeName: nil)
    return session
}

/// Plays an automatic battle between two roster entries straight to its result.
@MainActor
private func recordFight(_ session: PracticeSession, _ player: String, _ opponent: String) {
    session.playerID = player; session.opponentID = opponent
    session.mode = .automatic
    session.start()
    session.skipToResult()
}

/// A new folder under the temporary directory; the caller removes it.
private func recordFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("practice-records-\(UUID().uuidString)",
                                                                                  isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

private func recordListing(_ folder: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
}

private func recordTotals(wins: Int = 0, losses: Int = 0, draws: Int = 0, streak: Int = 0, best: Int = 0,
                          day: String? = nil, stars: Set<PracticeDailyGoal> = []) -> PracticeRecords {
    var totals = PracticeRecords()
    totals.wins = wins; totals.losses = losses; totals.draws = draws
    totals.streak = streak; totals.bestStreak = best
    totals.dailyDay = day; totals.dailyStars = stars
    return totals
}

private func recordUpdate(_ outcome: PracticeOutcome, streak: Int, best: Int, ended: Int? = nil) -> PracticeRecordUpdate {
    PracticeRecordUpdate(outcome: outcome, streak: streak, bestStreak: best, endedStreak: ended,
                         daily: false, newStars: [], stars: [])
}

// MARK: Accounting

/// What one ended battle does to the records, without an engine: streaks, the best streak and today's stars.
@MainActor
final class PracticeRecordAccountingTests: XCTestCase {
    func testTheEngineWinnerIsTheOutcome() {
        XCTAssertEqual(PracticeOutcome(winner: "p1"), .win)
        XCTAssertEqual(PracticeOutcome(winner: "p2"), .loss)
        XCTAssertEqual(PracticeOutcome(winner: nil), .draw, "the 200-turn cap and a tie name no winner")
    }

    func testWinsBuildTheStreakAndALossOrADrawEndsIt() {
        var current = PracticeRecords()
        XCTAssertEqual(current.record(.win, dailyDay: nil, turns: 4, playerHPShare: 1), recordUpdate(.win, streak: 1, best: 1))
        XCTAssertEqual(current.record(.win, dailyDay: nil, turns: 4, playerHPShare: 1), recordUpdate(.win, streak: 2, best: 2))
        XCTAssertEqual(current.record(.loss, dailyDay: nil, turns: 4, playerHPShare: 1), recordUpdate(.loss, streak: 0, best: 2, ended: 2))
        XCTAssertEqual(current.record(.loss, dailyDay: nil, turns: 4, playerHPShare: 1), recordUpdate(.loss, streak: 0, best: 2),
                       "no streak left to end")
        XCTAssertEqual(current.record(.win, dailyDay: nil, turns: 4, playerHPShare: 1), recordUpdate(.win, streak: 1, best: 2),
                       "below the best, the best stays")
        XCTAssertEqual(current.record(.draw, dailyDay: nil, turns: 200, playerHPShare: 1), recordUpdate(.draw, streak: 0, best: 2, ended: 1))
        for streak in 1...3 {
            XCTAssertEqual(current.record(.win, dailyDay: nil, turns: 4, playerHPShare: 1),
                           recordUpdate(.win, streak: streak, best: max(2, streak)))
        }
        XCTAssertEqual(current, recordTotals(wins: 6, losses: 2, draws: 1, streak: 3, best: 3))
    }

    func testABattleAgainstAnotherOpponentLeavesTheStarsAlone() {
        var current = recordTotals(day: "2026-10-30", stars: [.win])
        let result = current.record(.win, dailyDay: nil, turns: 1, playerHPShare: 1)
        XCTAssertFalse(result.daily)
        XCTAssertEqual(result.newStars, []); XCTAssertEqual(result.stars, [])
        XCTAssertEqual(current.dailyDay, "2026-10-30"); XCTAssertEqual(current.dailyStars, [.win])
    }

    /// Each star is earned once a day; a battle reports the stars it added and the day's stars after it.
    func testTodaysStarsAreEarnedOnceAndAnotherDayStartsFromNone() {
        let slow = PracticeDailyGoal.quickTurns + 1, weak = PracticeDailyGoal.healthyShare.nextDown
        var current = PracticeRecords()
        var result = current.record(.win, dailyDay: "2026-10-30", turns: slow, playerHPShare: 1)
        XCTAssertTrue(result.daily)
        XCTAssertEqual(result.newStars, [.win, .healthyWin]); XCTAssertEqual(result.stars, [.win, .healthyWin])
        XCTAssertEqual(current.dailyDay, "2026-10-30"); XCTAssertEqual(current.dailyStars, [.win, .healthyWin])

        result = current.record(.loss, dailyDay: "2026-10-30", turns: 1, playerHPShare: 1)
        XCTAssertTrue(result.daily)
        XCTAssertEqual(result.newStars, []); XCTAssertEqual(result.stars, [.win, .healthyWin], "a loss keeps the day's stars")

        result = current.record(.win, dailyDay: "2026-10-30", turns: 1, playerHPShare: weak)
        XCTAssertEqual(result.newStars, [.quickWin], "only the star not yet earned is new")
        XCTAssertEqual(result.stars, Set(PracticeDailyGoal.allCases))

        result = current.record(.win, dailyDay: "2026-10-30", turns: 1, playerHPShare: 1)
        XCTAssertEqual(result.newStars, []); XCTAssertEqual(result.stars, Set(PracticeDailyGoal.allCases))

        // Another day: yesterday's stars go before today's are added.
        result = current.record(.win, dailyDay: "2026-10-31", turns: slow, playerHPShare: weak)
        XCTAssertEqual(result.newStars, [.win]); XCTAssertEqual(result.stars, [.win])
        XCTAssertEqual(current.dailyDay, "2026-10-31"); XCTAssertEqual(current.dailyStars, [.win])

        result = current.record(.loss, dailyDay: "2026-11-01", turns: 1, playerHPShare: 1)
        XCTAssertEqual(result.newStars, []); XCTAssertEqual(result.stars, [])
        XCTAssertEqual(current.dailyDay, "2026-11-01"); XCTAssertEqual(current.dailyStars, [])
        XCTAssertEqual(current.wins, 4); XCTAssertEqual(current.losses, 2)
    }

    func testRecordsSurviveAnEncodingRoundTrip() throws {
        let original = recordTotals(wins: 7, losses: 3, draws: 1, streak: 2, best: 5, day: "2026-10-30", stars: [.win, .healthyWin])
        let decoded = try JSONDecoder().decode(PracticeRecords.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(PracticeRecords().version, PracticeRecords.currentVersion)
    }
}

// MARK: Store

/// The records file on disk: missing, written, damaged, from a newer version, or impossible to move aside.
@MainActor
final class PracticeRecordStoreTests: XCTestCase {
    private let fixed = Date(timeIntervalSince1970: 1_793_400_000)   // 2026-10-30 22:40:00 UTC

    func testAMissingFileLoadsEmptyAndAPersistedOneLoadsBack() throws {
        let folder = try recordFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("practice-records.json")
        let store = PracticeRecordStore(fileURL: file)
        XCTAssertEqual(store.load(), PracticeRecords())
        XCTAssertEqual(try recordListing(folder), [], "loading creates nothing")
        let saved = recordTotals(wins: 3, losses: 1, streak: 2, best: 2, day: "2026-10-30", stars: [.win, .healthyWin])
        store.persist(saved)
        XCTAssertEqual(store.load(), saved)
        XCTAssertEqual(PracticeRecordStore(fileURL: file).load(), saved, "a later launch reads the same file")
        var later = saved; later.wins = 4
        store.persist(later)
        XCTAssertEqual(store.load(), later)
        XCTAssertEqual(try recordListing(folder), ["practice-records.json"], "the atomic write leaves no other file")
    }

    func testANilURLKeepsRecordsInMemoryOnly() {
        let store = PracticeRecordStore(fileURL: nil)
        store.persist(recordTotals(wins: 1, streak: 1, best: 1))
        XCTAssertEqual(store.load(), PracticeRecords())
    }

    func testADamagedFileIsKeptAsideAndTheRecordsStartOver() throws {
        let folder = try recordFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("practice-records.json")
        let damaged = Data("{ \"wins\": 3, ".utf8)
        try damaged.write(to: file)
        let store = PracticeRecordStore(fileURL: file, now: { [fixed] in fixed })
        XCTAssertEqual(store.load(), PracticeRecords())
        let kept = folder.appendingPathComponent("practice-records.json.corrupt-20261030T224000Z")
        XCTAssertEqual(try recordListing(folder), [kept.lastPathComponent])
        XCTAssertEqual(try Data(contentsOf: kept), damaged, "the unreadable bytes are kept, never deleted")
        store.persist(recordTotals(wins: 1, streak: 1, best: 1))
        XCTAssertEqual(store.load(), recordTotals(wins: 1, streak: 1, best: 1))
        XCTAssertEqual(try Data(contentsOf: kept), damaged)
        // Valid JSON of another shape is damaged too. The same second again gets its own name.
        let wrongShape = Data("[1, 2, 3]".utf8)
        try wrongShape.write(to: file)
        XCTAssertEqual(store.load(), PracticeRecords())
        let second = folder.appendingPathComponent("practice-records.json.corrupt-20261030T224000Z-2")
        XCTAssertEqual(try Data(contentsOf: second), wrongShape)
        XCTAssertEqual(try Data(contentsOf: kept), damaged, "the first copy is not overwritten")
        XCTAssertEqual(try recordListing(folder), [kept.lastPathComponent, second.lastPathComponent])
    }

    func testAFileFromANewerVersionIsKeptAsideNotOverwritten() throws {
        let folder = try recordFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("practice-records.json")
        var future = recordTotals(wins: 9, streak: 9, best: 9); future.version = PracticeRecords.currentVersion + 1
        let bytes = try JSONEncoder().encode(future)
        try bytes.write(to: file)
        let store = PracticeRecordStore(fileURL: file, now: { [fixed] in fixed })
        XCTAssertEqual(store.load(), PracticeRecords())
        let kept = folder.appendingPathComponent("practice-records.json.corrupt-20261030T224000Z")
        XCTAssertEqual(try Data(contentsOf: kept), bytes)
        store.persist(recordTotals(losses: 1))
        XCTAssertEqual(try Data(contentsOf: kept), bytes)
    }

    /// A damaged file in a folder that cannot be written can be neither moved aside nor replaced, so it stays.
    func testADamagedFileThatCannotBeMovedIsNeverOverwritten() throws {
        let folder = try recordFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("practice-records.json")
        let damaged = Data("not json".utf8)
        try damaged.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        let store = PracticeRecordStore(fileURL: file, now: { [fixed] in fixed })
        XCTAssertEqual(store.load(), PracticeRecords())
        store.persist(recordTotals(wins: 1, streak: 1, best: 1))
        XCTAssertEqual(try Data(contentsOf: file), damaged)
        XCTAssertEqual(try recordListing(folder), ["practice-records.json"])
    }
}

// MARK: Session

/// The session records each battle once, when it ends, and writes the records after every change.
@MainActor
final class PracticeRecordSessionTests: XCTestCase {
    func testEachWayABattleFinishesCountsItOnce() throws {
        let clock = RecordClock()
        let session = recordSession(recordFast, clock: clock)
        XCTAssertEqual(session.records, PracticeRecords()); XCTAssertNil(session.lastRecord)
        // Skipped to the result.
        recordFight(session, "p", "m")
        XCTAssertEqual(session.battle?.phase, .finished); XCTAssertEqual(session.battle?.result?.winner, "p1")
        XCTAssertEqual(session.records, recordTotals(wins: 1, streak: 1, best: 1))
        XCTAssertEqual(session.lastRecord, recordUpdate(.win, streak: 1, best: 1))
        // Nothing after the end counts it again.
        clock.now += 100; session.tick(); session.skipToResult(); session.choose(slot: 1)
        session.markResultSeen(); session.forfeit(); session.backToSelection()
        XCTAssertEqual(session.records, recordTotals(wins: 1, streak: 1, best: 1))
        // A manual choice that ends it.
        session.mode = .manual
        session.start()
        XCTAssertNil(session.lastRecord, "a battle in progress has no record yet")
        session.choose(slot: 1)
        XCTAssertEqual(session.battle?.phase, .finished)
        XCTAssertEqual(session.records, recordTotals(wins: 2, streak: 2, best: 2))
        XCTAssertEqual(session.lastRecord, recordUpdate(.win, streak: 2, best: 2))
        // A timeout that ends it: the automatic choice plays the turn.
        session.start()
        clock.now += TimeInterval(PracticeBattle.manualTurnSeconds); session.tick()
        XCTAssertTrue(session.battle?.messages.contains { $0.contains("시간 초과") } == true, "the turn timed out")
        XCTAssertEqual(session.battle?.phase, .finished)
        XCTAssertEqual(session.records, recordTotals(wins: 3, streak: 3, best: 3))
        XCTAssertEqual(session.lastRecord, recordUpdate(.win, streak: 3, best: 3))
    }

    func testALossOrADrawEndsTheStreakAndTheBestStays() throws {
        let session = recordSession(recordFast + recordStall)
        recordFight(session, "p", "m"); recordFight(session, "p", "m")
        recordFight(session, "m", "p")
        XCTAssertEqual(session.battle?.result?.winner, "p2")
        XCTAssertEqual(session.lastRecord, recordUpdate(.loss, streak: 0, best: 2, ended: 2))
        recordFight(session, "m", "p")
        XCTAssertEqual(session.lastRecord, recordUpdate(.loss, streak: 0, best: 2), "no streak left to end")
        recordFight(session, "p", "m")
        recordFight(session, "s1", "s2")
        XCTAssertEqual(session.battle?.phase, .finished)
        XCTAssertNil(session.battle?.result?.winner); XCTAssertEqual(session.battle?.view?.turn, 200)
        XCTAssertEqual(session.lastRecord, recordUpdate(.draw, streak: 0, best: 2, ended: 1))
        XCTAssertEqual(session.records, recordTotals(wins: 3, losses: 2, draws: 1, streak: 0, best: 2))
    }

    func testAForfeitIsALossAndARestartedBattleCountsNothing() throws {
        let session = recordSession(recordFast)
        session.playerID = "p"; session.opponentID = "m"; session.mode = .manual
        session.start()
        let restarted = session.battle
        session.start()
        XCTAssertEqual(restarted?.phase, .cancelled)
        XCTAssertEqual(session.records, PracticeRecords(), "a battle replaced while running is not counted")
        XCTAssertNil(session.lastRecord)
        session.choose(slot: 1)
        XCTAssertEqual(session.records, recordTotals(wins: 1, streak: 1, best: 1))
        // Giving up a running battle, even a held one, is a loss.
        session.start()
        session.setPaused(true, reason: .popoverClosed)
        session.forfeit()
        XCTAssertNil(session.battle)
        XCTAssertEqual(session.lastRecord, recordUpdate(.loss, streak: 0, best: 1, ended: 1))
        XCTAssertEqual(session.records, recordTotals(wins: 1, losses: 1, best: 1))
        session.forfeit()
        XCTAssertEqual(session.records, recordTotals(wins: 1, losses: 1, best: 1), "nothing running, nothing to give up")
    }

    func testEveryChangeIsWrittenAndALaterLaunchLoadsIt() throws {
        let folder = try recordFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = PracticeRecordStore(fileURL: folder.appendingPathComponent("practice-records.json"))
        let session = recordSession(recordFast, store: store)
        recordFight(session, "p", "m")
        XCTAssertEqual(store.load(), recordTotals(wins: 1, streak: 1, best: 1))
        recordFight(session, "m", "p")
        XCTAssertEqual(store.load(), recordTotals(wins: 1, losses: 1, best: 1))
        session.playerID = "p"; session.opponentID = "m"; session.mode = .manual
        session.start(); session.forfeit()
        XCTAssertEqual(store.load(), recordTotals(wins: 1, losses: 2, best: 1))
        let relaunched = PracticeSession(engineURL: recordEngineURL, clock: { 0 }, drivesAutomatically: false, recordStore: store)
        XCTAssertEqual(relaunched.records, recordTotals(wins: 1, losses: 2, best: 1))
        XCTAssertNil(relaunched.lastRecord)
    }

    /// The healthy-win star reads the player's HP from the battle view. The engine runs with `reportExactHP = false`,
    /// which only rounds the other side: the viewer's own side (`p1`) is exact, the opponent's is a percentage.
    func testThePlayersHPIsExactWhileTheOpponentsIsAPercentage() throws {
        let session = recordSession(recordTackle)
        session.mode = .manual
        session.start(); session.choose(slot: 1)
        let view = try XCTUnwrap(session.battle?.view)
        XCTAssertEqual(view.turn, 2)
        let maxHP = try XCTUnwrap(session.battle?.player?.snapshot?.publicInfo.stats["hp"])
        XCTAssertNotEqual(maxHP, 100)
        XCTAssertEqual(view.p1.maxhp, maxHP, "the player's own side reports its real maximum")
        XCTAssertLessThan(view.p1.hp, maxHP, "the opponent's Tackle hit")
        XCTAssertEqual(view.p2.maxhp, 100, "the opponent's side is a percentage")
        XCTAssertEqual(view.p1.hpShare, Double(view.p1.hp) / Double(maxHP))
    }
}

// MARK: The save stays untouched

/// The record store is the only practice code that writes, and it writes one file. A real battle next to a save must
/// leave the save's bytes and modification time alone and create nothing but `practice-records.json`.
@MainActor
final class PracticeRecordFileTests: XCTestCase {
    func testABattleWritesOnlyTheRecordsFileNextToTheSave() throws {
        let folder = try recordFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let save = folder.appendingPathComponent("companion-state.json")
        let saveBytes = Data("{\"stand-in\": \"any bytes; practice never parses the save file\"}".utf8)
        try saveBytes.write(to: save)
        let past = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: save.path)
        let recordsFile = folder.appendingPathComponent("practice-records.json")

        let session = recordSession(recordFast, store: PracticeRecordStore(fileURL: recordsFile))
        recordFight(session, "p", "m")
        XCTAssertEqual(session.battle?.phase, .finished)
        session.markResultSeen(); session.releaseIfIdle()

        XCTAssertEqual(try recordListing(folder), ["companion-state.json", "practice-records.json"])
        XCTAssertEqual(try Data(contentsOf: save), saveBytes, "the save's bytes are unchanged")
        let modified = try FileManager.default.attributesOfItem(atPath: save.path)[.modificationDate] as? Date
        XCTAssertEqual(modified, past, "the save was not rewritten, not even with the same bytes")
        XCTAssertEqual(PracticeRecordStore(fileURL: recordsFile).load(), recordTotals(wins: 1, streak: 1, best: 1))
    }
}
