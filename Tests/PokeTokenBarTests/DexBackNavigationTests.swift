import AppKit
import SwiftUI
import Vision
import XCTest
@testable import PokeTokenBar

private struct OfflineProvider: PokeProviding, PokemonDetailProviding {
    func line(baseSpeciesID: Int) async throws -> EvoLine { throw URLError(.notConnectedToInternet) }
    func baseSpeciesIndex() async throws -> [BaseSpecies] { [] }
    func baseSpecies(id: Int) async throws -> BaseSpecies? { nil }
    func pokemonDetails(speciesID: Int) async throws -> PokemonDetails { throw URLError(.notConnectedToInternet) }
}

/// The detail page replaces the grid/log, so Back rebuilds them. These drive the real `CollectionView`
/// through that round trip and read the result off the rendered pixels.
@MainActor
final class DexBackNavigationTests: XCTestCase {
    private var window: NSWindow?

    override func tearDown() async throws {
        window?.close()
        window = nil
    }

    /// 20 species = 2 grid pages: Mon1…Mon16, then Mon17…Mon20.
    private func makeStore() throws -> CompanionStore {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("dex-back-\(UUID()).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        var state = CompanionState()
        state.language = .en
        state.dex = (1...20).map { id in
            DexEntry(id: "entry-\(id)", baseID: id, finalID: id, chainOrder: [id], rarity: .common,
                     caughtAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(id)),
                     names: [id: ["en": "Mon\(id)"]])
        }
        try JSONEncoder().encode(state).write(to: file)
        return CompanionStore(provider: OfflineProvider(), fileURL: file)
    }

    private func host(_ store: CompanionStore, _ navigation: PopoverNavigation) -> NSView {
        let host = NSHostingView(rootView: CollectionView(store: store, navigation: navigation)
            .frame(width: PopoverMetrics.contentWidth, height: 520)
            .background(Color.white)
            .environment(\.colorScheme, .light))
        host.frame = NSRect(x: 0, y: 0, width: PopoverMetrics.contentWidth, height: 520)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: PopoverMetrics.contentWidth, height: 520),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.orderFront(nil)
        self.window = window
        return host
    }

    // MARK: Rendered text (the accessibility tree stays empty without an AX client)

    /// `candidates`: Vision's top readings. The pager's "2/2" still reads as "212", so tests check
    /// which species a page shows instead.
    private struct Word {
        let candidates: [String]
        let box: CGRect   // normalized, y-up

        /// Spaces are ignored: Vision splits and joins words inconsistently.
        func reads(_ text: String, exactly: Bool) -> Bool {
            let wanted = text.replacingOccurrences(of: " ", with: "")
            return candidates.contains {
                let candidate = $0.replacingOccurrences(of: " ", with: "")
                return exactly ? candidate == wanted : candidate.contains(wanted)
            }
        }
    }

    private func words(in host: NSView) throws -> [Word] {
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VisionOCR.perform(request, on: XCTUnwrap(bitmap.cgImage))
        return request.results?.compactMap { observation in
            let candidates = observation.topCandidates(10).map(\.string)
            return candidates.isEmpty ? nil : Word(candidates: candidates, box: observation.boundingBox)
        } ?? []
    }

    /// Polls: SwiftUI renders a state change a run-loop turn or two later.
    @discardableResult
    private func waitForText(_ text: String, exactly: Bool = false, in host: NSView,
                             file: StaticString = #filePath, line: UInt = #line) async throws -> Word? {
        let deadline = ContinuousClock.now + .seconds(5)
        var seen: [Word] = []
        repeat {
            seen = try words(in: host)
            if let match = seen.first(where: { $0.reads(text, exactly: exactly) }) { return match }
            try await Task.sleep(for: .milliseconds(50))
        } while ContinuousClock.now < deadline
        XCTFail("\(text) not rendered. Seen: \(seen.map(\.candidates))", file: file, line: line)
        return nil
    }

    /// Clicks the control under a rendered label. A synthetic mouse-down on an `NSButton` blocks in its
    /// tracking loop waiting for a queued mouse-up, so that one is pressed directly. Plain SwiftUI buttons
    /// take the events.
    private func press(_ word: Word, in host: NSView) throws {
        let y = host.isFlipped ? 1 - word.box.midY : word.box.midY   // Vision boxes are y-up
        let point = NSPoint(x: word.box.midX * host.bounds.width, y: y * host.bounds.height)
        var view = host.hitTest(host.convert(point, to: host.superview))
        while let current = view, !(current is NSButton) { view = current.superview }
        if let button = view as? NSButton {
            button.performClick(nil)
            return
        }
        let window = try XCTUnwrap(host.window)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: host.convert(point, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
        }
    }

    /// Presses and re-presses until `done`. Right after a transition the view tree can still hit-test the
    /// previous screen (seen on CI), so a press that lands there is retried.
    private func press(until done: () -> Bool, what: String, file: StaticString, line: UInt,
                       _ pressOnce: () async throws -> Void) async throws {
        for _ in 0..<5 {
            try await pressOnce()
            let deadline = ContinuousClock.now + .seconds(1)
            repeat {
                try await Task.sleep(for: .milliseconds(50))
                if done() { return }
            } while ContinuousClock.now < deadline
        }
        XCTFail("Pressing \(what) never changed the screen", file: file, line: line)
    }

    /// Opens the detail page by pressing the row or cell labeled `text`.
    private func pressToOpenDetail(_ text: String, exactly: Bool = false, _ navigation: PopoverNavigation, in host: NSView,
                                   file: StaticString = #filePath, line: UInt = #line) async throws {
        try await press(until: { navigation.dexDetailCollectionID != nil }, what: text, file: file, line: line) {
            let word = try await waitForText(text, exactly: exactly, in: host, file: file, line: line)
            try press(XCTUnwrap(word, file: file, line: line), in: host)
        }
    }

    /// Presses the detail page's Back, the topmost button. It is not found by its label: on macOS 27 Vision
    /// drops "‹ Back" from the full page (it reads "#18" beside it, and "‹ Back" from a crop of the same image).
    /// Back is a borderless button that AppKit backs with an untitled `NSButton`.
    private func pressBack(_ store: CompanionStore, _ navigation: PopoverNavigation, in host: NSView,
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        try await waitForText(store.l.pokemonDetailsUnavailable, in: host, file: file, line: line)   // `OfflineProvider`
        func buttons(_ view: NSView) -> [NSButton] {
            ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap { buttons($0) }
        }
        func top(_ button: NSButton) -> CGFloat {
            let frame = button.convert(button.bounds, to: host)
            return host.isFlipped ? frame.minY : host.bounds.height - frame.maxY
        }
        try await press(until: { navigation.dexDetailCollectionID == nil }, what: store.l.back, file: file, line: line) {
            let back = try XCTUnwrap(buttons(host).min { top($0) < top($1) }, "the detail page has no button",
                                     file: file, line: line)
            back.performClick(nil)
        }
    }

    /// Opens #18 (page 2) the way Home's sprite does, then presses the detail page's Back.
    private func openPageTwoSpeciesAndGoBack(_ store: CompanionStore, _ navigation: PopoverNavigation,
                                             _ host: NSView) async throws {
        let species = try XCTUnwrap(store.dexSpecies.first { $0.id == 18 })
        navigation.dexDetailCollectionID = species.collectionID
        try await pressBack(store, navigation, in: host)
    }

    // MARK: Pokédex grid

    func testBackFromDetailReturnsToThePageOfThatSpecies() async throws {
        let store = try makeStore()
        let navigation = PopoverNavigation()
        navigation.tab = .collection
        let root = host(store, navigation)
        try await waitForText("Mon5", in: root)

        try await openPageTwoSpeciesAndGoBack(store, navigation, root)

        try await waitForText("Mon20", in: root)
        // Only the page comes back: the species is not selected, so the footer does not name it.
        let footer = try words(in: root).filter { $0.box.midY < 0.05 }   // y-up: the bottom strip
        XCTAssertFalse(footer.contains { $0.reads("Mon18", exactly: false) }, "Seen: \(footer.map(\.candidates))")
    }

    func testReturnPageIsUsedOnlyOnce() async throws {
        let store = try makeStore()
        let navigation = PopoverNavigation()
        navigation.tab = .collection
        let root = host(store, navigation)
        try await openPageTwoSpeciesAndGoBack(store, navigation, root)
        try await waitForText("Mon20", in: root)

        navigation.showingCollectionLog = true
        try await Task.sleep(for: .milliseconds(100))
        navigation.showingCollectionLog = false

        try await waitForText("Mon5", in: root)
    }

    /// Back to the log must not leave the grid's return page behind for the next segment switch.
    func testBackToTheLogLeavesTheGridOnItsFirstPage() async throws {
        let store = try makeStore()
        let navigation = PopoverNavigation()
        navigation.tab = .collection
        navigation.showingCollectionLog = true
        let root = host(store, navigation)
        try await openPageTwoSpeciesAndGoBack(store, navigation, root)
        try await waitForText("Mon20", in: root)   // the log's top row

        navigation.showingCollectionLog = false

        try await waitForText("Mon5", in: root)
    }

    // MARK: Catch log

    /// Mon1 is the oldest catch, so it is the log's last row — off screen until scrolled to.
    func testBackFromDetailReturnsTheLogToWhereItWas() async throws {
        let store = try makeStore()
        let navigation = PopoverNavigation()
        navigation.tab = .collection
        navigation.showingCollectionLog = true
        let root = host(store, navigation)
        try await waitForText("Mon20", in: root)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
        let log = try XCTUnwrap(descendants(root).compactMap { $0 as? NSScrollView }
            .max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) })
        // LazyVStack grows the document as rows are realized, so keep scrolling to the end.
        var row: Word?
        for _ in 0..<20 where row == nil {
            let clip = log.contentView
            let bottom = (log.documentView?.frame.height ?? 0) - clip.bounds.height
            clip.scroll(to: NSPoint(x: 0, y: clip.isFlipped ? bottom : 0))
            log.reflectScrolledClipView(clip)
            try await Task.sleep(for: .milliseconds(100))
            row = try words(in: root).first { $0.reads("Mon1", exactly: true) }
        }
        XCTAssertNotNil(row, "scrolling never reached Mon1")
        try await pressToOpenDetail("Mon1", exactly: true, navigation, in: root)
        try await pressBack(store, navigation, in: root)

        try await waitForText("Mon1", exactly: true, in: root)

        // Like the grid's page, the position does not survive a segment switch.
        navigation.showingCollectionLog = false
        try await Task.sleep(for: .milliseconds(100))
        navigation.showingCollectionLog = true
        try await waitForText("Mon20", in: root)
    }
}
