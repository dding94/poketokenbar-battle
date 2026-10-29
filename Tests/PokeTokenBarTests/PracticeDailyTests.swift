import XCTest
@testable import PokeTokenBar

/// Today's opponent: the local day, its seed, the candidate id that carries it, and the three goals.
@MainActor
final class PracticeDailyTests: XCTestCase {
    private func calendar(_ identifier: Calendar.Identifier, _ zone: String) throws -> Calendar {
        var calendar = Calendar(identifier: identifier)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
        return calendar
    }

    func testDayKeyIsTheDateInTheCalendarsTimeZone() throws {
        let instant = Date(timeIntervalSince1970: 1_793_400_000)   // 2026-10-30 22:40 UTC
        XCTAssertEqual(PracticeDaily.dayKey(instant, calendar: try calendar(.gregorian, "UTC")), "2026-10-30")
        XCTAssertEqual(PracticeDaily.dayKey(instant, calendar: try calendar(.gregorian, "Asia/Seoul")), "2026-10-31")
        XCTAssertEqual(PracticeDaily.dayKey(instant, calendar: try calendar(.gregorian, "America/Los_Angeles")), "2026-10-30")
        // Seoul's midnight is 15:00 UTC: the second before it is still the old day.
        let seoul = try calendar(.gregorian, "Asia/Seoul")
        XCTAssertEqual(PracticeDaily.dayKey(Date(timeIntervalSince1970: 1_793_372_399), calendar: seoul), "2026-10-30")
        XCTAssertEqual(PracticeDaily.dayKey(Date(timeIntervalSince1970: 1_793_372_400), calendar: seoul), "2026-10-31")
        XCTAssertEqual(PracticeDaily.dayKey(Date(timeIntervalSince1970: 1_798_729_200), calendar: seoul), "2027-01-01")
        XCTAssertEqual(PracticeDaily.dayKey(Date(timeIntervalSince1970: 1_798_729_200), calendar: try calendar(.gregorian, "UTC")),
                       "2026-12-31")
    }

    /// Another calendar system names the same day the same way, so two machines meet the same opponent.
    func testDayKeyIgnoresTheCalendarSystem() throws {
        let instant = Date(timeIntervalSince1970: 1_793_400_000)
        for identifier in [Calendar.Identifier.buddhist, .japanese, .islamicUmmAlQura, .hebrew] {
            XCTAssertEqual(PracticeDaily.dayKey(instant, calendar: try calendar(identifier, "Asia/Seoul")), "2026-10-31", "\(identifier)")
        }
    }

    /// FNV-1a 64 of the UTF-8 key. The published vectors and a pinned day prove the seed is the same on every launch
    /// and machine (`hashValue` changes per process).
    func testSeedIsFNV1aOfTheDayKey() {
        XCTAssertEqual(PracticeDaily.seed(dayKey: ""), 0xcbf2_9ce4_8422_2325)
        XCTAssertEqual(PracticeDaily.seed(dayKey: "a"), 0xaf63_dc4c_8601_ec8c)
        XCTAssertEqual(PracticeDaily.seed(dayKey: "foobar"), 0x8594_4171_f739_67e8)
        XCTAssertEqual(PracticeDaily.seed(dayKey: "2026-10-30"), 0x37c1_c73a_7a99_d101)
        XCTAssertEqual(PracticeDaily.seed(dayKey: "2026-10-31"), 0x37c1_c63a_7a99_cf4e)
    }

    func testTheCandidateIDCarriesItsDay() {
        XCTAssertEqual(PracticeDaily.dayKey(ofCandidateID: PracticeDaily.idPrefix + "2026-10-30"), "2026-10-30")
        XCTAssertNil(PracticeDaily.dayKey(ofCandidateID: "wild-11-0"))
        XCTAssertNil(PracticeDaily.dayKey(ofCandidateID: "my-daily-2026-10-30"))
        XCTAssertNil(PracticeDaily.dayKey(ofCandidateID: nil))
    }

    func testEveryGoalNeedsAWin() {
        for outcome in [PracticeOutcome.loss, .draw] {
            for goal in PracticeDailyGoal.allCases {
                XCTAssertFalse(goal.isMet(outcome: outcome, turns: 1, playerHPShare: 1), "\(goal) after a \(outcome)")
            }
        }
        XCTAssertTrue(PracticeDailyGoal.win.isMet(outcome: .win, turns: 200, playerHPShare: 0.01))
    }

    /// Both limits are inclusive: "within N turns" and "at least X of the HP".
    func testQuickAndHealthyWinsAreInclusiveLimits() {
        let turns = PracticeDailyGoal.quickTurns, share = PracticeDailyGoal.healthyShare
        XCTAssertTrue(PracticeDailyGoal.quickWin.isMet(outcome: .win, turns: turns, playerHPShare: 0.01))
        XCTAssertFalse(PracticeDailyGoal.quickWin.isMet(outcome: .win, turns: turns + 1, playerHPShare: 1))
        XCTAssertTrue(PracticeDailyGoal.healthyWin.isMet(outcome: .win, turns: 200, playerHPShare: share))
        XCTAssertFalse(PracticeDailyGoal.healthyWin.isMet(outcome: .win, turns: 1, playerHPShare: share.nextDown))
        // A one-turn win at full HP meets all three whatever the calibrated limits (the session tests rely on it).
        XCTAssertGreaterThanOrEqual(turns, 1)
        XCTAssertGreaterThan(share, 0); XCTAssertLessThanOrEqual(share, 1)
    }

    func testHPShareIsTheRemainingShareOfTheMaximum() {
        func pokemon(hp: Int, maxhp: Int) -> BattleView.Pokemon {
            BattleView.Pokemon(speciesNum: 242, species: "Blissey", level: 50, types: ["Normal"], hp: hp, maxhp: maxhp,
                               status: "", moves: [], ability: nil)
        }
        XCTAssertEqual(pokemon(hp: 120, maxhp: 320).hpShare, 0.375)
        XCTAssertEqual(pokemon(hp: 320, maxhp: 320).hpShare, 1)
        XCTAssertEqual(pokemon(hp: 0, maxhp: 320).hpShare, 0)
    }
}
