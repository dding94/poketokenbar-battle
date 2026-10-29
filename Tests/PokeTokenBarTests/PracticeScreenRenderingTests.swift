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

    /// The selection screen searches wild opponents on appear. Tests never reach PokéAPI: by default the search
    /// fails as if offline, which keeps the owned-opponent tests on their own data with a compact wild section.
    private func makeSession(_ state: CompanionState = syntheticState(),
                             wildSource: PracticeWildSource = PracticeWildSource(provider: OfflineWildProvider(),
                                                                                 details: OfflineWildProvider())) -> PracticeSession {
        let session = PracticeSession(engineURL: Self.engineURL, clock: { self.now }, drivesAutomatically: false,
                                      wildSource: wildSource, wildSeed: { 0x5EED })
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

    /// Renders at twice the point size. Display-less CI runners cache at 1x, where captions are a few pixels
    /// tall and Vision misreads them differently per macOS ("your" as "vour", "Pow 60" garbled on macOS 14).
    private func capture(_ host: NSView) throws -> NSBitmapImageRep {
        try Self.capture2x(host)
    }

    static func capture2x(_ host: NSView) throws -> NSBitmapImageRep {
        host.layoutSubtreeIfNeeded()
        let size = host.bounds.size
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = size
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
    /// sign reads as a letter x as often as not, so "×2" and "x2" are the same needle. Thin glyphs collapse
    /// too: CI read "Iron Tail" as "Iron Tall", so i, l, 1 and | compare equal. Dashes read as hyphens, so the
    /// level range "Lv.47–53" matches however its en dash is recognized.
    private static func normalized(_ text: String) -> String {
        String(text.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "×", with: "x").lowercased()
            .map { "l1|".contains($0) ? "i" : "–—−".contains($0) ? "-" : $0 })
    }

    /// Segment titles of the speed control, read from the AppKit control behind the SwiftUI picker. CI's
    /// Vision missed the small "2×" segment while reading its neighbors, so the control is checked directly.
    private func segmentLabels(in view: NSView) -> [String] {
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
        return descendants(view).compactMap { $0 as? NSSegmentedControl }
            .flatMap { control in (0..<control.segmentCount).compactMap { control.label(forSegment: $0) } }
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
        // The level sits next to a Korean name that en-US Vision mangles ("Lv.50" read as "#5450"), so the level
        // is asserted by data and OCR only checks that a level label renders.
        XCTAssertEqual(session.player?.snapshot?.set.level, 50)
        let needles = ["Lv.", "Start battle", "30", "200"]   // level label, CTA, manual timer, rules caption
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
        // The badge is white on the strong tint, which macOS 14's Vision cannot read even at 2x. Its data is
        // asserted here and its wording in PracticeWordingTests; OCR checks it where Vision can read it.
        XCTAssertEqual(session.moveHint("thunderbolt")?.multiplier, 2)
        if ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)) {
            assertMultiplier("2", in: text)
        }
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
        let needles = ["Skip to result", "Forfeit"]
        let (text, _) = try await waitForText(needles, in: host)
        assertRendered(needles, in: text)
        XCTAssertTrue(segmentLabels(in: host).contains("2×"), "speed segments: \(segmentLabels(in: host))")
        assertPopoverSized(host)

        session.skipToResult()
        XCTAssertEqual(session.battle?.phase, .finished, "skipping plays the battle to its end")
        XCTAssertNotEqual(session.playback?.isPlaying, true, "nothing is left to stage")
        let result = ["Rematch", "New opponent"]
        let (after, _) = try await waitForText(result, in: host)
        assertRendered(result, in: after)
        XCTAssertTrue(session.resultSeen, "the result screen reports it was shown")
    }

    // MARK: Review findings (hint UI)

    /// Hosts any view offscreen at a fixed size, closing the previous window first.
    private func hostView<V: View>(_ view: V, width: CGFloat, height: CGFloat) -> NSView {
        window?.close()
        let host = NSHostingView(rootView: view
            .frame(width: width, height: height, alignment: .topLeading)
            .background(Color.white)
            .environment(\.colorScheme, .light))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.orderFront(nil)
        self.window = window
        return host
    }

    /// The width of one move card: the board's two flexible columns with 8pt between them.
    private static var moveCardWidth: CGFloat { (PopoverMetrics.contentWidth - 8) / 2 }

    /// The body under the top bar is `.frame(height: 520)` (`PracticeScreen.bodyHeight`), so the screen's
    /// `fittingSize` stays 610 whatever the board needs: only the board's own height shows an overflow.
    private static let boardBodyHeight: CGFloat = 520

    /// Matchup card wording for every reach of the best hit, from the strongest to none at all. Before the
    /// fix a resisted or immune best fell into "Best hit: …", and a player with no damaging move read
    /// "No move hits a weak spot", which hides that the battle cannot be won.
    func testMatchupCardWordsEveryOffenseCase() async throws {
        let session = makeSession(Self.stagedState())
        let snapshot = try XCTUnwrap(session.player?.snapshot)
        func matchup(_ best: Double, _ moves: [String]) -> PracticeMatchup {
            PracticeMatchup(bestOffense: best, bestMoveIDs: moves, threat: 1, order: .playerFirst,
                            playerSpeed: 98, opponentSpeed: 88, levelGap: 0)
        }
        let cases: [(name: String, matchup: PracticeMatchup, needles: [String], absent: [String])] = [
            ("strong", matchup(2, ["thunderbolt", "volttackle"]), ["Weak spot", "Thunderbolt", "Volt Tackle"], ["draw"]),
            ("neutral", matchup(1, []), ["No move hits a weak spot"], ["draw"]),
            ("resisted", matchup(0.5, ["irontail"]), ["Every attack is resisted", "Iron Tail"], ["Best hit", "draw"]),
            ("immune", matchup(0, ["thunderbolt", "volttackle"]), ["None of your attacks land", "may end in a draw"],
             ["Best hit", "Thunderbolt"]),
            ("no attacks", matchup(0, []), ["No attacking moves", "may end in a draw"], ["weak spot"]),
        ]
        for item in cases {
            let card = PracticeMatchupCard(matchup: item.matchup, playerSnapshot: snapshot, playerLevel: 50,
                                           opponentLevel: 50, l: L(.en), artwork: false)
            let host = hostView(card.padding(8), width: PopoverMetrics.contentWidth, height: 120)
            let (text, bitmap) = try await waitForText(item.needles, in: host)
            try save(bitmap, as: "practice-matchup-\(item.name.replacingOccurrences(of: " ", with: "-")).png")
            for needle in item.needles {
                XCTAssertTrue(Self.normalized(text).contains(Self.normalized(needle)),
                              "\(item.name): \(needle) not rendered. Seen: \(text)")
            }
            for needle in item.absent {
                XCTAssertFalse(Self.normalized(text).contains(Self.normalized(needle)),
                               "\(item.name): \(needle) must not render. Seen: \(text)")
            }
        }
    }

    /// Seismic Toss deals damage by level: its card says so instead of a power, keeping accuracy and
    /// category. Hidden Power's type varies, so it has no matchup badge and a "Varies" marker instead.
    func testMoveCardsShowFixedDamageAndVariableType() async throws {
        let toss = PracticeMoveInfo(id: "seismictoss", name: "Seismic Toss", type: "Fighting", category: "Physical",
                                    basePower: 0, accuracy: 100, priority: 0, pp: 20, fixedDamage: true, variableType: false)
        let power = PracticeMoveInfo(id: "hiddenpower", name: "Hidden Power", type: "Normal", category: "Special",
                                     basePower: 60, accuracy: 100, priority: 0, pp: 15, fixedDamage: false, variableType: true)
        let cards = VStack(spacing: 8) {
            PracticeMoveCard(move: BattleMove(slot: 1, id: "seismictoss", name: "Seismic Toss", type: "Fighting",
                                              pp: 20, maxpp: 20, disabled: false),
                             key: 1, snapshot: nil, hint: PracticeMoveHint(info: toss, multiplier: 1, stab: false),
                             l: L(.en), artwork: false, locked: false, action: {})
            PracticeMoveCard(move: BattleMove(slot: 2, id: "hiddenpower", name: "Hidden Power", type: "Normal",
                                              pp: 15, maxpp: 15, disabled: false),
                             key: 2, snapshot: nil, hint: PracticeMoveHint(info: power, multiplier: nil, stab: false),
                             l: L(.en), artwork: false, locked: false, action: {})
        }
        let host = hostView(cards.frame(width: Self.moveCardWidth).padding(8),
                            width: Self.moveCardWidth + 16, height: 150)
        let needles = ["Fixed damage", "Acc 100", "Varies", "Pow 60"]
        let (text, bitmap) = try await waitForText(needles, in: host)
        try save(bitmap, as: "practice-cards-fixed-variable.png")
        assertRendered(needles, in: text)
    }

    /// FIGHTING + STAB + Priority + "PP 30/30" (Mach Punch on a Fighting type) is the widest English badge
    /// row; it overflowed its column by ~7pt because every `ViewThatFits` alternative kept both markers.
    /// The card must fit the width the grid proposes.
    func testWidestEnglishMoveCardFitsItsColumn() {
        let info = PracticeMoveInfo(id: "machpunch", name: "Mach Punch", type: "Fighting", category: "Physical",
                                    basePower: 40, accuracy: 100, priority: 1, pp: 30, fixedDamage: false, variableType: false)
        for lang in [AppLanguage.en, .ko] {
            let card = PracticeMoveCard(move: BattleMove(slot: 1, id: "machpunch", name: "Mach Punch", type: "Fighting",
                                                         pp: 30, maxpp: 30, disabled: false),
                                        key: 1, snapshot: nil, hint: PracticeMoveHint(info: info, multiplier: 2, stab: true),
                                        l: L(lang), artwork: false, locked: false, action: {})
            let size = NSHostingController(rootView: card)
                .sizeThatFits(in: CGSize(width: Self.moveCardWidth, height: .greatestFiniteMagnitude))
            XCTAssertLessThanOrEqual(size.width, Self.moveCardWidth + 0.5,
                                     "\(lang.rawValue): the card overflows its \(Self.moveCardWidth)pt column")
        }
    }

    /// The board's worst case must fit the 520pt body: English, the foe's four moves and ability revealed
    /// (the chips wrap to two lines), an engine notice, a beat with three callouts, and the bottom bar with
    /// the speed row in automatic mode. Measured on the board alone, since the screen's frame hides overflow.
    func testBattleBoardWorstCaseFitsTheBody() throws {
        // Three moves, so slot 4 is a valid number the engine rejects: that sets the notice.
        let state = Self.syntheticState(pikachu: ["thunderbolt", "quick-attack", "volt-tackle"],
                                        magikarp: ["splash", "tackle", "flail", "bounce"])
        for withBeat in [true, false] {
            let session = makeSession(state)
            session.mode = .manual
            session.start()
            let battle = try XCTUnwrap(session.battle)
            let playback = try XCTUnwrap(session.playback)
            playback.skipToEnd()
            session.tick()
            session.choose(slot: 4)
            XCTAssertNotNil(battle.notice, "an empty slot is rejected with a notice")
            playback.enqueue([.turn(2), .move(.opponent, moveID: "splash"), .move(.opponent, moveID: "tackle"),
                              .abilityRevealed(.opponent, abilityID: "swiftswim"),
                              .move(.opponent, moveID: "flail"), .move(.opponent, moveID: "bounce")])
            playback.skipToEnd()
            if withBeat {
                playback.enqueue([.turn(3), .move(.player, moveID: "thunderbolt"),
                                  .damage(.opponent, hp: 40, maxHP: 100, cause: nil),
                                  .superEffective(.opponent), .critical(.opponent), .status(.opponent, code: "par")])
                XCTAssertEqual(playback.beat?.callouts.count, 3, "the beat on screen carries three callouts")
            }
            session.mode = .automatic
            XCTAssertEqual(battle.phase, .running)

            let board = PracticeBattleBoard(session: session, battle: battle, l: L(.en), artwork: false)
            let host = hostView(board, width: PopoverMetrics.contentWidth, height: Self.boardBodyHeight)
            let measured = NSHostingView(rootView: board.frame(width: PopoverMetrics.contentWidth))
            host.addSubview(measured)
            let height = measured.fittingSize.height
            XCTAssertLessThanOrEqual(height, Self.boardBodyHeight,
                                     "board (beat on screen: \(withBeat)) needs \(height)pt of a \(Self.boardBodyHeight)pt body")
            if !withBeat, let bitmap = try? capture(host) { try save(bitmap, as: "practice-board-worst-case.png") }
        }
    }

    // MARK: Wild opponents

    /// Polls the session until `done` holds or 10 s pass; the search runs on its own task.
    private func waitForWild(_ session: PracticeSession, until done: (PracticeWildState) -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !done(session.wildState), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private static func isWild(_ candidate: PracticeCandidate) -> Bool {
        if case .wild = candidate.origin { return true }
        return false
    }

    /// Ready: the wild section heads the opponent list with the player's level ±3 (Pikachu is Lv.50) and a
    /// reroll button, lists three in-memory candidates from the hatch rule, and a selected wild row expands
    /// into the stat comparison and the matchup card like an owned one.
    func testSelectionShowsLevelMatchedWildOpponents() async throws {
        let session = makeSession(Self.stagedState(),
                                  wildSource: PracticeWildSource(provider: WildLineProvider(), details: WildLineProvider()))
        XCTAssertEqual(session.player?.snapshot?.set.level, 50, "Pikachu is the Lv.50 entry")
        session.findWildOpponents()
        try await waitForWild(session) { $0 == .ready }
        XCTAssertEqual(session.wildState, .ready, "the stubbed search must finish offline")
        XCTAssertEqual(session.wildCandidates.count, 3, "three wild opponents are offered")
        for candidate in session.wildCandidates {
            XCTAssertTrue(Self.isWild(candidate), "\(candidate.name) must be marked wild")
            let level = candidate.snapshot?.set.level ?? 0
            XCTAssertTrue((47...53).contains(level), "\(candidate.name) Lv.\(level) is outside Lv.47–53")
            XCTAssertTrue((1...9).contains(candidate.snapshot?.set.speciesNum ?? 0), "only the stubbed lines hatch")
        }
        XCTAssertEqual(Set(session.wildCandidates.compactMap { $0.snapshot?.set.speciesNum }).count, 3,
                       "one wild opponent per species")
        XCTAssertFalse(session.roster?.candidates.contains { Self.isWild($0) } ?? true,
                       "wild opponents stay out of the roster")

        let wild = try XCTUnwrap(session.wildCandidates.first, "no wild opponent to select")
        session.opponentID = wild.id
        XCTAssertEqual(session.opponent?.id, wild.id, "the session resolves a wild opponent")
        XCTAssertNotNil(session.matchup, "a wild pairing has a matchup")
        let mine = try XCTUnwrap(session.player?.snapshot?.publicInfo.stats["spe"])
        let theirs = try XCTUnwrap(wild.snapshot?.publicInfo.stats["spe"])

        let host = host(session)
        // The header carries the range; the selected wild row's matchup card carries the speed line.
        let needles = ["Wild opponents", "Lv.47–53", "Reroll", "\(mine) vs \(theirs)", "Start battle"]
        let (text, bitmap) = try await waitForText(needles, in: host)
        try save(bitmap, as: "practice-popover-wild.png")
        assertRendered(needles, in: text)
        assertPopoverSized(host)
    }

    /// Searching: a compact progress row under the wild header while the search is in flight.
    func testWildSearchShowsProgressRow() async throws {
        let session = makeSession(wildSource: PracticeWildSource(provider: StalledWildProvider(),
                                                                 details: StalledWildProvider()))
        session.findWildOpponents()
        XCTAssertEqual(session.wildState, .searching, "the search is in flight")
        let host = host(session)
        let needles = ["Wild opponents", "Finding opponents"]
        let (text, bitmap) = try await waitForText(needles, in: host)
        try save(bitmap, as: "practice-popover-wild-searching.png")
        assertRendered(needles, in: text)
        XCTAssertTrue(session.wildCandidates.isEmpty)
        assertPopoverSized(host)
    }

    /// Unavailable: when not a single opponent can be made (offline, nothing cached), the section says so and
    /// offers a retry; the owned opponents below keep their header and stay selectable.
    func testWildSearchFailureOffersRetry() async throws {
        let session = makeSession()
        session.findWildOpponents()
        try await waitForWild(session) { if case .unavailable = $0 { true } else { false } }
        var unavailable = false
        if case .unavailable = session.wildState { unavailable = true }
        XCTAssertTrue(unavailable, "an offline search ends unavailable, not \(session.wildState)")
        XCTAssertTrue(session.wildCandidates.isEmpty)
        let host = host(session)
        let needles = ["Wild opponents", "Retry", "Your collection"]
        let (text, bitmap) = try await waitForText(needles, in: host)
        try save(bitmap, as: "practice-popover-wild-unavailable.png")
        assertRendered(needles, in: text)
        XCTAssertEqual(session.opponent?.snapshot?.set.speciesNum, 129, "the owned opponent stays selected")
        assertPopoverSized(host)
    }
}

// MARK: Wild stubs

/// Bulbasaur's line with Black 2/White 2 level-up moves and abilities, so the hatch rule picks base #1 and the
/// generator builds legal sets at any stage without the network.
/// Three starter lines (distinct species, so the generator's one-per-species rule can fill three rows) with
/// plausible B2W2 level-up moves the engine accepts.
private struct WildLineProvider: PokeProviding, PokemonDetailProviding {
    private struct Mon {
        let name: String, ko: String, types: [String], stats: [Int], abilities: [String], moves: [(String, Int)]
    }
    private static let lines: [Int: [Int]] = [1: [1, 2, 3], 4: [4, 5, 6], 7: [7, 8, 9]]
    private static let grass: [(String, Int)] = [("tackle", 1), ("growl", 3), ("leech-seed", 7), ("vine-whip", 9),
        ("poison-powder", 13), ("sleep-powder", 13), ("take-down", 15), ("razor-leaf", 19), ("sweet-scent", 21),
        ("growth", 25), ("double-edge", 27), ("worry-seed", 31), ("synthesis", 33), ("seed-bomb", 37), ("solar-beam", 44)]
    private static let fire: [(String, Int)] = [("scratch", 1), ("growl", 1), ("ember", 7), ("smokescreen", 10),
        ("scary-face", 19), ("fire-fang", 25), ("slash", 34), ("flamethrower", 37), ("fire-spin", 43), ("inferno", 46)]
    private static let water: [(String, Int)] = [("tackle", 1), ("tail-whip", 4), ("water-gun", 7), ("withdraw", 10),
        ("bite", 16), ("rapid-spin", 19), ("protect", 22), ("water-pulse", 25), ("aqua-tail", 28),
        ("iron-defense", 34), ("rain-dance", 37), ("hydro-pump", 40)]
    private static let mons: [Int: Mon] = [
        1: Mon(name: "bulbasaur", ko: "이상해씨", types: ["grass", "poison"], stats: [45, 49, 49, 65, 65, 45],
               abilities: ["overgrow", "chlorophyll"], moves: grass),
        2: Mon(name: "ivysaur", ko: "이상해풀", types: ["grass", "poison"], stats: [60, 62, 63, 80, 80, 60],
               abilities: ["overgrow", "chlorophyll"], moves: grass),
        3: Mon(name: "venusaur", ko: "이상해꽃", types: ["grass", "poison"], stats: [80, 82, 83, 100, 100, 80],
               abilities: ["overgrow", "chlorophyll"], moves: grass),
        4: Mon(name: "charmander", ko: "파이리", types: ["fire"], stats: [39, 52, 43, 60, 50, 65],
               abilities: ["blaze", "solar-power"], moves: fire),
        5: Mon(name: "charmeleon", ko: "리자드", types: ["fire"], stats: [58, 64, 58, 80, 65, 80],
               abilities: ["blaze", "solar-power"], moves: fire),
        6: Mon(name: "charizard", ko: "리자몽", types: ["fire", "flying"], stats: [78, 84, 78, 109, 85, 100],
               abilities: ["blaze", "solar-power"], moves: fire),
        7: Mon(name: "squirtle", ko: "꼬부기", types: ["water"], stats: [44, 48, 65, 50, 64, 43],
               abilities: ["torrent", "rain-dish"], moves: water),
        8: Mon(name: "wartortle", ko: "어니부기", types: ["water"], stats: [59, 63, 80, 65, 80, 58],
               abilities: ["torrent", "rain-dish"], moves: water),
        9: Mon(name: "blastoise", ko: "거북왕", types: ["water"], stats: [79, 83, 100, 85, 105, 78],
               abilities: ["torrent", "rain-dish"], moves: water),
    ]

    func line(baseSpeciesID: Int) async throws -> EvoLine {
        guard let ids = Self.lines[baseSpeciesID] else { throw URLError(.fileDoesNotExist) }
        let tree = EvoNode(speciesID: ids[0], children: [EvoNode(speciesID: ids[1], children: [EvoNode(speciesID: ids[2], children: [])])])
        let names = Dictionary(uniqueKeysWithValues: ids.map { id in (id, ["en": Self.mons[id]!.name.capitalized, "ko": Self.mons[id]!.ko]) })
        return EvoLine(baseID: ids[0], tree: tree, rarity: .rare, names: names)
    }
    func baseSpeciesIndex() async throws -> [BaseSpecies] { [1, 4, 7].map { BaseSpecies(id: $0, captureRate: 45) } }
    func baseSpecies(id: Int) async throws -> BaseSpecies? { Self.lines[id] == nil ? nil : BaseSpecies(id: id, captureRate: 45) }
    func pokemonDetails(speciesID: Int) async throws -> PokemonDetails {
        guard let mon = Self.mons[speciesID] else { throw URLError(.fileDoesNotExist) }
        let keys = ["hp", "attack", "defense", "special-attack", "special-defense", "speed"]
        return PokemonDetails(
            speciesID: speciesID, name: mon.name, height: 7, weight: 69, baseExperience: 64, genderRate: 1,
            types: mon.types, baseStats: Dictionary(uniqueKeysWithValues: zip(keys, mon.stats)),
            abilities: [PokemonAbilityOption(name: mon.abilities[0], slot: 1, isHidden: false),
                        PokemonAbilityOption(name: mon.abilities[1], slot: 3, isHidden: true)],
            moves: mon.moves.map { PokemonMoveOption(name: $0.0, learnMethods: [PokemonMoveLearnMethod(method: "level-up", level: $0.1)]) })
    }
}

/// Offline with nothing cached: every lookup fails, so not a single wild opponent can be made.
private struct OfflineWildProvider: PokeProviding, PokemonDetailProviding {
    func line(baseSpeciesID: Int) async throws -> EvoLine { throw URLError(.notConnectedToInternet) }
    func baseSpeciesIndex() async throws -> [BaseSpecies] { throw URLError(.notConnectedToInternet) }
    func baseSpecies(id: Int) async throws -> BaseSpecies? { throw URLError(.notConnectedToInternet) }
    func pokemonDetails(speciesID: Int) async throws -> PokemonDetails { throw URLError(.notConnectedToInternet) }
}

/// A search that never answers, so the screen stays on its progress row; a newer search cancels it.
private struct StalledWildProvider: PokeProviding, PokemonDetailProviding {
    private func stall<T>() async throws -> T {
        try await Task.sleep(for: .seconds(3600))
        throw CancellationError()
    }
    func line(baseSpeciesID: Int) async throws -> EvoLine { try await stall() }
    func baseSpeciesIndex() async throws -> [BaseSpecies] { try await stall() }
    func baseSpecies(id: Int) async throws -> BaseSpecies? { try await stall() }
    func pokemonDetails(speciesID: Int) async throws -> PokemonDetails { try await stall() }
}
