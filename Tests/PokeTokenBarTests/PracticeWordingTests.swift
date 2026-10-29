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
