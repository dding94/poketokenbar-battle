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
