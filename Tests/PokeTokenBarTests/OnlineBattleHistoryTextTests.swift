import XCTest
@testable import PokeTokenBar

final class OnlineBattleHistoryTextTests: XCTestCase {
    func testKoreanKnownMovesAndSafeUntranslatedFallbackWithP2Orientation() {
        let raw = ["|turn|1", "|move|p1a: Pikachu|Quick Attack|p2a: Eevee", "|move|p2a: Eevee|Mystery Move|p1a: Pikachu", "|-ability|p1a: Pikachu|Static", "|win|p2"]
        let text = OnlineBattleHistoryText.logs(raw, localSide: .p2).joined(separator: "\n")
        XCTAssertTrue(text.contains("1턴"))
        XCTAssertTrue(text.contains("상대 포켓몬 · 전광석화 사용"))
        XCTAssertTrue(text.contains("내 포켓몬 · 미번역 기술 (Mystery Move) 사용"))
        XCTAssertTrue(text.contains("정전기"))
        XCTAssertTrue(text.contains("내 포켓몬 승리"))
        XCTAssertFalse(text.contains("p1a:"))
    }
    func testUnknownProtocolAndUnsafeNamesNeverEchoRawMetadata() {
        let raw = ["|player|p1|private@example.com", "|-unknown|p1a: private@example.com|SECRET", "|raw|<script>SECRET</script>", "|move|p1a: name|<script>SECRET</script>|p2a: name", "|move|p9a: SECRET|Tackle|p2a: name", "|-ability|p1a: name|secret@example.com", "|turn|SECRET", "|-damage|p1a: name|SECRET"]
        let text = OnlineBattleHistoryText.logs(raw, localSide: .p1).joined()
        XCTAssertFalse(text.contains("SECRET")); XCTAssertFalse(text.contains("private@")); XCTAssertFalse(text.contains("secret@"))
        XCTAssertFalse(text.contains("<script>")); XCTAssertFalse(text.contains("p9a"))
        XCTAssertTrue(text.contains("알 수 없는 기술"))
    }
    func testViewerHPIsRetainedOnlyAsNumbersAndKnownStatus() {
        let text = OnlineBattleHistoryText.logs(["|-damage|p1a: Eevee|89/132 par", "|-damage|p2a: Pikachu|32/100", "|-status|p2a: Pikachu|par", "|tie|"], localSide: .p1).joined()
        XCTAssertTrue(text.contains("89/132")); XCTAssertTrue(text.contains("32/100")); XCTAssertTrue(text.contains("마비")); XCTAssertTrue(text.contains("무승부"))
    }
    func testCanonicalTieMarkerProducesKoreanTerminalText() {
        XCTAssertEqual(OnlineBattleHistoryText.logs(["|tie"], localSide: .p2), ["무승부 · 배틀을 마쳤습니다."])
    }
    func testUnknownEffectHasGenericFallbackWithoutExposingProtocolOrPayload() {
        XCTAssertEqual(OnlineBattleHistoryText.logs(["|-future-private-tag|p1a: name|SECRET"], localSide: .p1), ["전투 효과가 처리되었습니다."])
    }

    func testRecoveryEffectivenessAndStatChangesHaveKoreanMessages() {
        let raw = ["|-heal|p1a: private|100/120", "|-curestatus|p2a: private|par",
                   "|-supereffective|p2a: private", "|-resisted|p1a: private",
                   "|-unboost|p2a: private|spe|1", "|-boost|p1a: private|atk|2",
                   "|-status|p2a: private|new-status", "|-boost|p1a: private|new-stat|1"]
        XCTAssertEqual(OnlineBattleHistoryText.logs(raw, localSide: .p1), [
            "내 포켓몬 · 체력을 회복했습니다 (HP 100/120).", "상대 포켓몬 · 상태이상이 회복됐습니다.",
            "효과가 굉장합니다!", "효과가 별로입니다.", "상대 포켓몬 · 스피드 하락", "내 포켓몬 · 공격 상승",
            "상대 포켓몬 · 상태이상 상태가 되었습니다.", "내 포켓몬 · 능력치 상승"
        ])
        XCTAssertTrue(OnlineBattleHistoryText.logs(["malformed", "|", "|metadata|p1a: private|secret"], localSide: .p1).isEmpty)
    }

}
