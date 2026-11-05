import AppKit
import XCTest
@testable import PokeTokenBar

/// Every test uses its own named pasteboard: the person's clipboard is never read or written.
@MainActor
final class OnlineBattleClipboardTests: XCTestCase {
    private var board: NSPasteboard!

    override func setUp() async throws {
        board = NSPasteboard(name: .init("ptb-test-\(UUID().uuidString)"))
    }
    override func tearDown() async throws {
        board.releaseGlobally()
        board = nil
    }
    private func put(_ text: String) {
        board.clearContents()
        board.setString(text, forType: .string)
    }

    func testACopiedCodeIsMarkedForClipboardHistoriesToSkip() {
        XCTAssertTrue(OnlineBattleClipboard.write("ABCDEFGHJKMN", to: board))
        XCTAssertEqual(board.string(forType: .string), "ABCDEFGHJKMN")
        XCTAssertEqual(OnlineBattleClipboard.concealedType.rawValue, "org.nspasteboard.ConcealedType")
        XCTAssertTrue(board.types?.contains(OnlineBattleClipboard.concealedType) == true)
    }
    func testACopyReplacesWhatWasThere() {
        put("something else")
        XCTAssertTrue(OnlineBattleClipboard.write("ABCDEFGHJKMN", to: board))
        XCTAssertEqual(board.string(forType: .string), "ABCDEFGHJKMN")
    }
    func testForgettingClearsOnlyTheSameCode() {
        put("  ABCDEFGHJKMN\n")
        OnlineBattleClipboard.forget("ABCDEFGHJKMN", on: board)
        XCTAssertNil(board.string(forType: .string))
    }
    func testForgettingLeavesAnythingElseAlone() {
        for other in ["a note from earlier", "ZZZZZZZZZZZZ", "ABCDEFGHJKMN and more"] {
            put(other)
            let count = board.changeCount
            OnlineBattleClipboard.forget("ABCDEFGHJKMN", on: board)
            XCTAssertEqual(board.string(forType: .string), other)
            XCTAssertEqual(board.changeCount, count, "nothing was written")
        }
    }
    func testForgettingUnderstandsTheSpacedAndDashedFormsOfAnInviteCode() {
        for form in ["ABCD-EFGH-JKMN", "abcd efgh jkmn"] {
            put(form)
            OnlineBattleClipboard.forget("ABCDEFGHJKMN", on: board)
            XCTAssertNil(board.string(forType: .string), form)
        }
    }
    func testForgettingTakesTheHostsTwoLineInvitationOfThatCode() {
        put("서버 주소: https://battle.example.invalid\n초대코드: ABCDEFGHJKMN")
        OnlineBattleClipboard.forget("ABCDEFGHJKMN", on: board)
        XCTAssertNil(board.string(forType: .string))
        let other = "서버 주소: https://battle.example.invalid\n초대코드: ZZZZZZZZZZZZ"
        put(other)
        OnlineBattleClipboard.forget("ABCDEFGHJKMN", on: board)
        XCTAssertEqual(board.string(forType: .string), other)
        let longer = "안녕하세요\n오늘 시작해요\n초대코드: ABCDEFGHJKMN"
        put(longer)
        OnlineBattleClipboard.forget("ABCDEFGHJKMN", on: board)
        XCTAssertEqual(board.string(forType: .string), longer, "a longer message is the person's own text")
    }
    func testForgettingAFreeFormCodeNeedsAnExactMatch() {
        put("recovery-code-one")
        OnlineBattleClipboard.forget("recovery-code-two", on: board)
        XCTAssertEqual(board.string(forType: .string), "recovery-code-one")
        OnlineBattleClipboard.forget("recovery-code-one", on: board)
        XCTAssertNil(board.string(forType: .string))
    }
    func testForgettingOnAnEmptyClipboardDoesNothing() {
        board.clearContents()
        let count = board.changeCount
        OnlineBattleClipboard.forget("ABCDEFGHJKMN", on: board)
        XCTAssertEqual(board.changeCount, count)
    }
    /// The screens must use the marked writer. A plain write here would put a code in every clipboard history again.
    func testNoOnlineScreenWritesTheClipboardItself() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("Sources/PokeTokenBar/UI")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("Online") && $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(source.contains(".setString("), file.lastPathComponent)
            XCTAssertFalse(source.contains("clearContents"), file.lastPathComponent)
        }
        let app = try String(contentsOf: root.appendingPathComponent("Sources/PokeTokenBar/PokeTokenBarApp.swift"), encoding: .utf8)
        XCTAssertTrue(app.contains("onSetupCodeUsed = { OnlineBattleClipboard.forget($0) }"), "the app wires the session's signal to the clipboard")
    }
}
