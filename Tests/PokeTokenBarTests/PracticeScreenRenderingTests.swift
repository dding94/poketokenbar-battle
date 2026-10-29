import AppKit
import SwiftUI
import Vision
import XCTest
@testable import PokeTokenBar

/// Drives the in-popover practice screen through selection → manual battle → result with a real
/// `PracticeSession` and engine, and reads the result off the rendered pixels. Assertions stick to
/// Latin and numeric text rendered with `L(.en)`, because Vision's Korean recognition is flaky.
/// Set `PTB_SNAPSHOT_SCREENSHOT_DIR` to keep the three stages as PNGs (PR images).
@MainActor
final class PracticeScreenRenderingTests: XCTestCase {
    private var window: NSWindow?
    private var now: TimeInterval = 0

    override func tearDown() async throws {
        window?.close()
        window = nil
    }

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()    // PokeTokenBarTests
        .deletingLastPathComponent()    // Tests
        .deletingLastPathComponent()    // repo root

    /// Pikachu (Thunderbolt) and Magikarp (Splash) at Lv.50, as in `PracticeBattleRenderingTests`.
    static func syntheticState() -> CompanionState {
        var state = CompanionState()
        state.dex = [25, 129].enumerated().map { index, species in
            var p = PokemonProfile.generate(seed: 42, instanceID: "popover-render-\(index)")
            p.gender = .male; p.level = 50; p.abilityName = index == 0 ? "static" : "swift-swim"
            p.moves = [PokemonKnownMove(name: index == 0 ? "thunderbolt" : "splash", learnedAtLevel: 1)]
            return DexEntry(baseID: species, finalID: species, chainOrder: [species], rarity: .common,
                            caughtAt: nil, nature: .hardy, profile: p,
                            names: [species: ["ko": index == 0 ? "피카츄" : "잉어킹"]])
        }
        return state
    }

    static var engineURL: URL { root.appendingPathComponent("engine/dist/battle-engine.js") }

    private func makeSession() -> PracticeSession {
        let session = PracticeSession(engineURL: Self.engineURL, clock: { self.now }, drivesAutomatically: false)
        session.prepare(state: Self.syntheticState(), activeName: nil)
        return session
    }

    private func host(_ session: PracticeSession) -> NSView {
        let host = NSHostingView(rootView: PracticeScreen(session: session, l: L(.en), artwork: false, onClose: {})
            .background(Color.white)
            .environment(\.colorScheme, .light))
        host.frame = NSRect(x: 0, y: 0, width: PopoverMetrics.width, height: 640)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: PopoverMetrics.width, height: 640),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.orderFront(nil)
        self.window = window
        return host
    }

    private func capture(_ host: NSView) throws -> NSBitmapImageRep {
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    private func recognizedText(_ bitmap: NSBitmapImageRep) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    /// Polls until every needle is rendered (spaces ignored) or 5 s pass; SwiftUI draws a state change
    /// a run-loop turn or two later. Returns the last text and bitmap for assertions and screenshots.
    private func waitForText(_ needles: [String], in host: NSView) async throws -> (String, NSBitmapImageRep) {
        let deadline = ContinuousClock.now + .seconds(5)
        var text = ""
        var bitmap = try capture(host)
        repeat {
            bitmap = try capture(host)
            text = try recognizedText(bitmap)
            if needles.allSatisfy({ Self.normalized(text).contains(Self.normalized($0)) }) { break }
            try await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock.now < deadline
        return (text, bitmap)
    }

    private static func normalized(_ text: String) -> String { text.replacingOccurrences(of: " ", with: "") }

    private func assertRendered(_ needles: [String], in text: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        for needle in needles {
            XCTAssertTrue(Self.normalized(text).contains(Self.normalized(needle)),
                          "\(needle) not rendered. Seen: \(text)", file: file, line: line)
        }
    }

    /// Same height as the tabs (~612pt) so the popover does not jump, never wider than the popover.
    private func assertPopoverSized(_ host: NSView, file: StaticString = #filePath, line: UInt = #line) {
        let size = host.fittingSize
        XCTAssertLessThanOrEqual(size.width, PopoverMetrics.width, "wider than the popover", file: file, line: line)
        XCTAssertGreaterThanOrEqual(size.height, 596, "shorter than the tabs: \(size)", file: file, line: line)
        XCTAssertLessThanOrEqual(size.height, 628, "taller than the tabs: \(size)", file: file, line: line)
    }

    private func save(_ bitmap: NSBitmapImageRep, as name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["PTB_SNAPSHOT_SCREENSHOT_DIR"] else { return }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent(name))
    }

    // MARK: Stages

    /// Selection: my entry with its level, the opponent list, the 30 s manual mode and a start button.
    func testSelectionShowsContendersModeAndStartButton() async throws {
        let session = makeSession()
        XCTAssertEqual(session.roster?.eligible.count, 2, "the synthetic save holds two eligible Pokémon")
        XCTAssertNil(session.battle)
        let host = host(session)
        let needles = ["Lv.50", "Start battle", "30", "200"]   // level, CTA, manual timer, rules caption
        let (text, bitmap) = try await waitForText(needles, in: host)
        assertRendered(needles, in: text)
        assertPopoverSized(host)
        try save(bitmap, as: "practice-popover-selection.png")
    }

    /// Manual battle: the turn clock in the top bar and a move card with its name and PP.
    func testManualBattleShowsMoveGridAndTurnClock() async throws {
        let session = makeSession()
        session.mode = .manual
        session.start()
        XCTAssertEqual(session.battle?.phase, .running)
        XCTAssertEqual(session.battle?.request.moves.first?.id, "thunderbolt")
        let host = host(session)
        // artwork: false renders move identifiers, so Pikachu's only move reads "Thunderbolt".
        let needles = ["Thunderbolt", "PP", "Turn 1", "30s", "Forfeit"]
        let (text, bitmap) = try await waitForText(needles, in: host)
        assertRendered(needles, in: text)
        assertPopoverSized(host)
        try save(bitmap, as: "practice-popover-battle.png")
    }

    /// Result: an automatic battle stepped to its end shows the outcome and the rematch actions, and
    /// showing it marks the result as seen (the menu bar badge clears).
    func testFinishedBattleShowsResultAndMarksItSeen() async throws {
        let session = makeSession()
        session.start()
        session.mode = .automatic
        for _ in 0..<600 where session.battle?.phase == .running {
            now += 1
            session.tick()
        }
        XCTAssertEqual(session.battle?.phase, .finished, "an automatic battle must end within the bounded loop")
        XCTAssertNotNil(session.battle?.result)
        let host = host(session)
        let needles = ["Rematch", "New opponent"]
        let (text, bitmap) = try await waitForText(needles, in: host)
        assertRendered(needles, in: text)
        XCTAssertTrue(["Victory", "Defeat", "Draw"].contains { Self.normalized(text).contains($0) },
                      "outcome not rendered: \(text)")
        XCTAssertTrue(session.resultSeen, "the result screen reports it was shown")
        assertPopoverSized(host)
        try save(bitmap, as: "practice-popover-result.png")
    }
}
