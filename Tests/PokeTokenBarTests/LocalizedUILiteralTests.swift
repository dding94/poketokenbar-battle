import XCTest
@testable import PokeTokenBar

/// Routing guard: `LocalizationInterpolationTests` only checks strings that already go through
/// `L(_:)` — a literal that never reaches the table is structurally invisible to it. #210 shipped
/// three Korean literals straight into `Text(...)`/`Button(...)`, so every non-Korean user would
/// have read Korean. Scan the UI sources instead and require Hangul to live in `Localization.swift`.
/// (Korean *comments* are the house style and stay allowed — only string literals are offenders.)
final class LocalizedUILiteralTests: XCTestCase {
    func testNoHangulStringLiteralsInUISources() throws {
        let ui = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // PokeTokenBarTests
            .deletingLastPathComponent()    // Tests
            .deletingLastPathComponent()    // repo root
            .appendingPathComponent("Sources/PokeTokenBar/UI")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: ui, includingPropertiesForKeys: nil))
        var offenders: [String] = []

        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let lines = try String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            for (index, line) in lines.enumerated() where Self.hasHangulStringLiteral(line) {
                offenders.append("\(url.lastPathComponent):\(index + 1)")
            }
        }

        XCTAssertTrue(offenders.isEmpty, """
            User-facing copy must be routed through Localization.swift so every AppLanguage gets it.
            Move these Hangul literals into an `L` property and reference it: \
            \(offenders.joined(separator: ", "))
            """)
    }

    /// Core files that may hold a Hangul literal, each for a reason that is not user-facing copy picked without a
    /// language. Everything else in Core and the app target must route copy through `L`: the battle log, blocked reasons
    /// and online errors shipped Korean-only because this scan used to stop at `UI/`. A `*Text.swift` file holds `L`
    /// wording, so what keeps it honest is its own test in the other language (`PracticeLanguageTests`).
    private static let coreFilesAllowedHangul: Set<String> = [
        "KoreanParticle.swift",         // the particles themselves
        "CompanionModel.swift",         // per-language tables: language labels and nature names
        "CrashReporter.swift", "LoginItem.swift", "UpdateChecker.swift",   // log file lines, never on screen
        "Models.swift",                 // `CodexRateLimitWindow.displayName`, which no screen reads
        "UsageStore.swift",             // `intervalPresets` labels, which `L.intervalLabel` replaces on screen
        "OnlineBattleSetupInput.swift", // Korean keywords accepted in pasted setup text
        "OnlineBattleSpoken.swift", "OnlineBattleHost.swift",              // call `l.online(ko, en)` inline
    ]
    private static func coreAllowsHangul(_ name: String) -> Bool {
        coreFilesAllowedHangul.contains(name) || name.hasPrefix("Localization") || name.hasSuffix("Localization.swift")
            || name.hasSuffix("Text.swift")
    }
    func testNoHangulStringLiteralsInCoreOutsideLocalizedFiles() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PokeTokenBar")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var offenders: [String] = [], scanned = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" && !url.path.contains("/UI/") {
            if Self.coreAllowsHangul(url.lastPathComponent) { continue }
            scanned += 1
            let lines = try String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            for (index, line) in lines.enumerated() where Self.hasHangulStringLiteral(line) {
                offenders.append("\(url.lastPathComponent):\(index + 1)")
            }
        }
        XCTAssertGreaterThan(scanned, 50, "the scan must actually walk the sources")
        XCTAssertTrue(offenders.isEmpty, """
            Copy in Core must come from `L` so every AppLanguage gets it: \(offenders.joined(separator: ", "))
            """)
    }

    /// Character walk rather than a regex: it has to tell a `//` inside a string literal apart from
    /// a real trailing comment, or Korean comments (house style) would all read as offenders.
    private static func hasHangulStringLiteral(_ line: String) -> Bool {
        var inString = false
        var escaped = false
        var previous: Character?
        for character in line {
            if escaped { escaped = false; previous = character; continue }
            if character == "\\" && inString { escaped = true; previous = character; continue }
            if character == "\"" { inString.toggle(); previous = character; continue }
            if !inString && character == "/" && previous == "/" { return false }  // trailing comment
            if inString && Self.isHangul(character) { return true }
            previous = character
        }
        return false
    }

    private static func isHangul(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            (0xAC00...0xD7A3).contains(scalar.value)     // syllables
                || (0x1100...0x11FF).contains(scalar.value)   // jamo
                || (0x3130...0x318F).contains(scalar.value)   // compatibility jamo
        }
    }
}
