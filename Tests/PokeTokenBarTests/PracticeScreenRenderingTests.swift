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
    /// level range "Lv.47–53" matches however its en dash is recognized. Apostrophes are dropped: "Today's"
    /// comes back straight, curly or missing.
    private static func normalized(_ text: String) -> String {
        String(text.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "×", with: "x").lowercased()
            .filter { !"'’‘`".contains($0) }
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

    /// Selection: my entry with its level, the opponent list, the manual mode with the practice turn limit and a
    /// start button.
    func testSelectionShowsContendersModeAndStartButton() async throws {
        let session = makeSession()
        XCTAssertEqual(session.roster?.eligible.count, 2, "the synthetic save holds two eligible Pokémon")
        XCTAssertNil(session.battle)
        let host = host(session)
        // The level sits next to a Korean name that en-US Vision mangles ("Lv.50" read as "#5450"), so the level
        // is asserted by data and OCR only checks that a level label renders.
        XCTAssertEqual(session.player?.snapshot?.set.level, 50)
        // level label, CTA, manual timer, rules caption
        let needles = ["Lv.", "Start battle", "\(PracticeBattle.manualTurnSeconds)s per turn", "200"]
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
        let seconds = try XCTUnwrap(session.battle?.remainingSeconds)
        let host = host(session)
        // artwork: false renders move identifiers, so Pikachu's only move reads "Thunderbolt". The clock shows
        // whatever limit Core gives a practice turn.
        let needles = ["Thunderbolt", "PP", "Turn 1", "\(seconds)s", "Forfeit"]
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
    /// Volt Tackle are ×2 on Magikarp) and who moves first, with both public Speed stats. The record line and
    /// today's opponent sit above the list, so the card is read off the list at full height (`hostFullList`).
    func testSelectionShowsMatchupHints() async throws {
        let session = makeSession(Self.stagedState())
        XCTAssertEqual(session.player?.snapshot?.set.speciesNum, 25, "Pikachu is the default entry")
        XCTAssertEqual(session.opponent?.snapshot?.set.speciesNum, 129, "Magikarp is the default opponent")
        let mine = try XCTUnwrap(session.player?.snapshot?.publicInfo.stats["spe"])
        let theirs = try XCTUnwrap(session.opponent?.snapshot?.publicInfo.stats["spe"])
        let host = host(session)
        let (_, popover) = try await waitForText(["Start battle"], in: host)
        try save(popover, as: "practice-popover-matchup.png")
        assertPopoverSized(host)
        // The stat bars show both numbers too, but never joined by "vs": only the speed line reads "98 vs 88".
        let needles = ["\(mine) vs \(theirs)", "Start battle"]
        let (text, bitmap) = try await waitForText(needles, in: hostFullList(session))
        try save(bitmap, as: "practice-selection-matchup-full.png")
        assertRendered(needles, in: text)
        assertMultiplier("2", in: text)
    }

    /// Height that shows the whole selection list without scrolling, with a selected row's stats and matchup open.
    private static let fullListHeight: CGFloat = 1100

    /// The selection list with the session's own progress, as `PracticeScreen` builds it, at full height. The
    /// popover's 520pt body scrolls to a selected row below the fold; here every row is on screen.
    private func hostFullList(_ session: PracticeSession) -> NSView {
        hostView(PracticeSelectionView(session: session, progress: PracticeSelectionProgress(session), l: L(.en), artwork: false),
                 width: PopoverMetrics.contentWidth, height: Self.fullListHeight)
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
        // The header carries the range; the selected wild row's matchup card carries the speed line, which today's
        // opponent above can push below the fold, so it is read off the full list.
        let needles = ["Wild opponents", "Lv.47–53", "Reroll", "Start battle"]
        let (text, bitmap) = try await waitForText(needles, in: host)
        try save(bitmap, as: "practice-popover-wild.png")
        assertRendered(needles, in: text)
        assertPopoverSized(host)
        let speed = ["\(mine) vs \(theirs)"]
        let (listText, _) = try await waitForText(speed, in: hostFullList(session))
        assertRendered(speed, in: listText)
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

    /// The board shows the pair the battle was started with, not the selection. A wild search finishing
    /// mid-battle can replace the selection while the engine keeps fighting the first foe; a direct
    /// `opponentID` write stands in for that async writer, since `dropIdleBattle` keeps a running battle.
    /// Checked on the side cards' data: the wild names are Korean and the tag is tiny tinted text, both
    /// outside what Vision reads reliably (defect-log, Vision OCR).
    func testBattleBoardKeepsTheStartedPairWhenTheSelectionChanges() async throws {
        let session = makeSession(Self.stagedState(),
                                  wildSource: PracticeWildSource(provider: WildLineProvider(), details: WildLineProvider()))
        session.findWildOpponents()
        try await waitForWild(session) { $0 == .ready }
        let wild = try XCTUnwrap(session.wildCandidates.first, "no wild opponent to fight")
        session.opponentID = wild.id
        session.mode = .manual
        session.start()
        let battle = try XCTUnwrap(session.battle)
        XCTAssertEqual(battle.phase, .running)
        let player = try XCTUnwrap(session.player)

        let owned = try XCTUnwrap(session.roster?.eligible.first { $0.id != player.id })
        session.opponentID = owned.id
        XCTAssertEqual(session.opponent?.id, owned.id, "the selection moved on to an owned Pokémon")
        XCTAssertTrue(session.battle === battle, "a running battle survives a selection change")

        let view = try XCTUnwrap(battle.view)
        let board = PracticeBattleBoard(session: session, battle: battle, l: L(.en), artwork: false)
        let foe = board.sideCard(.opponent, view.p2)
        XCTAssertEqual(foe.name, wild.name, "the foe's name follows the battle, not the selection")
        XCTAssertEqual(foe.snapshot?.instanceID, wild.snapshot?.instanceID, "the foe's snapshot follows the battle")
        XCTAssertTrue(foe.wild, "the foe keeps its wild tag")
        XCTAssertNotNil(wild.temperament, "a wild opponent with a snapshot has a temperament")
        XCTAssertEqual(foe.temperament, wild.temperament, "the foe's temperament follows the battle")
        let mine = board.sideCard(.player, view.p1)
        XCTAssertEqual(mine.name, player.name)
        XCTAssertEqual(mine.snapshot?.instanceID, player.snapshot?.instanceID)
        XCTAssertNil(mine.temperament, "my own side runs no temperament")

        let host = host(session)
        let (_, bitmap) = try await waitForText(["Forfeit"], in: host)
        try save(bitmap, as: "practice-popover-wild-battle.png")
    }

    /// The selection searches whenever a search is due, not on particular transitions. A search released
    /// with the popover leaves `.idle` and the old player; if the screen appears before `prepare` (no player
    /// yet) and `prepare` then re-assigns that same player, no player or state change fires. The real popover
    /// happens to run `prepare` first (`PopoverPracticeRoutingTests` covers that path), so this forces the
    /// order that left "Finding opponents…" on screen forever with no spinner and no retry.
    func testSelectionSearchesOnceAPlayerArrivesAfterARelease() async throws {
        let session = PracticeSession(engineURL: Self.engineURL, clock: { self.now }, drivesAutomatically: false,
                                      wildSource: PracticeWildSource(provider: StalledWildProvider(),
                                                                     details: StalledWildProvider()),
                                      wildSeed: { 0x5EED })
        let state = Self.syntheticState()
        session.prepare(state: state, activeName: nil)
        session.findWildOpponents()
        XCTAssertEqual(session.wildState, .searching)
        session.releaseIfIdle()
        XCTAssertEqual(session.wildState, .idle, "releasing cancels the search in flight")
        XCTAssertNil(session.player, "the roster went with the engine")

        let host = host(session)
        _ = try await waitForText(["Start battle"], in: host)
        XCTAssertEqual(session.wildState, .idle, "no player yet, so nothing to search for")
        let player = session.playerID
        session.prepare(state: state, activeName: nil)
        XCTAssertEqual(session.playerID, player, "the same player is re-assigned, so no player change fires")
        try await waitForWild(session) { $0 == .searching }
        XCTAssertEqual(session.wildState, .searching, "the screen must search once the player is back")
    }

    // MARK: Records, today's opponent and temperaments (03B-5)
    //
    // The session keeps its defaults until Core lands records and today's opponent, so these tests feed the new
    // views plain values: `PracticeSelectionProgress`, `PracticeRecordUpdate`, a hand-made daily candidate and
    // explicit temperaments. Tags and stars are too small or symbolic for Vision (defect-log, 표시·UI): they are
    // checked by size and pixels, and OCR reads only the caption-sized words.

    /// A candidate with a hand-made snapshot. Rows and cards read only its set and public types, so no engine runs.
    static func syntheticCandidate(id: String, name: String, species: Int, level: Int, types: [String],
                                   origin: PracticeOrigin = .owned) -> PracticeCandidate {
        let set = BattleSet(speciesNum: species, form: nil, level: level, gender: .male, nature: "adamant",
                            ability: "overgrow", moves: ["tackle"], ivs: [:], shiny: false)
        let info = BattlePublicInfo(speciesNum: species, species: name, level: level, types: types,
                                    stats: ["hp": 80, "atk": 82, "def": 83, "spa": 100, "spd": 100, "spe": 80])
        let snapshot = BattleSnapshot(schemaVersion: 1, instanceID: id, engineHash: "", rulesVersion: "",
                                      policyVersion: "", set: set, publicInfo: info)
        return PracticeCandidate(id: id, name: name, snapshot: snapshot, blockedReason: nil, origin: origin)
    }

    /// Today's opponent as Core hands it over: a wild candidate whose id carries the daily prefix.
    static var dailyCandidate: PracticeCandidate {
        syntheticCandidate(id: PracticeDaily.idPrefix + "2026-10-30", name: "이상해꽃", species: 3, level: 52,
                           types: ["Grass", "Poison"], origin: .wild(rarity: .rare, shiny: false))
    }

    /// 12 wins, 5 losses, a draw, a 3-win streak with a best of 7, and today's first star.
    static var sampleRecords: PracticeRecords {
        PracticeRecords(wins: 12, losses: 5, draws: 1, streak: 3, bestStreak: 7, dailyDay: "2026-10-30", dailyStars: [.win])
    }

    /// Room the result screen must leave for log lines. Its least height already holds the log card's title and
    /// padding (the scrolling lines shrink to nothing), so this is about three lines on top.
    private static let resultLogMinimum: CGFloat = 48

    /// Raw RGBA bytes of a capture, to tell two renders apart.
    private static func pixels(_ bitmap: NSBitmapImageRep) -> Data {
        guard let data = bitmap.bitmapData else { return Data() }
        return Data(bytes: data, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    }

    /// Saturated gold-to-orange pixels. Earned stars are drawn gold, which OCR cannot read; more earned stars
    /// draw more of it.
    private static func goldPixels(_ bitmap: NSBitmapImageRep) -> Int {
        guard let data = bitmap.bitmapData, bitmap.bitsPerPixel == 32 else { return 0 }
        var count = 0
        for y in 0..<bitmap.pixelsHigh {
            let row = data + y * bitmap.bytesPerRow
            for x in 0..<bitmap.pixelsWide {
                let r = row[x * 4], g = row[x * 4 + 1], b = row[x * 4 + 2]
                if r > 215, g > 120, g < 215, b < 90 { count += 1 }
            }
        }
        return count
    }

    /// Recognized lines with their boxes (Vision's normalized coordinates: a larger y is higher on screen).
    private func recognizedLines(_ bitmap: NSBitmapImageRep) throws -> [(text: String, box: CGRect)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage)).perform([request])
        return (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first.map { ($0.string, observation.boundingBox) }
        }
    }

    /// The record line: totals with the running streak and the best one; before any battle a first-time line
    /// instead of zeros.
    func testRecordsLineShowsTotalsStreakAndBest() async throws {
        let width = PopoverMetrics.scrollContentWidth
        let host = hostView(PracticeRecordsLine(records: Self.sampleRecords, l: L(.en)).padding(8), width: width, height: 40)
        let needles = ["12W 5L 1D", "3-win streak", "best 7"]
        let (text, bitmap) = try await waitForText(needles, in: host)
        try save(bitmap, as: "practice-records-line.png")
        assertRendered(needles, in: text)

        let first = hostView(PracticeRecordsLine(records: PracticeRecords(), l: L(.en)).padding(8), width: width, height: 40)
        let (firstText, _) = try await waitForText(["No record yet"], in: first)
        assertRendered(["No record yet"], in: firstText)
        XCTAssertFalse(Self.normalized(firstText).contains("0w"), "no zero totals before the first battle: \(firstText)")
    }

    /// What an empty hosting view reports as its fitting width (10pt, not 0), the baseline for "draws nothing".
    private static var emptyWidth: CGFloat { NSHostingView(rootView: EmptyView()).fittingSize.width }

    /// The record line stays one unscaled line with three-digit totals in both languages.
    func testRecordsLineFitsTheScrollColumn() {
        let records = PracticeRecords(wins: 999, losses: 999, draws: 99, streak: 99, bestStreak: 999)
        for lang in [AppLanguage.en, .ko] {
            let size = NSHostingView(rootView: PracticeRecordsLine(records: records, l: L(lang))).fittingSize
            XCTAssertGreaterThan(size.width, Self.emptyWidth + 100, "\(lang.rawValue): no record line: \(size)")
            XCTAssertLessThanOrEqual(size.width, PopoverMetrics.scrollContentWidth, "\(lang.rawValue): \(size)")
        }
    }

    /// The tag shows for every temperament in a width an opponent row can take, drops to its symbol when asked,
    /// and is not there at all without a temperament.
    func testTemperamentTagSizes() {
        let empty = Self.emptyWidth
        for lang in [AppLanguage.en, .ko] {
            for temperament in PracticeTemperament.allCases {
                let full = NSHostingView(rootView: PracticeTemperamentTag(temperament: temperament, l: L(lang))).fittingSize
                let compact = NSHostingView(rootView: PracticeTemperamentTag(temperament: temperament, l: L(lang),
                                                                             compact: true)).fittingSize
                XCTAssertGreaterThan(full.width, empty + 10, "\(lang.rawValue) \(temperament): no tag: \(full)")
                XCTAssertLessThanOrEqual(full.width, 80, "\(lang.rawValue) \(temperament): \(full)")
                XCTAssertLessThan(compact.width, full.width, "\(lang.rawValue) \(temperament): the compact tag keeps its word")
            }
        }
        // A nil body measures 0, below the empty view's 10.
        XCTAssertLessThanOrEqual(NSHostingView(rootView: PracticeTemperamentTag(temperament: nil, l: L(.en))).fittingSize.width,
                                 empty, "no temperament, no tag")
    }

    /// Owned, wild and today's rows are one row view, and it draws the temperament next to the types. The widest
    /// English rows still fit the scroll column: shiny, legendary, two long types, the wild tag and any temperament,
    /// and an owned row with its number.
    func testOpponentRowsDrawTheTemperamentAndFitTheColumn() async throws {
        let wild = Self.syntheticCandidate(id: "wild-widest", name: "Crabominable", species: 308, level: 100,
                                           types: ["Fighting", "Psychic"], origin: .wild(rarity: .legendary, shiny: true))
        let owned = Self.syntheticCandidate(id: "owned-widest", name: "Crabominable", species: 308, level: 100,
                                            types: ["Fighting", "Psychic"])
        let width = PopoverMetrics.scrollContentWidth
        for (candidate, number) in [(wild, nil), (owned, 12)] as [(PracticeCandidate, Int?)] {
            func row(_ temperament: PracticeTemperament?, _ lang: AppLanguage = .en) -> some View {
                PracticeOpponentRow(candidate: candidate, temperament: temperament, selected: false, number: number,
                                    l: L(lang), artwork: false, onSelect: {}) { EmptyView() }
            }
            let with = try Self.capture2x(hostView(row(.aggressive), width: width, height: 64))
            if number == nil { try save(with, as: "practice-row-temperament.png") }
            let without = try Self.capture2x(hostView(row(nil), width: width, height: 64))
            XCTAssertNotEqual(Self.pixels(with), Self.pixels(without), "\(candidate.id): the row draws no temperament")
            for lang in [AppLanguage.en, .ko] {
                for temperament in PracticeTemperament.allCases {
                    let size = NSHostingController(rootView: row(temperament, lang))
                        .sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
                    XCTAssertLessThanOrEqual(size.width, width + 0.5, "\(candidate.id) \(lang.rawValue) \(temperament): \(size)")
                }
            }
        }
        // The widest English row with the full word sits within a few points of the column (without the fallback it
        // measured 322pt of 320), and localized type names (artwork on) can be wider still: the temperament drops to
        // its symbol before the badges overflow, so the row also fits a column 24pt narrower.
        let narrow = width - 24
        let tight = NSHostingController(rootView: PracticeOpponentRow(candidate: wild, temperament: .aggressive, selected: false,
                                                                      l: L(.en), artwork: false, onSelect: {}) { EmptyView() })
            .sizeThatFits(in: CGSize(width: narrow, height: .greatestFiniteMagnitude))
        XCTAssertLessThanOrEqual(tight.width, narrow + 0.5, "the temperament must give way before the row overflows: \(tight)")
    }

    /// Today's opponent: the title, the three goals worded from their numbers with today's stars, and the
    /// opponent's row. Earned stars are gold, so more stars draw more gold; the card fits the column in both
    /// languages.
    func testDailyCardShowsGoalsStarsAndTheOpponent() async throws {
        func card(_ stars: Set<PracticeDailyGoal>, _ lang: AppLanguage = .en) -> some View {
            PracticeDailyCard(candidate: Self.dailyCandidate, state: .ready, stars: stars, l: L(lang), onRetry: {}) { candidate in
                PracticeOpponentRow(candidate: candidate, temperament: .tactical, selected: false, l: L(lang),
                                    artwork: false, onSelect: {}) { EmptyView() }
            }
        }
        let width = PopoverMetrics.scrollContentWidth
        let needles = ["Today's opponent", "Win within \(PracticeDailyGoal.quickTurns)", "HP left", "1/3"]
        let (text, bitmap) = try await waitForText(needles, in: hostView(card([.win]), width: width, height: 200))
        try save(bitmap, as: "practice-daily-card.png")
        assertRendered(needles, in: text)

        let none = Self.goldPixels(try Self.capture2x(hostView(card([]), width: width, height: 200)))
        let one = Self.goldPixels(try Self.capture2x(hostView(card([.win]), width: width, height: 200)))
        let all = Self.goldPixels(try Self.capture2x(hostView(card(Set(PracticeDailyGoal.allCases)), width: width, height: 200)))
        XCTAssertLessThan(none, one, "an earned star is drawn gold")
        XCTAssertLessThan(one, all, "every earned star is drawn gold")
        for lang in [AppLanguage.en, .ko] {
            let size = NSHostingController(rootView: card([.win], lang))
                .sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
            XCTAssertLessThanOrEqual(size.width, width + 0.5, "\(lang.rawValue): \(size)")
        }
    }

    /// While today's opponent is missing, its row's place says what the search is doing, like the wild notice:
    /// searching, or unavailable with a retry. The goals stay, so today's stars do not vanish with the network.
    func testDailyCardWithoutTheOpponentShowsTheSearchAndARetry() async throws {
        let width = PopoverMetrics.scrollContentWidth
        func card(_ state: PracticeWildState) -> some View {
            PracticeDailyCard(candidate: nil, state: state, stars: [.win], l: L(.en), onRetry: {}) { _ in EmptyView() }
        }
        let needles = ["Finding today's opponent", "Win within"]
        let (text, bitmap) = try await waitForText(needles, in: hostView(card(.searching), width: width, height: 160))
        try save(bitmap, as: "practice-daily-searching.png")
        assertRendered(needles, in: text)

        let failed = ["Couldn't find today's opponent", "Retry", "Win within"]
        let (failedText, failedBitmap) = try await waitForText(failed, in: hostView(card(.unavailable), width: width, height: 160))
        try save(failedBitmap, as: "practice-daily-unavailable.png")
        assertRendered(failed, in: failedText)
    }

    /// The selection screen with progress: the record line first, then my entry, then today's opponent above the
    /// wild ones, with the mode and the start button pinned at the bottom of the 520pt body. Sample progress
    /// until Core fills the session; the screen reads it only through `PracticeSelectionProgress`.
    func testSelectionShowsRecordsAndTodaysOpponentAboveTheWildOnes() async throws {
        let session = makeSession(Self.stagedState(),
                                  wildSource: PracticeWildSource(provider: WildLineProvider(), details: WildLineProvider()))
        session.findWildOpponents()
        try await waitForWild(session) { $0 == .ready }
        XCTAssertEqual(session.wildState, .ready, "the stubbed search must finish offline")
        let progress = PracticeSelectionProgress(records: Self.sampleRecords, daily: Self.dailyCandidate, dailyState: .ready)
        for lang in [AppLanguage.en, .ko] {
            let view = PracticeSelectionView(session: session, progress: progress, l: L(lang), artwork: false)
            let host = hostView(view, width: PopoverMetrics.contentWidth, height: Self.boardBodyHeight)
            guard lang == .en else {
                let (_, bitmap) = try await waitForText(["1/3"], in: host)
                try save(bitmap, as: "practice-step5-selection-ko.png")
                continue
            }
            let needles = ["12W 5L 1D", "3-win streak", "Today's opponent", "Win within", "Wild opponents", "Start battle"]
            let (text, bitmap) = try await waitForText(needles, in: host)
            try save(bitmap, as: "practice-step5-selection-en.png")
            assertRendered(needles, in: text)
            let lines = try recognizedLines(bitmap)
            func top(_ needle: String) throws -> CGFloat {
                try XCTUnwrap(lines.first { Self.normalized($0.text).contains(Self.normalized(needle)) }, needle).box.midY
            }
            XCTAssertGreaterThan(try top("3-win streak"), try top("Today's opponent"), "the record line leads")
            XCTAssertGreaterThan(try top("Today's opponent"), try top("Wild opponents"), "today's opponent sits above the wild ones")
        }
    }

    /// The result card words the streak change: continued, started and ended, and only today's opponent shows
    /// today's stars. The stars this battle earned are highlighted, which only pixels show.
    func testResultRecordWordsTheStreakAndHighlightsNewStars() async throws {
        func host(_ update: PracticeRecordUpdate) -> NSView {
            hostView(PracticeResultRecord(update: update, l: L(.en)), width: PopoverMetrics.contentWidth, height: 70)
        }
        let continued = PracticeRecordUpdate(outcome: .win, streak: 4, bestStreak: 4, endedStreak: nil, daily: true,
                                             newStars: [.quickWin], stars: [.win, .quickWin])
        let needles = ["4-win streak", "Today's stars"]
        let (text, bitmap) = try await waitForText(needles, in: host(continued))
        try save(bitmap, as: "practice-result-record.png")
        assertRendered(needles, in: text)

        let ended = PracticeRecordUpdate(outcome: .loss, streak: 0, bestStreak: 7, endedStreak: 7, daily: false,
                                         newStars: [], stars: [])
        let (endedText, _) = try await waitForText(["Streak ended at 7"], in: host(ended))
        assertRendered(["Streak ended at 7"], in: endedText)
        XCTAssertFalse(Self.normalized(endedText).contains(Self.normalized("Today's stars")),
                       "only today's opponent shows today's stars: \(endedText)")

        let started = PracticeRecordUpdate(outcome: .win, streak: 1, bestStreak: 7, endedStreak: nil, daily: false,
                                           newStars: [], stars: [])
        let (startedText, _) = try await waitForText(["Streak started"], in: host(started))
        assertRendered(["Streak started"], in: startedText)

        // The same stars, once all earned earlier and once partly by this battle: only the highlight differs.
        let earlier = PracticeRecordUpdate(outcome: .win, streak: 4, bestStreak: 4, endedStreak: nil, daily: true,
                                           newStars: [], stars: [.win, .quickWin])
        let fresh = try Self.capture2x(host(continued))
        let old = try Self.capture2x(host(earlier))
        XCTAssertNotEqual(Self.pixels(fresh), Self.pixels(old), "a star earned by this battle is highlighted")
    }

    /// The result screen with the record card fits its 520pt body in both languages: the card takes room from the
    /// log, never from the actions. Measured as the screen's least height (the log shrinks first) plus room for
    /// two log lines; in English the actions are also read off the rendered body.
    func testResultWithTheRecordCardFitsTheBody() async throws {
        let session = makeSession(Self.stagedState())
        try chooseVoltTackle(session)
        for _ in 0..<120 where session.battle?.phase != .finished || session.playback?.isPlaying != false {
            now += 0.5
            session.tick()
        }
        let battle = try XCTUnwrap(session.battle)
        XCTAssertEqual(battle.phase, .finished, "Volt Tackle knocks Magikarp out in one turn")
        let record = PracticeRecordUpdate(outcome: .win, streak: 4, bestStreak: 4, endedStreak: nil, daily: true,
                                          newStars: [.quickWin, .healthyWin], stars: Set(PracticeDailyGoal.allCases))
        let width = PopoverMetrics.contentWidth
        for lang in [AppLanguage.en, .ko] {
            func least(_ record: PracticeRecordUpdate?) -> CGFloat {
                let view = PracticeResultView(session: session, battle: battle, record: record, l: L(lang), artwork: false)
                return NSHostingController(rootView: view.frame(width: width))
                    .sizeThatFits(in: CGSize(width: width, height: 0)).height
            }
            let with = least(record), bare = least(nil)
            XCTAssertGreaterThan(with, bare, "\(lang.rawValue): the record card is on the result screen")
            XCTAssertLessThanOrEqual(with + Self.resultLogMinimum, Self.boardBodyHeight,
                                     "\(lang.rawValue): the result needs \(with)pt plus its log in a \(Self.boardBodyHeight)pt body")
            let view = PracticeResultView(session: session, battle: battle, record: record, l: L(lang), artwork: false)
            let host = hostView(view, width: width, height: Self.boardBodyHeight)
            guard lang == .en else {
                let (_, bitmap) = try await waitForText(["%"], in: host)
                try save(bitmap, as: "practice-step5-result-ko.png")
                continue
            }
            let needles = ["Victory", "4-win streak", "Today's stars", "Rematch", "New opponent", "Again on auto"]
            let (text, bitmap) = try await waitForText(needles, in: host)
            try save(bitmap, as: "practice-step5-result-en.png")
            assertRendered(needles, in: text)
        }
    }

    /// The foe's card shows its temperament, read off the battle's opponent; my own card has none.
    func testFoeCardDrawsItsTemperament() async throws {
        let session = makeSession(Self.stagedState())
        session.mode = .manual
        session.start()
        let battle = try XCTUnwrap(session.battle)
        let view = try XCTUnwrap(battle.view)
        let board = PracticeBattleBoard(session: session, battle: battle, l: L(.en), artwork: false)
        let foe = board.sideCard(.opponent, view.p2)
        XCTAssertNotNil(foe.temperament, "an opponent with a snapshot has a temperament")
        XCTAssertEqual(foe.temperament, battle.opponent?.temperament)
        XCTAssertNil(board.sideCard(.player, view.p1).temperament)

        var tagged = foe, bare = foe
        tagged.temperament = .aggressive
        bare.temperament = nil
        let width = PopoverMetrics.contentWidth
        let with = try Self.capture2x(hostView(tagged, width: width, height: 90))
        let without = try Self.capture2x(hostView(bare, width: width, height: 90))
        XCTAssertNotEqual(Self.pixels(with), Self.pixels(without), "the foe card draws no temperament")
        for lang in [AppLanguage.en, .ko] {
            let host = hostView(PracticeBattleBoard(session: session, battle: battle, l: L(lang), artwork: false),
                                width: width, height: Self.boardBodyHeight)
            let (_, bitmap) = try await waitForText(["Lv."], in: host)
            try save(bitmap, as: "practice-step5-board-\(lang.rawValue).png")
        }
    }

    // MARK: Battle items, HP and stakes (PR 03C)
    //
    // Core keeps HP and pays XP in parallel, so until it lands the session reports no HP and no stakes: these tests
    // feed the views plain values (`PracticeSelectionProgress.health`, `PracticeStakesUpdate`, a recording bag). The
    // fainted tag, star-like marks and arrows are small, so they are checked by size and pixels, never by OCR.

    /// A finished staged battle: my Pikachu's Volt Tackle wins in one turn, or my Magikarp loses to Pikachu.
    private func finishedBattle(won: Bool) throws -> (PracticeSession, PracticeBattle) {
        let session = makeSession(Self.stagedState())
        if won {
            try chooseVoltTackle(session)
            for _ in 0..<120 where session.battle?.phase != .finished || session.playback?.isPlaying != false {
                now += 0.5
                session.tick()
            }
        } else {
            let pikachu = try XCTUnwrap(session.playerID), magikarp = try XCTUnwrap(session.opponentID)
            session.playerID = magikarp
            session.opponentID = pikachu
            session.mode = .automatic
            session.start()
            session.skipToResult()
        }
        let battle = try XCTUnwrap(session.battle)
        XCTAssertEqual(battle.phase, .finished)
        XCTAssertEqual(battle.result?.winner == "p1", won, "the staged battle must end the way the test needs")
        return (session, battle)
    }

    /// A companion store on a temp file: Pikachu is the current Pokémon with known IVs, and the four battle items
    /// are in the bag. HP is whatever the store reports for a fresh save.
    private func battleItemStore(language: AppLanguage) throws -> CompanionStore {
        let suite = "PracticeBag-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(suite).json")
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: file)
        }
        var profile = PokemonProfile.generate(seed: 7, instanceID: "bag-pikachu")
        profile.gender = .male; profile.level = 30; profile.abilityName = "static"
        profile.moves = [PokemonKnownMove(name: "thunderbolt", learnedAtLevel: 1)]
        profile.ivs = PokemonIVs(hp: 31, attack: 12, defense: 0, specialAttack: 25, specialDefense: 7, speed: 18)
        var state = CompanionState()
        state.active = MonState(baseID: 25, pathIDs: [25], stageIndex: 0, usedAtStage: 0, rarity: .common,
                                totalForms: 1, nature: .hardy, profile: profile)
        state.inventory = [ItemKind.potion.rawValue: 2, ItemKind.hyperPotion.rawValue: 1, ItemKind.revive.rawValue: 1,
                           ItemKind.ivReroll.rawValue: 1]
        state.language = language
        try JSONEncoder().encode(state).write(to: file)
        return CompanionStore(provider: OfflineWildProvider(), fileURL: file, defaults: defaults)
    }

    /// HP as a bar with its percentage, or a "Fainted" tag at 0.
    func testHealthLineShowsPercentOrFainted() async throws {
        let width: CGFloat = 200
        let (text, bitmap) = try await waitForText(["63%"], in: hostView(BattleHealthLine(share: 0.63, l: L(.en)).padding(6),
                                                                         width: width, height: 30))
        try save(bitmap, as: "practice-03c-health-line.png")
        assertRendered(["63%"], in: text)
        let empty = Self.emptyWidth
        XCTAssertGreaterThan(NSHostingView(rootView: BattleHealthLine(share: 0, l: L(.en))).fittingSize.width, empty + 10,
                             "a fainted Pokémon shows its tag")
        XCTAssertGreaterThan(NSHostingView(rootView: BattleFaintedTag(l: L(.en))).fittingSize.width, empty + 10)
        let low = try Self.capture2x(hostView(BattleHealthLine(share: 0.2, l: L(.en)), width: width, height: 30))
        let high = try Self.capture2x(hostView(BattleHealthLine(share: 0.9, l: L(.en)), width: width, height: 30))
        let zero = try Self.capture2x(hostView(BattleHealthLine(share: 0, l: L(.en)), width: width, height: 30))
        XCTAssertNotEqual(Self.pixels(low), Self.pixels(high), "the bar follows the share")
        XCTAssertNotEqual(Self.pixels(zero), Self.pixels(low), "fainted is drawn apart from a low bar")
    }

    /// The IV reroll's confirm shows the six current IVs and warns they may drop; the result shows the new six. Both
    /// fit the bag's column in both languages.
    func testIVRerollPanelShowsTheIVsBeforeAndAfter() async throws {
        let old = PokemonIVs(hp: 31, attack: 12, defense: 0, specialAttack: 25, specialDefense: 7, speed: 18)
        let new = PokemonIVs(hp: 20, attack: 12, defense: 9, specialAttack: 26, specialDefense: 30, speed: 2)
        let width = PopoverMetrics.scrollContentWidth
        func confirms(_ stage: IVRerollPanel.Stage) -> Bool {
            if case .confirm = stage { return true }
            return false
        }
        for lang in [AppLanguage.en, .ko] {
            for stage in [IVRerollPanel.Stage.confirm(current: old), .result(old: old, new: new)] {
                let panel = IVRerollPanel(stage: stage, l: L(lang), onReroll: {}, onCancel: {}, onDone: {})
                let size = NSHostingController(rootView: panel)
                    .sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
                XCTAssertGreaterThan(size.height, 40, "\(lang.rawValue) \(stage): no panel")
                XCTAssertLessThanOrEqual(size.width, width + 0.5, "\(lang.rawValue) \(stage): \(size)")
                let host = hostView(panel.padding(8), width: width, height: 170)
                let isConfirm = confirms(stage)
                let name = "practice-03c-iv-reroll-\(isConfirm ? "confirm" : "result")-\(lang.rawValue).png"
                guard lang == .en else {
                    let (_, bitmap) = try await waitForText(["31"], in: host)
                    try save(bitmap, as: name)
                    continue
                }
                let needles = isConfirm ? ["Current IVs", "They may get lower", "Re-roll", "Cancel", "Attack", "Speed", "25", "18"]
                    : ["New IVs", "Close", "Attack", "26", "30"]
                let (text, bitmap) = try await waitForText(needles, in: host)
                try save(bitmap, as: name)
                assertRendered(needles, in: text)
                if !isConfirm {
                    XCTAssertFalse(Self.normalized(text).contains(Self.normalized("They may get lower")),
                                   "the warning belongs before the reroll: \(text)")
                }
            }
        }
    }

    /// The bag lists the four battle items with their effect, and says why a healing item cannot be used on the
    /// current Pokémon: a fresh save is at full HP, so Potions say so and the Revive waits for a faint. The reroll
    /// is ready to use.
    func testBagShowsBattleItemsWithWhatTheyDoNow() async throws {
        for lang in [AppLanguage.en, .ko] {
            let store = try battleItemStore(language: lang)
            XCTAssertEqual(store.currentInstanceID, "bag-pikachu")
            XCTAssertEqual(store.currentIVs?.speed, 18)
            XCTAssertEqual(store.currentHealthShare, 1, "a fresh save starts at full HP")
            let host = hostView(BagView(store: store, nav: PopoverNavigation()), width: PopoverMetrics.contentWidth, height: 520)
            guard lang == .en else {
                let (_, bitmap) = try await waitForText(["IV"], in: host)
                try save(bitmap, as: "practice-03c-bag-ko.png")
                continue
            }
            let needles = ["Potion", "Hyper Potion", "Revive", "IV Reroll", "HP is full", "Only for a fainted Pokémon",
                           "Re-roll all 6 IVs"]
            let (text, bitmap) = try await waitForText(needles, in: host)
            try save(bitmap, as: "practice-03c-bag-en.png")
            assertRendered(needles, in: text)
        }
    }

    /// The Heal control lists only the items that would work on the entry, and says where to get one when none do.
    func testHealControlListsWhatWorksOnTheEntry() async throws {
        let width = PopoverMetrics.scrollContentWidth
        let counts: [ItemKind: Int] = [.potion: 2, .hyperPotion: 1, .revive: 1]
        func host(_ share: Double, _ counts: [ItemKind: Int], open: Bool = true) -> NSView {
            hostView(PracticeHealControl(share: share, counts: counts, isOpen: open, l: L(.en), onToggle: {}, onUse: { _ in })
                .padding(8), width: width, height: 130)
        }
        let hurt = ["Heal", "Potion", "Hyper Potion"]
        let (text, bitmap) = try await waitForText(hurt, in: host(0.63, counts))
        try save(bitmap, as: "practice-03c-heal-open.png")
        assertRendered(hurt, in: text)
        XCTAssertFalse(Self.normalized(text).contains("revive"), "a Revive does nothing for a hurt entry: \(text)")

        let (faintedText, _) = try await waitForText(["Revive"], in: host(0, counts))
        assertRendered(["Revive"], in: faintedText)
        XCTAssertFalse(Self.normalized(faintedText).contains("potion"), "a Potion cannot wake a fainted entry: \(faintedText)")

        let (noneText, _) = try await waitForText(["No healing item"], in: host(0.63, [:]))
        assertRendered(["No healing item"], in: noneText)

        let (closedText, _) = try await waitForText(["Heal"], in: host(0.63, counts, open: false))
        assertRendered(["Heal"], in: closedText)
        XCTAssertFalse(Self.normalized(closedText).contains("potion"), "closed, it lists nothing: \(closedText)")
    }

    /// My hurt entry shows its HP and the Heal control; a fainted owned Pokémon is drawn apart from a healthy one and
    /// can still be sparred with. The rows with HP fit the column in both languages.
    func testSelectionShowsHurtAndFaintedPokemon() async throws {
        let session = makeSession(Self.stagedState())
        let pikachu = try XCTUnwrap(session.player), magikarp = try XCTUnwrap(session.opponent)
        let progress = PracticeSelectionProgress(health: [pikachu.id: 0.63, magikarp.id: 0])
        let bag = RecordingItemBag([.potion: 2, .hyperPotion: 1])
        for lang in [AppLanguage.en, .ko] {
            let view = PracticeSelectionView(session: session, progress: progress, l: L(lang), artwork: false, bag: bag)
            let host = hostView(view, width: PopoverMetrics.contentWidth, height: Self.boardBodyHeight)
            guard lang == .en else {
                let (_, bitmap) = try await waitForText(["63%"], in: host)
                try save(bitmap, as: "practice-03c-selection-hurt-ko.png")
                continue
            }
            let needles = ["63%", "Heal", "Start battle"]
            let (text, bitmap) = try await waitForText(needles, in: host)
            try save(bitmap, as: "practice-03c-selection-hurt-en.png")
            assertRendered(needles, in: text)
        }
        XCTAssertFalse(progress.faintedBlock)
        XCTAssertTrue(PracticeSelectionView.canStart(player: pikachu, opponent: magikarp, faintedBlock: progress.faintedBlock),
                      "sparring a fainted Pokémon of my own stays open")

        let width = PopoverMetrics.scrollContentWidth
        func row(_ health: Double?, _ lang: AppLanguage = .en) -> some View {
            PracticeOpponentRow(candidate: magikarp, temperament: .standard, selected: false, number: 2, health: health,
                                l: L(lang), artwork: false, onSelect: {}) { EmptyView() }
        }
        let fainted = try Self.capture2x(hostView(row(0), width: width, height: 70))
        try save(fainted, as: "practice-03c-row-fainted.png")
        let healthy = try Self.capture2x(hostView(row(1), width: width, height: 70))
        let wild = try Self.capture2x(hostView(row(nil), width: width, height: 70))
        XCTAssertNotEqual(Self.pixels(fainted), Self.pixels(healthy), "a fainted row is drawn apart")
        XCTAssertNotEqual(Self.pixels(healthy), Self.pixels(wild), "an owned row shows its HP")
        for lang in [AppLanguage.en, .ko] {
            for health in [0, 0.5, 1] {
                let size = NSHostingController(rootView: row(health, lang))
                    .sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
                XCTAssertLessThanOrEqual(size.width, width + 0.5, "\(lang.rawValue) HP \(health): \(size)")
            }
        }
    }

    /// A fainted entry cannot start against a wild opponent: Start is refused and the line above it says why. The
    /// Heal control offers the Revive.
    func testFaintedEntryCannotStartAgainstAWildOpponent() async throws {
        let session = makeSession(Self.stagedState(),
                                  wildSource: PracticeWildSource(provider: WildLineProvider(), details: WildLineProvider()))
        session.findWildOpponents()
        try await waitForWild(session) { $0 == .ready }
        let wild = try XCTUnwrap(session.wildCandidates.first, "no wild opponent")
        session.opponentID = wild.id
        let pikachu = try XCTUnwrap(session.player)
        let blocked = PracticeSelectionProgress.blocksStart(playerShare: 0, opponent: session.opponent)
        XCTAssertTrue(blocked, "a fainted entry against a wild opponent")
        let progress = PracticeSelectionProgress(health: [pikachu.id: 0], faintedBlock: blocked)
        XCTAssertFalse(PracticeSelectionView.canStart(player: session.player, opponent: session.opponent,
                                                      faintedBlock: progress.faintedBlock))
        let bag = RecordingItemBag([.revive: 1, .potion: 3])
        for lang in [AppLanguage.en, .ko] {
            let view = PracticeSelectionView(session: session, progress: progress, l: L(lang), artwork: false, bag: bag)
            let host = hostView(view, width: PopoverMetrics.contentWidth, height: Self.boardBodyHeight)
            guard lang == .en else {
                let (_, bitmap) = try await waitForText(["Lv."], in: host)
                try save(bitmap, as: "practice-03c-selection-fainted-ko.png")
                continue
            }
            let needles = ["heal it to fight wild", "Heal", "Start battle"]
            let (text, bitmap) = try await waitForText(needles, in: host)
            try save(bitmap, as: "practice-03c-selection-fainted-en.png")
            assertRendered(needles, in: text)
        }
    }

    /// The result card reports what a battle with stakes did: XP with the paying wins left, why there was none, the
    /// HP that carries over, or the faint with a way to heal it.
    func testResultCardReportsXPAndHP() async throws {
        let width = PopoverMetrics.contentWidth
        func host(_ outcome: PracticeOutcome, _ stakes: PracticeStakesUpdate) -> NSView {
            let update = PracticeRecordUpdate(outcome: outcome, streak: outcome == .win ? 2 : 0, bestStreak: 5,
                                              endedStreak: outcome == .win ? nil : 3, daily: false, newStars: [], stars: [])
            return hostView(PracticeResultRecord(update: update, stakes: stakes, l: L(.en)), width: width, height: 90)
        }
        let won = ["+5M XP", "9 more today", "71%", "stays for your next battle"]
        let (text, bitmap) = try await waitForText(won, in: host(.win, PracticeStakesUpdate(healthShare: 0.71, xp: 5_000_000,
                                                                                               xpWinsLeft: 9)))
        try save(bitmap, as: "practice-03c-result-card-win.png")
        assertRendered(won, in: text)

        let lost = ["Fainted", "Use a Revive", "No XP for a loss"]
        let (lostText, lostBitmap) = try await waitForText(lost, in: host(.loss, PracticeStakesUpdate(healthShare: 0, xp: 0,
                                                                                                         xpWinsLeft: 9)))
        try save(lostBitmap, as: "practice-03c-result-card-fainted.png")
        assertRendered(lost, in: lostText)

        let capped = ["No XP", "limit of \(PracticeStakes.dailyXPWins) wins"]
        let (cappedText, _) = try await waitForText(capped, in: host(.win, PracticeStakesUpdate(healthShare: 0.5, xp: 0,
                                                                                                   xpWinsLeft: 0)))
        assertRendered(capped, in: cappedText)
    }

    /// The result screen with streak, XP, HP and today's stars still fits its 520pt body in both languages, won or
    /// fainted, and the HP left is said once (the summary drops its own row).
    func testResultWithStakesFitsTheBody() async throws {
        let width = PopoverMetrics.contentWidth
        for won in [true, false] {
            let (session, battle) = try finishedBattle(won: won)
            let record = won
                ? PracticeRecordUpdate(outcome: .win, streak: 4, bestStreak: 4, endedStreak: nil, daily: true,
                                       newStars: [.quickWin], stars: [.win, .quickWin])
                : PracticeRecordUpdate(outcome: .loss, streak: 0, bestStreak: 7, endedStreak: 7, daily: true,
                                       newStars: [], stars: [.win])
            let stakes = won ? PracticeStakesUpdate(healthShare: 0.71, xp: PracticeStakes.winXP, xpWinsLeft: 9)
                : PracticeStakesUpdate(healthShare: 0, xp: 0, xpWinsLeft: 9)
            for lang in [AppLanguage.en, .ko] {
                func least(_ stakes: PracticeStakesUpdate?) -> CGFloat {
                    let view = PracticeResultView(session: session, battle: battle, record: record, stakes: stakes,
                                                  l: L(lang), artwork: false)
                    return NSHostingController(rootView: view.frame(width: width))
                        .sizeThatFits(in: CGSize(width: width, height: 0)).height
                }
                let with = least(stakes), bare = least(nil)
                XCTAssertGreaterThan(with, bare, "\(lang.rawValue) won \(won): the stakes are on the result screen")
                XCTAssertLessThanOrEqual(with + Self.resultLogMinimum, Self.boardBodyHeight,
                                         "\(lang.rawValue) won \(won): the result needs \(with)pt plus its log")
                let view = PracticeResultView(session: session, battle: battle, record: record, stakes: stakes,
                                              l: L(lang), artwork: false)
                let host = hostView(view, width: width, height: Self.boardBodyHeight)
                let name = "practice-03c-result-\(won ? "win" : "fainted")-\(lang.rawValue).png"
                guard lang == .en else {
                    let (_, bitmap) = try await waitForText(["%"], in: host)
                    try save(bitmap, as: name)
                    continue
                }
                let needles = (won ? ["+5M XP", "71%"] : ["Fainted", "Use a Revive"]) + ["Rematch", "Again on auto"]
                let (text, bitmap) = try await waitForText(needles, in: host)
                try save(bitmap, as: name)
                assertRendered(needles, in: text)
                XCTAssertFalse(Self.normalized(text).contains(Self.normalized("HP left")),
                               "won \(won): the HP is said once, on the stakes line: \(text)")
            }
        }
    }

    /// Review image only: the status item cannot be hosted in a test, so this draws the menu bar text the app builds
    /// with the fainted mark, next to a sprite tile at the opacity the app gives a fainted current Pokémon, and the
    /// tooltip the app sets.
    func testMenuBarFaintIllustration() async throws {
        let mark = AppDelegate.faintedMark
        let lines = AppDelegate.menuLines(["5h 12%", "1.2M"], badge: AppDelegate.menuBadge(practice: nil, fainted: true))
        XCTAssertEqual(lines.first, "5h 12% " + mark, "the mark follows the first line")
        let opacity = Double(AppDelegate.statusSpriteOpacity(fainted: true, showsCurrent: true))
        XCTAssertLessThan(opacity, 1)
        for lang in [AppLanguage.en, .ko] {
            let l = L(lang)
            let tip = AppDelegate.menuToolTip(base: "5h 12% · 1.2M", badge: nil, resultReady: false,
                                              faintedName: lang == .ko ? "피카츄" : "Pikachu", l: l) ?? ""
            XCTAssertTrue(tip.contains(l.menuFaintedLine(lang == .ko ? "피카츄" : "Pikachu")))
            let host = hostView(MenuBarFaintPreview(lines: lines, opacity: opacity, toolTip: tip),
                                width: 300, height: 92)
            let (_, bitmap) = try await waitForText(["1.2M"], in: host)
            try save(bitmap, as: "practice-03c-menubar-\(lang.rawValue).png")
        }
    }
}

/// A bag that holds counts and records each healing use, standing in for the companion store.
@MainActor
final class RecordingItemBag: PracticeItemBag {
    private(set) var counts: [ItemKind: Int]
    private(set) var uses: [(kind: ItemKind, instanceID: String)] = []

    init(_ counts: [ItemKind: Int]) { self.counts = counts }

    func itemCount(_ kind: ItemKind) -> Int { counts[kind] ?? 0 }

    func useHealingItem(_ kind: ItemKind, on instanceID: String) -> Bool {
        guard itemCount(kind) > 0 else { return false }
        counts[kind, default: 0] -= 1
        uses.append((kind, instanceID))
        return true
    }
}

/// The review illustration of the menu bar while the current Pokémon is fainted (`testMenuBarFaintIllustration`):
/// the app's own lines and opacity on a menu-bar-like strip, with its tooltip underneath.
@MainActor
private struct MenuBarFaintPreview: View {
    let lines: [String]
    let opacity: Double
    let toolTip: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "pawprint.fill")
                    .font(.system(size: 16))
                    .frame(width: 22, height: 22)
                    .opacity(opacity)
                VStack(spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 10).monospacedDigit())
                    }
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 2)
            .frame(height: 24)
            .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            Text(toolTip)
                .font(.system(size: 11))
                .padding(6)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
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
