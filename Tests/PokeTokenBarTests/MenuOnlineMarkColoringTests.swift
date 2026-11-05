import AppKit
import XCTest
@testable import PokeTokenBar

final class MenuOnlineMarkColoringTests: XCTestCase {
    private func mark(_ text: String, _ tone: OnlineMenuMark.Tone) -> OnlineMenuMark { .init(text: text, tone: tone, tooltip: "") }
    private func color(of string: NSAttributedString, at index: Int) -> NSColor? {
        string.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
    }

    func testAttentionAndUrgentColorOnlyTheMark() {
        let line = "5h 12% ⚔︎ ●"
        for (tone, expected) in [(OnlineMenuMark.Tone.attention, NSColor.systemBlue), (.urgent, NSColor.systemRed)] {
            let title = NSMutableAttributedString(string: line)
            MenuOnlineMarkColoring.apply(mark("●", tone), to: title)
            XCTAssertEqual(color(of: title, at: line.utf16.count - 1), expected, "\(tone)")
            XCTAssertNil(color(of: title, at: 0), "\(tone): the limit text keeps the system color")
            XCTAssertNil(color(of: title, at: line.utf16.count - 4), "\(tone): the practice badge keeps the system color")
        }
    }

    func testTheCountIsColoredWithTheDot() {
        let title = NSMutableAttributedString(string: "5h 12% ●12\n1.2M")
        MenuOnlineMarkColoring.apply(mark("●12", .urgent), to: title)
        for index in 7...9 { XCTAssertEqual(color(of: title, at: index), .systemRed, "index \(index)") }
        XCTAssertNil(color(of: title, at: 6), "The space before the mark")
        XCTAssertNil(color(of: title, at: 11), "The second line is untouched")
    }

    func testOngoingAndMissingMarksChangeNothing() {
        let ongoing = NSMutableAttributedString(string: "5h 12% ○")
        MenuOnlineMarkColoring.apply(mark("○", .ongoing), to: ongoing)
        XCTAssertNil(color(of: ongoing, at: 7))
        XCTAssertNil(MenuOnlineMarkColoring.color(for: .ongoing))
        let none = NSMutableAttributedString(string: "5h 12% ●")
        MenuOnlineMarkColoring.apply(nil, to: none)
        XCTAssertNil(color(of: none, at: 7))
        let absent = NSMutableAttributedString(string: "5h 12%")
        MenuOnlineMarkColoring.apply(mark("●", .attention), to: absent)
        XCTAssertNil(color(of: absent, at: 0), "A mark that is not in the text colors nothing")
    }
}
