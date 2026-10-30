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

    // MARK: Battle items, HP and stakes (PR 03C)

    private static let battleItems: [ItemKind] = [.potion, .hyperPotion, .revive, .ivReroll]

    /// Official names for the three healing items; the IV reroll is the app's own, so it has its own short name.
    /// Every language has a name of its own for each, never the raw case name.
    func testBattleItemNames() {
        let ko = L(.ko), en = L(.en)
        XCTAssertEqual(Self.battleItems.map(ko.itemName), ["상처약", "고급상처약", "기력의조각", "개체값 재추첨권"])
        XCTAssertEqual(Self.battleItems.map(en.itemName), ["Potion", "Hyper Potion", "Revive", "IV Reroll"])
        for language in AppLanguage.allCases {
            let names = Self.battleItems.map(L(language).itemName)
            XCTAssertEqual(Set(names).count, names.count, "\(language): \(names)")
            for (kind, name) in zip(Self.battleItems, names) {
                XCTAssertFalse(name.isEmpty || name == kind.rawValue, "\(language) \(kind): \(name)")
            }
        }
    }

    /// Descriptions come from `BattleItem`: the Potion's and the Revive's share in every language, and the reroll
    /// warns that the IVs may drop.
    func testBattleItemDescriptionsFollowTheConstants() {
        let potion = "\(Int((BattleItem.potionHeal * 100).rounded()))%"
        let revive = "\(Int((BattleItem.reviveShare * 100).rounded()))%"
        XCTAssertEqual(L(.ko).itemDescription(.potion), "포켓몬의 체력을 \(potion) 회복해요.")
        XCTAssertEqual(L(.en).itemDescription(.potion), "Restores \(potion) of a Pokémon's HP.")
        XCTAssertEqual(L(.ko).itemDescription(.hyperPotion), "포켓몬의 체력을 모두 회복해요.")
        XCTAssertEqual(L(.en).itemDescription(.hyperPotion), "Fully restores a Pokémon's HP.")
        XCTAssertEqual(L(.ko).itemDescription(.revive), "기절한 포켓몬을 체력 \(revive)로 되살려요.")
        XCTAssertEqual(L(.en).itemDescription(.revive), "Revives a fainted Pokémon with \(revive) of its HP.")
        XCTAssertEqual(L(.ko).itemDescription(.ivReroll), "현재 포켓몬의 개체값 6개를 모두 다시 뽑아요. 더 낮아질 수도 있어요.")
        XCTAssertEqual(L(.en).itemDescription(.ivReroll), "Re-rolls all six IVs of your Pokémon. They may get lower.")
        for language in AppLanguage.allCases {
            let l = L(language)
            XCTAssertTrue(l.itemDescription(.potion).contains(potion), "\(language)")
            XCTAssertTrue(l.itemDescription(.revive).contains(revive), "\(language)")
            XCTAssertFalse(l.itemDescription(.hyperPotion).isEmpty, "\(language)")
            XCTAssertFalse(l.itemDescription(.ivReroll).isEmpty, "\(language)")
        }
    }

    /// The bag's effect hint next to Use, and why an item cannot be used now.
    func testBattleItemHintsAndReasons() {
        let ko = L(.ko), en = L(.en)
        let potion = "\(Int((BattleItem.potionHeal * 100).rounded()))%"
        let revive = "\(Int((BattleItem.reviveShare * 100).rounded()))%"
        XCTAssertEqual(Self.battleItems.map(ko.battleItemEffectHint), ["체력 +\(potion)", "체력 완전 회복", "기절 → 체력 \(revive)", "개체값 6개 다시 뽑기"])
        XCTAssertEqual(Self.battleItems.map(en.battleItemEffectHint), ["HP +\(potion)", "Full HP", "Fainted → \(revive) HP", "Re-roll all 6 IVs"])
        XCTAssertEqual(ko.battleItemFullHealth, "체력이 가득해요")
        XCTAssertEqual(en.battleItemFullHealth, "HP is full")
        XCTAssertEqual(ko.battleItemNeedsRevive, "기절했어요 · 기력의조각이 필요해요")
        XCTAssertEqual(en.battleItemNeedsRevive, "Fainted · needs a Revive")
        XCTAssertEqual(ko.battleItemOnlyFainted, "기절했을 때만 쓸 수 있어요")
        XCTAssertEqual(en.battleItemOnlyFainted, "Only for a fainted Pokémon")
        XCTAssertEqual(ko.battleFainted, "기절")
        XCTAssertEqual(en.battleFainted, "Fainted")
        XCTAssertEqual(ko.ivRerollMayDrop, "더 낮아질 수 있어요")
        XCTAssertEqual(en.ivRerollMayDrop, "They may get lower")
        for language in AppLanguage.allCases {
            let l = L(language)
            for text in Self.battleItems.map(l.battleItemEffectHint) + [l.battleItemFullHealth, l.battleItemNeedsRevive,
                    l.battleItemOnlyFainted, l.battleHP, l.battleFainted, l.ivRerollCurrent, l.ivRerollMayDrop,
                    l.ivRerollAction, l.ivRerollNew, l.menuFaintedLine("Pikachu")] {
                XCTAssertFalse(text.isEmpty, "\(language): an empty battle item string")
            }
        }
    }

    /// Mirrors `CompanionStore.useHealingItem`: Potions need a hurt Pokémon that is standing, a Revive a fainted
    /// one, the reroll any hatched one. Nothing works without the item or a Pokémon.
    func testBattleItemUseFollowsTheHealthShare() {
        for kind in [ItemKind.potion, .hyperPotion] {
            XCTAssertEqual(BattleItemUse(kind, count: 0, healthShare: 0.5), .notOwned)
            XCTAssertEqual(BattleItemUse(kind, count: 1, healthShare: nil), .noPokemon)
            XCTAssertEqual(BattleItemUse(kind, count: 1, healthShare: 1), .fullHealth)
            XCTAssertEqual(BattleItemUse(kind, count: 1, healthShare: 0), .fainted)
            XCTAssertEqual(BattleItemUse(kind, count: 1, healthShare: 0.5), .usable)
            XCTAssertEqual(BattleItemUse(kind, count: 2, healthShare: 0.999), .usable, "a scratch still heals")
        }
        XCTAssertEqual(BattleItemUse(.revive, count: 0, healthShare: 0), .notOwned)
        XCTAssertEqual(BattleItemUse(.revive, count: 1, healthShare: nil), .noPokemon)
        XCTAssertEqual(BattleItemUse(.revive, count: 1, healthShare: 0), .usable)
        XCTAssertEqual(BattleItemUse(.revive, count: 1, healthShare: 0.5), .notFainted)
        XCTAssertEqual(BattleItemUse(.revive, count: 1, healthShare: 1), .notFainted)
        XCTAssertEqual(BattleItemUse(.ivReroll, count: 0, healthShare: 1), .notOwned)
        XCTAssertEqual(BattleItemUse(.ivReroll, count: 1, healthShare: nil), .noPokemon)
        XCTAssertEqual(BattleItemUse(.ivReroll, count: 1, healthShare: 0), .usable, "a fainted Pokémon keeps its IVs")
    }

    /// 0% only when fainted and 100% only when full, so the bar's number never contradicts what an item can do.
    func testHealthPercentReadsFaintedAndFullOnlyAtTheEnds() {
        XCTAssertEqual(BattleHealth.percent(0), 0)
        XCTAssertEqual(BattleHealth.percent(1), 100)
        XCTAssertEqual(BattleHealth.percent(0.63), 63)
        XCTAssertEqual(BattleHealth.percent(0.996), 99, "a scratch is not full")
        XCTAssertEqual(BattleHealth.percent(0.004), 1, "a sliver is not fainted")
        XCTAssertEqual(BattleHealth.percent(-0.2), 0)
        XCTAssertEqual(BattleHealth.percent(1.3), 100)
    }

    /// The reroll's result marks each IV as up, down or unchanged.
    func testIVChangesFollowEachStat() {
        let old = PokemonIVs(hp: 31, attack: 12, defense: 0, specialAttack: 25, specialDefense: 7, speed: 18)
        let new = PokemonIVs(hp: 20, attack: 12, defense: 9, specialAttack: 25, specialDefense: 30, speed: 2)
        XCTAssertEqual(IVGrid.change("hp", from: old, to: new), .down)
        XCTAssertEqual(IVGrid.change("attack", from: old, to: new), .same)
        XCTAssertEqual(IVGrid.change("defense", from: old, to: new), .up)
        XCTAssertEqual(IVGrid.change("special-defense", from: old, to: new), .up)
        XCTAssertEqual(IVGrid.change("speed", from: old, to: new), .down)
        XCTAssertNil(IVGrid.change("speed", from: nil, to: new), "no arrows before a reroll")
    }

    /// The Heal control lists only the items I own that would work on the entry, cheapest first.
    func testHealOptionsListOnlyItemsThatWork() {
        let counts: [ItemKind: Int] = [.potion: 2, .hyperPotion: 1, .revive: 3, .ivReroll: 1]
        XCTAssertEqual(PracticeHealControl.options(share: 0.5, counts: counts).map(\.kind), [.potion, .hyperPotion])
        XCTAssertEqual(PracticeHealControl.options(share: 0.5, counts: counts).map(\.count), [2, 1])
        XCTAssertEqual(PracticeHealControl.options(share: 0, counts: counts).map(\.kind), [.revive])
        XCTAssertTrue(PracticeHealControl.options(share: 1, counts: counts).isEmpty, "nothing to heal at full HP")
        XCTAssertEqual(PracticeHealControl.options(share: 0.5, counts: [.potion: 0, .hyperPotion: 1]).map(\.kind), [.hyperPotion])
        XCTAssertTrue(PracticeHealControl.options(share: 0, counts: [.potion: 4]).isEmpty, "a Potion cannot wake a fainted one")
    }

    /// Start needs both sides and no fainted block. The block itself is Core's (`PracticeSession.startBlock`); the
    /// selection reads it through `PracticeSelectionProgress` (wired in the rendering tests).
    func testStartNeedsAPairAndNoFaintedBlock() {
        let owned = PracticeCandidate(id: "owned", name: "o", snapshot: nil, blockedReason: nil)
        let wild = PracticeCandidate(id: "wild", name: "w", snapshot: nil, blockedReason: nil,
                                     origin: .wild(rarity: .common, shiny: false))
        XCTAssertTrue(PracticeSelectionView.canStart(player: owned, opponent: wild, faintedBlock: false))
        XCTAssertFalse(PracticeSelectionView.canStart(player: owned, opponent: wild, faintedBlock: true))
        XCTAssertFalse(PracticeSelectionView.canStart(player: nil, opponent: wild, faintedBlock: false))
        XCTAssertFalse(PracticeSelectionView.canStart(player: owned, opponent: nil, faintedBlock: false))
    }

    /// Sparring leaves the save alone, a battle with stakes keeps the HP it costs (the battle's first log line says
    /// the same): the selection asks about the selected opponent, the result about the battle that ended.
    func testStakesAwareSaveNote() {
        let owned = PracticeCandidate(id: "owned", name: "o", snapshot: nil, blockedReason: nil)
        let wild = PracticeCandidate(id: "wild", name: "w", snapshot: nil, blockedReason: nil,
                                     origin: .wild(rarity: .common, shiny: false))
        let stakes = PracticeStakesUpdate(healthShare: 0.5, xp: 0, xpWinsLeft: 3)
        XCTAssertTrue(PracticeScreen.showsStakes(onResult: false, opponent: wild, lastStakes: nil))
        XCTAssertFalse(PracticeScreen.showsStakes(onResult: false, opponent: owned, lastStakes: stakes), "sparring is picked")
        XCTAssertFalse(PracticeScreen.showsStakes(onResult: false, opponent: nil, lastStakes: nil))
        XCTAssertTrue(PracticeScreen.showsStakes(onResult: true, opponent: owned, lastStakes: stakes),
                      "the result follows the battle that ended, not the selection")
        XCTAssertFalse(PracticeScreen.showsStakes(onResult: true, opponent: wild, lastStakes: nil))
        XCTAssertEqual(L(.ko).practiceStakesCapsule, "깎인 체력은 남아요")
        XCTAssertEqual(L(.en).practiceStakesCapsule, "Lost HP stays")
        XCTAssertEqual(L(.ko).practiceCaptionResultStakes, "깎인 체력은 배틀이 끝나도 남아요 · 200턴이 지나면 무승부")
        XCTAssertEqual(L(.en).practiceCaptionResultStakes, "Lost HP stays after the battle · draw at 200 turns")
    }

    /// After a fainting loss the line above the off buttons says, after "Fainted", what heals it and where: a Revive,
    /// from New opponent (the selection's Heal control), naming that button and the item as they read.
    func testResultFaintedBlockWording() {
        let ko = L(.ko), en = L(.en)
        XCTAssertEqual(ko.practiceResultFaintedBlock(ko.practiceOtherOpponent), "다른 상대에서 기력의조각을 쓰면 다시 붙을 수 있어요")
        XCTAssertEqual(en.practiceResultFaintedBlock(en.practiceOtherOpponent), "Use a Revive from New opponent to battle again")
    }

    /// Item icons load PokéAPI sprites only with artwork on, so screens drawn with artwork off (tests) stay offline;
    /// the reroll has no sprite either way.
    func testItemIconsLoadSpritesOnlyWithArtwork() {
        for kind in [ItemKind.potion, .hyperPotion, .revive, .rareCandy] {
            XCTAssertTrue(ItemIconView.loadsSprite(kind, artwork: true), "\(kind)")
            XCTAssertFalse(ItemIconView.loadsSprite(kind, artwork: false), "\(kind): artwork off must stay offline")
        }
        XCTAssertFalse(ItemIconView.loadsSprite(.ivReroll, artwork: true), "the reroll is an emoji")
    }

    /// Healing from the selection screen uses the item on my entry's individual, never on the current Pokémon.
    func testHealUsesTheItemOnTheEntry() throws {
        let bag = RecordingItemBag([.potion: 1])
        let entry = PracticeScreenRenderingTests.syntheticCandidate(id: "entry-7", name: "Pikachu", species: 25, level: 30,
                                                                    types: ["Electric"])
        XCTAssertTrue(PracticeSelectionView.heal(.potion, entry: entry, bag: bag))
        XCTAssertEqual(bag.uses.map(\.kind), [.potion])
        XCTAssertEqual(bag.uses.map(\.instanceID), [try XCTUnwrap(entry.snapshot?.instanceID)])
        XCTAssertFalse(PracticeSelectionView.heal(.potion, entry: nil, bag: bag), "no entry, nothing used")
        XCTAssertFalse(PracticeSelectionView.heal(.potion, entry: entry, bag: nil), "no bag, nothing used")
        XCTAssertEqual(bag.uses.count, 1)
    }

    /// The result's XP line: what the current Pokémon got and how many paying wins are left, or why it got none.
    func testResultXPLine() {
        func update(_ outcome: PracticeOutcome) -> PracticeRecordUpdate {
            PracticeRecordUpdate(outcome: outcome, streak: outcome == .win ? 1 : 0, bestStreak: 3, endedStreak: nil,
                                 daily: false, newStars: [], stars: [])
        }
        let xp = PracticeStakes.winXP
        XCTAssertEqual(PracticeResultRecord.xpLine(update(.win), PracticeStakesUpdate(healthShare: 0.7, xp: xp, xpWinsLeft: 9)),
                       .gained(xp: xp, winsLeft: 9))
        XCTAssertEqual(PracticeResultRecord.xpLine(update(.win), PracticeStakesUpdate(healthShare: 0.7, xp: xp, xpWinsLeft: 0)),
                       .gained(xp: xp, winsLeft: 0), "the last paying win still paid")
        XCTAssertEqual(PracticeResultRecord.xpLine(update(.win), PracticeStakesUpdate(healthShare: 0.7, xp: 0, xpWinsLeft: 0)),
                       .capReached)
        XCTAssertEqual(PracticeResultRecord.xpLine(update(.win), PracticeStakesUpdate(healthShare: 0.7, xp: 0, xpWinsLeft: 4)),
                       .noPokemon)
        XCTAssertEqual(PracticeResultRecord.xpLine(update(.loss), PracticeStakesUpdate(healthShare: 0, xp: 0, xpWinsLeft: 4)),
                       .loss)
        XCTAssertEqual(PracticeResultRecord.xpLine(update(.draw), PracticeStakesUpdate(healthShare: 0.3, xp: 0, xpWinsLeft: 4)),
                       .draw)
        XCTAssertTrue(PracticeResultRecord.isEmpty(update(.loss), stakes: nil), "sparring a loss shows no card")
        XCTAssertFalse(PracticeResultRecord.isEmpty(update(.loss), stakes: PracticeStakesUpdate(healthShare: 0, xp: 0, xpWinsLeft: 4)),
                       "a battle with stakes always reports HP and XP")
    }

    /// The selection's heal and block lines and the result's XP and HP lines.
    func testStakesWording() {
        let ko = L(.ko), en = L(.en)
        let cap = PracticeStakes.dailyXPWins
        XCTAssertEqual(ko.practiceHeal, "회복")
        XCTAssertEqual(en.practiceHeal, "Heal")
        XCTAssertEqual(ko.practiceHealNone, "쓸 수 있는 회복약이 없어요 · 상점에서 살 수 있어요")
        XCTAssertEqual(en.practiceHealNone, "No healing item that works · buy one in the shop")
        XCTAssertEqual(ko.practiceFaintedBlock, "기절 · 회복해야 야생·오늘의 상대와 싸울 수 있어요")
        XCTAssertEqual(en.practiceFaintedBlock, "Fainted · heal it to fight wild or today's opponents")
        XCTAssertEqual(ko.practiceXPGained(xp: 5_000_000, winsLeft: 9), "+5M XP · 오늘 9번 남음")
        XCTAssertEqual(en.practiceXPGained(xp: 5_000_000, winsLeft: 9), "+5M XP · 9 more today")
        XCTAssertEqual(ko.practiceXPGained(xp: 5_000_000, winsLeft: 0), "+5M XP · 오늘은 마지막이에요")
        XCTAssertEqual(en.practiceXPGained(xp: 5_000_000, winsLeft: 0), "+5M XP · last one today")
        XCTAssertEqual(ko.practiceXPCapReached, "경험치 없음 · 오늘 \(cap)승을 모두 채웠어요")
        XCTAssertEqual(en.practiceXPCapReached, "No XP · today's limit of \(cap) wins is reached")
        XCTAssertEqual(ko.practiceXPNoPokemon, "경험치 없음 · 키우는 포켓몬이 없어요")
        XCTAssertEqual(en.practiceXPNoPokemon, "No XP · no current Pokémon to grow")
        XCTAssertEqual(ko.practiceXPLoss, "진 판은 경험치가 없어요")
        XCTAssertEqual(en.practiceXPLoss, "No XP for a loss")
        XCTAssertEqual(ko.practiceXPDraw, "무승부는 경험치가 없어요")
        XCTAssertEqual(en.practiceXPDraw, "No XP for a draw")
        XCTAssertEqual(ko.practiceHPCarries(63), "63% · 다음 판까지 남아요")
        XCTAssertEqual(en.practiceHPCarries(63), "63% · stays for your next battle")
        XCTAssertEqual(ko.practiceFaintedTitle, "기절했어요")
        XCTAssertEqual(en.practiceFaintedTitle, "Fainted")
        XCTAssertEqual(ko.practiceFaintedHint, "기력의조각으로 되살려야 야생과 다시 싸울 수 있어요")
        XCTAssertEqual(en.practiceFaintedHint, "Use a Revive to fight wild opponents again")
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
