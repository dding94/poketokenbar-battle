import AppKit
import SwiftUI
import Vision
import XCTest
@testable import PokeTokenBar

/// T17 drawn: the hinted move cards inside the arena's fixed 488pt board and 122pt footer. Synthetic data and
/// native SwiftUI renders only. With `PTB_SNAPSHOT_SCREENSHOT_DIR` set the whole-screen PNGs are kept (720px wide).
@MainActor
final class OnlineBattleMoveHintRenderingTests: XCTestCase {
    private typealias Mon = OnlineBattleHintFixture.Mon
    private var window: NSWindow?
    override func tearDown() async throws { window?.close(); window = nil }

    private static let filler: CGFloat = 200

    private func arena(_ me: Mon, _ foe: Mon, seat: OnlineBattleSide = .p1) throws -> OnlineBattleArenaFixture.Arena {
        let battle = seat == .p1 ? try OnlineBattleHintFixture.battle(p1: me, p2: foe) : try OnlineBattleHintFixture.battle(p1: foe, p2: me)
        return try OnlineBattleArenaFixture.arena(seat: seat, custom: battle)
    }

    private func arenaHost(_ model: OnlineBattlePresentation, _ lang: AppLanguage) async -> NSView {
        let host = NSHostingView(rootView: VStack(alignment: .leading, spacing: 0) {
            OnlineBattleArena(model: model, l: L(lang), artwork: false, speciesNameProvider: OnlineBattleSyntheticNameProvider(),
                              speciesNameStore: PokemonNameDisplayStore())
            Color.clear.frame(height: Self.filler)
        }.frame(width: PopoverMetrics.scrollContentWidth).background(Color.white).environment(\.colorScheme, .light))
        host.frame = NSRect(x: 0, y: 0, width: PopoverMetrics.scrollContentWidth, height: 700)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
        window.contentView = host; window.orderFront(nil); self.window = window
        try? await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func settle(_ host: NSView) async {
        try? await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded()
    }

    private func boardHeight(_ host: NSView) -> CGFloat { host.fittingSize.height - Self.filler }

    /// Nothing may draw under the board's fixed height: a footer taller than its room would hang out of the scroll area.
    private func inkBelowTheBoard(_ host: NSView) throws -> Int {
        let bitmap = try PracticeScreenRenderingTests.capture2x(host)
        let first = Int(OnlineBattleArena.boardHeight * 2) + 2
        var inked = 0
        for y in first..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.alphaComponent > 0.01, color.redComponent < 0.99 || color.greenComponent < 0.99 || color.blueComponent < 0.99 { inked += 1 }
            }
        }
        return inked
    }

    private func recognized(_ host: NSView, languages: [String]) throws -> String {
        let bitmap = try PracticeScreenRenderingTests.capture2x(host)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.recognitionLanguages = languages
        try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    private func screenHost(_ model: OnlineBattlePresentation, _ lang: AppLanguage) async -> NSView {
        let provider = OnlineBattleSyntheticNameProvider()
        let names = PokemonNameDisplayStore()
        for id in [4, 1, 68, 94] { _ = await names.load(.init(kind: .pokemonSpecies, name: String(id)), provider: provider) }
        let host = NSHostingView(rootView: OnlineBattleScreen(model: model, l: L(lang), artwork: false, readInvitationClipboard: { nil },
                                                             speciesNameProvider: provider, speciesNameStore: names,
                                                             onClosePopover: {}, onClose: {})
            .background(Color.white).environment(\.colorScheme, .light))
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 610)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 360, height: 610),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
        window.contentView = host; window.orderFront(nil); self.window?.close(); self.window = window
        await settle(host)
        return host
    }

    private func keep(_ host: NSView, as name: String) throws {
        let bitmap = try PracticeScreenRenderingTests.capture2x(host)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertEqual(bitmap.pixelsWide, 720, "the kept images are 720px wide")
        XCTAssertGreaterThan(data.count, 8000, "A blank hosting view must not pass as a rendered screen")
        if let path = ProcessInfo.processInfo.environment["PTB_SNAPSHOT_SCREENSHOT_DIR"] {
            let directory = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(name))
        }
    }

    private let charmander = Mon(species: 4, moves: ["ember", "quick-attack", "dragon-claw", "growl"])
    private let bulbasaur = Mon(species: 1, moves: ["splash"])
    /// FIGHTING + STAB + Priority is the widest badge row in English.
    private let machamp = Mon(species: 68, moves: ["mach-punch", "knock-off", "bullet-punch", "bulk-up"])
    private let gengar = Mon(species: 94, moves: ["splash"])

    /// Hints change what is inside the cards, never the board: one height with and without them, in both
    /// languages and for the widest English row, and nothing is drawn under the board.
    func testHintedCardsKeepTheBoardAtItsOneHeightAndInsideTheScrollArea() async throws {
        for lang in [AppLanguage.ko, .en] {
            for (me, foe) in [(charmander, bulbasaur), (machamp, gengar)] {
                let fixture = try arena(me, foe); defer { fixture.close() }
                XCTAssertEqual(fixture.model.moveHints.count, 4)
                let host = await arenaHost(fixture.model, lang)
                let hinted = boardHeight(host)
                XCTAssertEqual(try inkBelowTheBoard(host), 0, "\(lang) hinted: ink under the board")
                let withHints = try PracticeScreenRenderingTests.capture2x(host).representation(using: .png, properties: [:])
                fixture.model.moveHints = [:]
                await settle(host)
                XCTAssertEqual(boardHeight(host), hinted, accuracy: 0.5, "\(lang): the hints change the card, not the board")
                let without = try PracticeScreenRenderingTests.capture2x(host).representation(using: .png, properties: [:])
                XCTAssertNotEqual(withHints, without, "\(lang): the hints must actually be drawn")
                XCTAssertEqual(hinted, OnlineBattleArena.boardHeight, accuracy: 0.5)
                XCTAssertLessThanOrEqual(hinted, 520 - 16 - 12, "the move picker must stay inside the scroll area")
            }
        }
    }

    /// The marked card and the locked cards keep their hints after my choice, in the same height.
    func testHintsStayOnTheCardsAfterMyChoiceWithoutChangingTheBoard() async throws {
        let fixture = try arena(charmander, bulbasaur); defer { fixture.close() }
        let host = await arenaHost(fixture.model, .en)
        let resting = boardHeight(host)
        fixture.model.send(.chooseMove(1)); await settle(host)
        XCTAssertEqual(boardHeight(host), resting, accuracy: 0.5)
        XCTAssertEqual(try inkBelowTheBoard(host), 0)
        XCTAssertEqual(fixture.model.moveHints.count, 4, "a choice does not drop the hints")
        let text = try recognized(host, languages: ["en-US"])
        XCTAssertTrue(text.contains("Pow 40"), "the hint line stays on the locked cards: \(text)")
    }

    /// The words on the cards, read back from the pixels: the matchup badge, STAB, power and accuracy.
    func testTheCardsSayMatchupStabAndPowerInEnglish() async throws {
        let fixture = try arena(charmander, bulbasaur); defer { fixture.close() }
        let host = await arenaHost(fixture.model, .en)
        let text = try recognized(host, languages: ["en-US"])
        for needle in ["×2", "STAB", "Pow 40", "Acc 100", "Special", "Status"] {
            XCTAssertTrue(text.contains(needle), "\(needle) missing in: \(text)")
        }
    }

    /// Whole-screen renders for review: both languages, plus the widest English row against an immune foe.
    func testRendersTheHintedArenaForReview() async throws {
        let rows: [(String, AppLanguage, Mon, Mon)] = [
            ("online-t17-hints-ko.png", .ko, charmander, bulbasaur),
            ("online-t17-hints-en.png", .en, charmander, bulbasaur),
            ("online-t17-hints-en-widest.png", .en, machamp, gengar),
        ]
        for (name, lang, me, foe) in rows {
            let fixture = try arena(me, foe); defer { fixture.close() }
            let host = await screenHost(fixture.model, lang)
            try keep(host, as: name)
            XCTAssertEqual(fixture.model.moveHints.count, 4, name)
        }
    }
}
