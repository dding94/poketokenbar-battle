import XCTest
@testable import PokeTokenBar

@MainActor
final class PracticeWordingTests: XCTestCase {
    /// `|-boost|p1a: Skarmory|spe|0` arrives when Agility is used at +6; it must not read as a drop.
    func testZeroStageBoostReadsAsUnchangedNotAsADrop() {
        XCTAssertEqual(L(.ko).practiceBoost(stat: "spe", stages: 0), "스피드 그대로")
        XCTAssertEqual(L(.en).practiceBoost(stat: "spe", stages: 0), "Spe unchanged")
        XCTAssertEqual(PracticeCalloutTone(.boost(.player, stat: "spe", stages: 0)), .muted)
    }

    /// Reopening the popover before the first move rebuilds the board; the splash must not play again.
    func testVersusSplashPlaysOncePerBattle() {
        XCTAssertTrue(PracticeBattleBoard.splashDue(phase: .running, turn: 1, introShown: false, played: false))
        XCTAssertFalse(PracticeBattleBoard.splashDue(phase: .running, turn: 1, introShown: true, played: false))
        XCTAssertFalse(PracticeBattleBoard.splashDue(phase: .running, turn: 1, introShown: false, played: true))
        XCTAssertFalse(PracticeBattleBoard.splashDue(phase: .running, turn: 2, introShown: false, played: false))
        XCTAssertFalse(PracticeBattleBoard.splashDue(phase: .finished, turn: 1, introShown: false, played: false))
    }

    /// The move-card badge text; the rendering test can only OCR it where Vision reads white-on-tint text.
    func testMultiplierBadgeWording() {
        let en = L(.en), ko = L(.ko)
        XCTAssertEqual(en.practiceMultiplier(4), "×4")
        XCTAssertEqual(en.practiceMultiplier(2), "×2")
        XCTAssertEqual(en.practiceMultiplier(0.5), "×½")
        XCTAssertEqual(en.practiceMultiplier(0.25), "×¼")
        XCTAssertEqual(en.practiceMultiplier(0), "×0")
        XCTAssertEqual(ko.practiceMultiplier(0), "무효")
        XCTAssertEqual(ko.practiceMultiplier(2), "×2")
    }

    // MARK: Records, today's opponent and temperaments (03B-5)

    /// The record line: totals (draws only once there is one) and the running streak with the best, or only the
    /// best between streaks; nothing before the first win.
    func testRecordWording() {
        let ko = L(.ko), en = L(.en)
        XCTAssertEqual(ko.practiceRecordTotals(wins: 12, losses: 5, draws: 1), "12승 5패 1무")
        XCTAssertEqual(en.practiceRecordTotals(wins: 12, losses: 5, draws: 1), "12W 5L 1D")
        XCTAssertEqual(ko.practiceRecordTotals(wins: 12, losses: 5, draws: 0), "12승 5패")
        XCTAssertEqual(en.practiceRecordTotals(wins: 12, losses: 5, draws: 0), "12W 5L")
        XCTAssertEqual(ko.practiceRecordStreak(streak: 3, best: 7), "3연승 (최고 7)")
        XCTAssertEqual(en.practiceRecordStreak(streak: 3, best: 7), "3-win streak (best 7)")
        XCTAssertEqual(ko.practiceRecordStreak(streak: 0, best: 7), "최고 7연승")
        XCTAssertEqual(en.practiceRecordStreak(streak: 0, best: 7), "best streak 7")
        XCTAssertNil(ko.practiceRecordStreak(streak: 0, best: 0))
        XCTAssertNil(en.practiceRecordStreak(streak: 0, best: 0))
        XCTAssertEqual(ko.practiceRecordEmpty, "아직 전적이 없어요 · 이기면 연승이 시작돼요")
        XCTAssertEqual(en.practiceRecordEmpty, "No record yet · a win starts your streak")
    }

    /// Goals are worded from `PracticeDailyGoal`'s numbers, which calibration will change: the expected text is
    /// built from the same constants, never from literals.
    func testDailyGoalsFollowTheCalibratedNumbers() {
        let ko = L(.ko), en = L(.en)
        let turns = PracticeDailyGoal.quickTurns
        let percent = Int((PracticeDailyGoal.healthyShare * 100).rounded())
        XCTAssertEqual(ko.practiceDailyGoal(.win), "이기기")
        XCTAssertEqual(en.practiceDailyGoal(.win), "Win")
        XCTAssertEqual(ko.practiceDailyGoal(.quickWin), "\(turns)턴 안에 이기기")
        XCTAssertEqual(en.practiceDailyGoal(.quickWin), "Win within \(turns) turn\(turns == 1 ? "" : "s")")
        XCTAssertEqual(ko.practiceDailyGoal(.healthyWin), "HP \(percent)% 이상 남기고 이기기")
        XCTAssertEqual(en.practiceDailyGoal(.healthyWin), "Win with \(percent)%+ HP left")
        XCTAssertEqual(ko.practiceDailyGoalShort(.win), "이기기")
        XCTAssertEqual(en.practiceDailyGoalShort(.win), "Win")
        XCTAssertEqual(ko.practiceDailyGoalShort(.quickWin), "\(turns)턴 안에")
        XCTAssertEqual(en.practiceDailyGoalShort(.quickWin), "≤\(turns) turn\(turns == 1 ? "" : "s")")
        XCTAssertEqual(ko.practiceDailyGoalShort(.healthyWin), "HP \(percent)% 이상")
        XCTAssertEqual(en.practiceDailyGoalShort(.healthyWin), "HP ≥\(percent)%")
        XCTAssertEqual(ko.practiceDailyStarsSpoken(earned: 1, total: 3), "오늘의 별 3개 중 1개")
        XCTAssertEqual(en.practiceDailyStarsSpoken(earned: 1, total: 3), "1 of 3 stars today")
    }

    /// Today's opponent reads like the wild section it sits above: the same structure for searching and for the
    /// unavailable notice.
    func testDailyCardWordingMirrorsTheWildSection() {
        let ko = L(.ko), en = L(.en)
        XCTAssertEqual(ko.practiceDailyTitle, "오늘의 상대")
        XCTAssertEqual(en.practiceDailyTitle, "Today's opponent")
        XCTAssertEqual(ko.practiceDailySearching, "오늘의 상대를 찾는 중…")
        XCTAssertEqual(en.practiceDailySearching, "Finding today's opponent…")
        XCTAssertEqual(ko.practiceDailyUnavailable, "오늘의 상대를 찾지 못했습니다. 인터넷 연결을 확인한 뒤 다시 찾아 주세요.")
        XCTAssertEqual(en.practiceDailyUnavailable, "Couldn't find today's opponent. Check your internet connection and try again.")
        XCTAssertEqual(ko.practiceTodayStars, "오늘의 별")
        XCTAssertEqual(en.practiceTodayStars, "Today's stars")
    }

    /// Short tag words, one per engine policy, plus a tooltip; every temperament has its own words.
    func testTemperamentWords() {
        let ko = L(.ko), en = L(.en)
        let expected: [(PracticeTemperament, String, String)] = [
            (.standard, "기본형", "Standard"), (.aggressive, "공격형", "Aggressive"),
            (.tactical, "신중형", "Cautious"), (.erratic, "변덕형", "Erratic"),
        ]
        for (temperament, korean, english) in expected {
            XCTAssertEqual(ko.practiceTemperament(temperament), korean)
            XCTAssertEqual(en.practiceTemperament(temperament), english)
            XCTAssertFalse(ko.practiceTemperamentHint(temperament).isEmpty, "\(temperament) has no tooltip")
            XCTAssertFalse(en.practiceTemperamentHint(temperament).isEmpty, "\(temperament) has no tooltip")
        }
        XCTAssertEqual(Set(PracticeTemperament.allCases.map { en.practiceTemperamentHint($0) }).count,
                       PracticeTemperament.allCases.count, "each temperament explains itself")
    }

    /// The result card's streak lines and the best mark.
    func testStreakWording() {
        let ko = L(.ko), en = L(.en)
        XCTAssertEqual(ko.practiceStreakStarted, "연승 시작!")
        XCTAssertEqual(en.practiceStreakStarted, "Streak started!")
        XCTAssertEqual(ko.practiceStreakContinued(4), "4연승!")
        XCTAssertEqual(en.practiceStreakContinued(4), "4-win streak!")
        XCTAssertEqual(ko.practiceStreakEnded(7), "연승 7에서 멈췄어요")
        XCTAssertEqual(en.practiceStreakEnded(7), "Streak ended at 7")
        XCTAssertEqual(ko.practiceBestStreak, "최고 기록")
        XCTAssertEqual(en.practiceBestStreak, "Personal best")
    }

    /// Practice results are kept now (in their own file), so nothing may still say they are not; the manual turn
    /// names the practice limit, and automatic battles say the foe follows its temperament.
    func testWordingAfterRecordsAndTemperaments() {
        let ko = L(.ko), en = L(.en)
        XCTAssertEqual(ko.practiceSaveUntouched, "세이브 영향 없음")
        XCTAssertEqual(en.practiceSaveUntouched, "Save untouched")
        XCTAssertEqual(ko.practiceCaptionResult, "세이브는 그대로예요 · 200턴이 지나면 무승부")
        XCTAssertEqual(en.practiceCaptionResult, "Your save stays untouched · draw at 200 turns")
        XCTAssertEqual(ko.practiceManualPerTurn(15), "직접 조작 · 턴당 15초")
        XCTAssertEqual(en.practiceManualPerTurn(15), "Manual · 15s per turn")
        XCTAssertEqual(ko.practiceAutoModeHint, "내 개체는 기본형, 상대는 성향대로 기술을 골라요")
        XCTAssertEqual(en.practiceAutoModeHint, "Yours plays Standard; the foe follows its temperament")
        // The temperament tag shows before battle, so the caption lists it with the other public facts.
        XCTAssertEqual(ko.practiceOpponentCaption, "상대 고르기 · 공개 정보는 종·레벨·타입·능력치·성향뿐")
        XCTAssertEqual(en.practiceOpponentCaption, "Pick a foe · public: species, level, types, stats, temperament")
    }

    /// Practice is Korean first with an English fallback: every other language reads the English words.
    func testProgressWordingFallsBackToEnglish() {
        let en = L(.en)
        for language in AppLanguage.allCases where language != .ko && language != .en {
            let l = L(language)
            XCTAssertEqual(l.practiceDailyTitle, en.practiceDailyTitle, "\(language)")
            XCTAssertEqual(l.practiceRecordTotals(wins: 1, losses: 2, draws: 3), en.practiceRecordTotals(wins: 1, losses: 2, draws: 3))
            XCTAssertEqual(l.practiceTemperament(.tactical), en.practiceTemperament(.tactical), "\(language)")
            XCTAssertEqual(l.practiceDailyGoal(.quickWin), en.practiceDailyGoal(.quickWin), "\(language)")
            XCTAssertEqual(l.practiceStreakEnded(3), en.practiceStreakEnded(3), "\(language)")
        }
    }

    /// The result card's streak change from the record update: a win continues or starts a streak, a loss or a
    /// draw that ended one says where, and one that ended nothing has no line.
    func testResultStreakChange() {
        func update(_ outcome: PracticeOutcome, streak: Int, best: Int, ended: Int? = nil, daily: Bool = false,
                    new: Set<PracticeDailyGoal> = [], stars: Set<PracticeDailyGoal> = []) -> PracticeRecordUpdate {
            PracticeRecordUpdate(outcome: outcome, streak: streak, bestStreak: best, endedStreak: ended, daily: daily,
                                 newStars: new, stars: stars)
        }
        XCTAssertEqual(PracticeResultRecord.streak(update(.win, streak: 1, best: 7)), .started)
        XCTAssertEqual(PracticeResultRecord.streak(update(.win, streak: 4, best: 7)), .continued(4))
        XCTAssertEqual(PracticeResultRecord.streak(update(.loss, streak: 0, best: 7, ended: 7)), .ended(7))
        XCTAssertEqual(PracticeResultRecord.streak(update(.draw, streak: 0, best: 7, ended: 2)), .ended(2))
        XCTAssertNil(PracticeResultRecord.streak(update(.loss, streak: 0, best: 7)))

        // The mark needs a streak of two at the best: a first win is not a record worth a badge.
        XCTAssertTrue(PracticeResultRecord.atBest(update(.win, streak: 4, best: 4)))
        XCTAssertFalse(PracticeResultRecord.atBest(update(.win, streak: 3, best: 7)))
        XCTAssertFalse(PracticeResultRecord.atBest(update(.win, streak: 1, best: 1)))
        XCTAssertFalse(PracticeResultRecord.atBest(update(.loss, streak: 0, best: 0, ended: nil)))

        XCTAssertTrue(PracticeResultRecord.isEmpty(update(.loss, streak: 0, best: 7)), "nothing changed, nothing to show")
        XCTAssertFalse(PracticeResultRecord.isEmpty(update(.loss, streak: 0, best: 7, ended: 3)))
        XCTAssertFalse(PracticeResultRecord.isEmpty(update(.loss, streak: 0, best: 7, daily: true)),
                       "today's opponent always shows today's stars")
    }

    /// Today's stars on the result: the ones this battle earned are new, earlier ones earned, the rest open.
    func testResultStarsHighlightWhatThisBattleEarned() {
        let update = PracticeRecordUpdate(outcome: .win, streak: 2, bestStreak: 5, endedStreak: nil, daily: true,
                                          newStars: [.quickWin], stars: [.win, .quickWin])
        XCTAssertEqual(PracticeResultRecord.star(.win, in: update), .earned)
        XCTAssertEqual(PracticeResultRecord.star(.quickWin, in: update), .new)
        XCTAssertEqual(PracticeResultRecord.star(.healthyWin, in: update), .open)
    }

    /// The selection's goal rows follow today's stars, in goal order.
    func testDailyGoalRowsFollowTodaysStars() {
        let rows = PracticeDailyGoalList.rows(stars: [.healthyWin])
        XCTAssertEqual(rows.map(\.goal), [.win, .quickWin, .healthyWin])
        XCTAssertEqual(rows.map(\.earned), [false, false, true])
    }

    /// While today's opponent is missing the card mirrors the search; once it is there it always shows, even
    /// while a reroll searches again or fails.
    func testDailyNoticeFollowsTheSearchUntilTheOpponentIsThere() {
        let daily = PracticeCandidate(id: PracticeDaily.idPrefix + "x", name: "x", snapshot: nil, blockedReason: nil)
        XCTAssertEqual(PracticeDailyNotice(candidate: nil, state: .idle), .idle)
        XCTAssertEqual(PracticeDailyNotice(candidate: nil, state: .searching), .searching)
        XCTAssertEqual(PracticeDailyNotice(candidate: nil, state: .unavailable), .unavailable)
        XCTAssertEqual(PracticeDailyNotice(candidate: nil, state: .ready), .unavailable, "a search that made no daily")
        XCTAssertNil(PracticeDailyNotice(candidate: daily, state: .searching))
        XCTAssertNil(PracticeDailyNotice(candidate: daily, state: .unavailable))
        XCTAssertNil(PracticeDailyNotice(candidate: daily, state: .ready))
    }

    /// A 15 s turn would sit in orange for two thirds of it at the old 10 s mark; the last 5 s are urgent.
    func testTurnClockTurnsUrgentInTheLastFiveSeconds() {
        XCTAssertFalse(PracticeScreen.clockIsUrgent(remaining: 6, paused: false))
        XCTAssertTrue(PracticeScreen.clockIsUrgent(remaining: 5, paused: false))
        XCTAssertTrue(PracticeScreen.clockIsUrgent(remaining: 0, paused: false))
        XCTAssertFalse(PracticeScreen.clockIsUrgent(remaining: 5, paused: true), "a held clock is not running out")
    }

    func testBoostArrowsFollowTheStageSign() {
        let l = L(.ko)
        XCTAssertEqual(l.practiceBoost(stat: "atk", stages: 1), "공격 ↑")
        XCTAssertEqual(l.practiceBoost(stat: "atk", stages: 2), "공격 ↑↑")
        XCTAssertEqual(l.practiceBoost(stat: "def", stages: -1), "방어 ↓")
        XCTAssertEqual(l.practiceBoost(stat: "def", stages: -2), "방어 ↓↓")
        XCTAssertEqual(l.practiceBoost(stat: "accuracy", stages: -1), "명중 ↓")
        XCTAssertEqual(PracticeCalloutTone(.boost(.opponent, stat: "atk", stages: 2)), .up)
        XCTAssertEqual(PracticeCalloutTone(.boost(.opponent, stat: "def", stages: -1)), .down)
    }
}
