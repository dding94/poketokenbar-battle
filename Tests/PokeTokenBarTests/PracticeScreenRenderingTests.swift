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
        syntheticState(pikachu: ["thunderbolt"], magikarp: ["splash"])
    }

    /// Pikachu (static; four moves) against Magikarp (swift-swim; four moves). Volt Tackle is a one-turn KO
    /// that is super effective and costs recoil, so one choice exercises damage, a callout and a finisher.
    static func stagedState() -> CompanionState {
        syntheticState(pikachu: ["thunderbolt", "quick-attack", "iron-tail", "volt-tackle"],
                       magikarp: ["splash", "tackle", "flail", "bounce"])
    }

    /// The roster builds both snapshots with `BattleSnapshot.make` from these dex entries.
    static func syntheticState(pikachu: [String], magikarp: [String]) -> CompanionState {
        var state = CompanionState()
        state.dex = [25, 129].enumerated().map { index, species in
            var p = PokemonProfile.generate(seed: 42, instanceID: "popover-render-\(index)")
            p.gender = .male; p.level = 50; p.abilityName = index == 0 ? "static" : "swift-swim"
            p.moves = (index == 0 ? pikachu : magikarp).map { PokemonKnownMove(name: $0, learnedAtLevel: 1) }
            return DexEntry(baseID: species, finalID: species, chainOrder: [species], rarity: .common,
                            caughtAt: nil, nature: .hardy, profile: p,
                            names: [species: ["ko": index == 0 ? "피카츄" : "잉어킹"]])
        }
        return state
    }

    static var engineURL: URL { root.appendingPathComponent("engine/dist/battle-engine.js") }

    private func makeSession(_ state: CompanionState = syntheticState()) -> PracticeSession {
        let session = PracticeSession(engineURL: Self.engineURL, clock: { self.now }, drivesAutomatically: false)
        session.prepare(state: state, activeName: nil)
        return session
    }

    /// Starts a manual staged battle and picks Volt Tackle by its slot.
    private func chooseVoltTackle(_ session: PracticeSession) throws {
        session.mode = .manual
        session.start()
        XCTAssertEqual(session.battle?.phase, .running)
        let slot = try XCTUnwrap(session.battle?.request.moves.first { $0.id == "volttackle" }?.slot,
                                 "Pikachu must offer Volt Tackle")
        session.choose(slot: slot)
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

    /// Spaces and letter case are ignored: Vision reads small "Lv.50" as "LV.50" on CI. The multiplication
    /// sign reads as a letter x as often as not, so "×2" and "x2" are the same needle.
    private static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "×", with: "x").lowercased()
    }

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
        // Staging holds the board until the last beat has played, so step until the playback is idle too.
        for _ in 0..<600 where session.battle?.phase == .running || session.playback?.isPlaying == true {
            now += 1
            session.tick()
        }
        XCTAssertEqual(session.battle?.phase, .finished, "an automatic battle must end within the bounded loop")
        XCTAssertNotEqual(session.playback?.isPlaying, true, "the playback must finish within the bounded loop")
        XCTAssertNotNil(session.battle?.result)
        let host = host(session)
        let needles = ["Rematch", "New opponent"]
        let (text, bitmap) = try await waitForText(needles, in: host)
        assertRendered(needles, in: text)
        XCTAssertTrue(["Victory", "Defeat", "Draw"].contains { Self.normalized(text).contains(Self.normalized($0)) },
                      "outcome not rendered: \(text)")
        XCTAssertTrue(session.resultSeen, "the result screen reports it was shown")
        assertPopoverSized(host)
        try save(bitmap, as: "practice-popover-result-auto.png")
    }

    // MARK: Staging

    /// Mid-beat: with the clock held inside Volt Tackle's beat, the board shows the action, the
    /// super-effective callout and the floating damage number next to the foe's HP bar.
    func testMidBeatShowsCalloutAndFloatingDamage() async throws {
        let session = makeSession(Self.stagedState())
        try chooseVoltTackle(session)
        // If Magikarp moves first, step whole beats until Volt Tackle is the one on screen. Each step
        // lands exactly where the next beat starts, so the clock stays inside that beat.
        for _ in 0..<6 where session.playback?.beat?.moveID != "volttackle" {
            now += PracticePlayback.actionBeat
            session.tick()
        }
        let beat = session.playback?.beat
        XCTAssertEqual(beat?.actor, .player, "Volt Tackle must be the beat on screen")
        XCTAssertEqual(session.playback?.isPlaying, true, "the beat is still playing")
        XCTAssertEqual(beat?.callouts.contains(.superEffective(.opponent)), true)
        let damage = abs(beat?.hpDelta[.opponent] ?? 0)
        XCTAssertGreaterThan(damage, 0, "Volt Tackle must damage Magikarp")

        let host = host(session)
        let needles = ["Super effective", "Volt Tackle"]
        let (text, bitmap) = try await waitForText(needles, in: host)
        try save(bitmap, as: "practice-popover-beat.png")
        assertRendered(needles, in: text)
        // The floating number reads "−N%"; the foe's HP text shows a plain "N%", so require the sign.
        XCTAssertNotNil(text.range(of: "[-−–—]\\s*\(damage)\\s*%", options: .regularExpression),
                        "floating damage −\(damage)% not rendered. Seen: \(text)")
        assertPopoverSized(host)
    }

    /// No spoilers: the engine's view already lists the opponent's move once the step ran, but its chip must
    /// wait for the opponent's beat. Quick Attack has priority, so Pikachu's beat always plays first, and it
    /// does not knock Magikarp out, so Magikarp acts in the same step.
    func testOpponentMoveChipWaitsForItsBeat() async throws {
        let session = makeSession(Self.stagedState())
        session.mode = .manual
        session.start()
        let slot = try XCTUnwrap(session.battle?.request.moves.first { $0.id == "quickattack" }?.slot,
                                 "Pikachu must offer Quick Attack")
        session.choose(slot: slot)
        XCTAssertEqual(session.battle?.view?.p2.moves.isEmpty, false, "the engine view is ahead of the playback")
        XCTAssertEqual(session.playback?.beat?.actor, .player, "the priority move plays first")
        XCTAssertEqual(session.playback?.beat?.moveID, "quickattack")

        let host = host(session)
        let (text, _) = try await waitForText(["Quick Attack", "Ability"], in: host)
        assertRendered(["Quick Attack"], in: text)
        // artwork: false renders identifiers; none of Magikarp's moves may show while Pikachu's beat plays.
        // Pikachu's own "Volt Tackle" card also contains "tackle", so that one is counted apart.
        let seen = Self.normalized(text)
        func count(_ needle: String) -> Int { seen.components(separatedBy: needle).count - 1 }
        for move in ["splash", "flail", "bounce"] {
            XCTAssertEqual(count(move), 0, "\(move) revealed before its beat. Seen: \(text)")
        }
        XCTAssertEqual(count("tackle"), count("volttackle"), "Tackle revealed before its beat. Seen: \(text)")
    }

    /// Finished: the board gives way to the result only after the last beat, and the result card shows
    /// the finishing move and the damage totals.
    func testFinishedStagedBattleShowsFinisherAndDamage() async throws {
        let session = makeSession(Self.stagedState())
        try chooseVoltTackle(session)
        for _ in 0..<120 where session.battle?.phase != .finished || session.playback?.isPlaying != false {
            now += 0.5
            session.tick()
        }
        XCTAssertEqual(session.battle?.phase, .finished, "Volt Tackle knocks Magikarp out in one turn")
        XCTAssertEqual(session.playback?.isPlaying, false, "the playback must finish within the bounded loop")
        let summary = session.playback?.summary
        XCTAssertEqual(summary?.finishingMoveID, "volttackle")
        let dealt = summary?.damageDealtPercent ?? 0
        XCTAssertGreaterThan(dealt, 0, "the summary counts the damage dealt")

        let host = host(session)
        let needles = ["Victory", "Finishing move", "Volt Tackle", "Damage dealt", "\(dealt)%", "Rematch"]
        let (text, bitmap) = try await waitForText(needles, in: host)
        try save(bitmap, as: "practice-popover-result.png")
        assertRendered(needles, in: text)
        XCTAssertTrue(session.resultSeen, "the result screen reports it was shown")
        assertPopoverSized(host)
    }

    // MARK: Decision hints

    /// Selection: the matchup card under the selected opponent names the super-effective hit (Thunderbolt and
    /// Volt Tackle are ×2 on Magikarp) and who moves first, with both public Speed stats.
    func testSelectionShowsMatchupHints() async throws {
        let session = makeSession(Self.stagedState())
        XCTAssertEqual(session.player?.snapshot?.set.speciesNum, 25, "Pikachu is the default entry")
        XCTAssertEqual(session.opponent?.snapshot?.set.speciesNum, 129, "Magikarp is the default opponent")
        let mine = try XCTUnwrap(session.player?.snapshot?.publicInfo.stats["spe"])
        let theirs = try XCTUnwrap(session.opponent?.snapshot?.publicInfo.stats["spe"])
        let host = host(session)
        // The stat bars show both numbers too, but never joined by "vs": only the speed line reads "98 vs 88".
        let needles = ["\(mine) vs \(theirs)", "Start battle"]
        let (text, bitmap) = try await waitForText(needles, in: host)
        try save(bitmap, as: "practice-popover-matchup.png")
        assertRendered(needles, in: text)
        assertMultiplier("2", in: text)
        assertPopoverSized(host)
    }

    /// A multiplier ("×2", often read as "x2") as a word of its own. A substring check would also pass on the
    /// speed control's "1× 2×", which joins into "1x2x" once spaces are dropped.
    private func assertMultiplier(_ value: String, in text: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNotNil(text.range(of: "(^|\\s)[x×]\\s?\(value)(\\s|$)", options: [.regularExpression, .caseInsensitive]),
                        "×\(value) not rendered. Seen: \(text)", file: file, line: line)
    }

    /// Manual battle: every move card carries its power line, and the cards add the matchup badge, STAB and
    /// priority markers (Thunderbolt and Volt Tackle are super effective STAB moves; Quick Attack has priority).
    func testBattleMoveCardsShowPowerEffectivenessAndMarkers() async throws {
        let session = makeSession(Self.stagedState())
        session.mode = .manual
        session.start()
        XCTAssertEqual(session.battle?.phase, .running)
        let host = host(session)
        let needles = ["Pow 90", "STAB", "Priority", "Quick Attack", "Forfeit"]
        let (text, bitmap) = try await waitForText(needles, in: host)
        try save(bitmap, as: "practice-popover-hints.png")
        assertRendered(needles, in: text)
        assertMultiplier("2", in: text)
        assertPopoverSized(host)
    }

    /// Automatic battle: the speed control and "Skip to result" sit in the bottom bar, and skipping plays the
    /// rest of the battle at once so the result screen follows.
    func testAutomaticBattleOffersSpeedControlAndSkipToResult() async throws {
        let session = makeSession(Self.stagedState())
        session.mode = .automatic
        session.start()
        XCTAssertEqual(session.battle?.phase, .running)
        let host = host(session)
        let needles = ["2×", "Skip to result", "Forfeit"]
        let (text, _) = try await waitForText(needles, in: host)
        assertRendered(needles, in: text)
        assertPopoverSized(host)

        session.skipToResult()
        XCTAssertEqual(session.battle?.phase, .finished, "skipping plays the battle to its end")
        XCTAssertNotEqual(session.playback?.isPlaying, true, "nothing is left to stage")
        let result = ["Rematch", "New opponent"]
        let (after, _) = try await waitForText(result, in: host)
        assertRendered(result, in: after)
        XCTAssertTrue(session.resultSeen, "the result screen reports it was shown")
    }
}
