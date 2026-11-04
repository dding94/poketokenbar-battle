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
}
