import AppKit
import SwiftUI
import XCTest
@testable import PokeTokenBar

/// T18 drawn: the turn bar, the foe card's nickname line and the opening splash inside the arena's fixed board.
/// Synthetic data and native SwiftUI renders only. With `PTB_SNAPSHOT_SCREENSHOT_DIR` set the whole-screen PNGs are
/// kept (720px wide). Nothing here reads small text back by OCR: bars are measured by colour, the splash by pixel
/// differences between the same board with and without it.
@MainActor
final class OnlineBattleTimerRenderingTests: XCTestCase {
    private var window: NSWindow?
    override func tearDown() async throws { window?.close(); window = nil }
    private static let filler: CGFloat = 200

    private func arena(splash: Bool = false) throws -> OnlineBattleArenaFixture.Arena {
        let fixture = try OnlineBattleArenaFixture.arena(seat: .p1, splash: splash)
        let foeID = try XCTUnwrap(fixture.model.room).p2.trainerId
        fixture.model.members = [.init(trainerId: foeID, displayEmail: "연습친구", role: .member, status: .active, joinedAt: 0, online: true)]
        return fixture
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
        window.contentView = host; window.orderFront(nil); self.window?.close(); self.window = window
        await settle(host)
        return host
    }

    private func settle(_ host: NSView, milliseconds: Int = 200) async {
        try? await Task.sleep(for: .milliseconds(milliseconds)); host.layoutSubtreeIfNeeded()
    }

    /// Ink under the board's fixed height: a footer or a line taller than its room would hang out of the scroll area.
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

    /// The rows of one band of the board as bytes, so two renders of it compare exactly.
    private func band(_ host: NSView, fromPoint top: CGFloat, toPoint bottom: CGFloat) throws -> [UInt8] {
        let bitmap = try PracticeScreenRenderingTests.capture2x(host)
        var bytes: [UInt8] = []
        for y in Int(top * 2)..<min(Int(bottom * 2), bitmap.pixelsHigh) {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                bytes += [UInt8(color.redComponent * 255), UInt8(color.greenComponent * 255), UInt8(color.blueComponent * 255)]
            }
        }
        return bytes
    }

    private var footerTop: CGFloat { OnlineBattleArena.boardHeight - OnlineBattleArena.footerHeight }

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

    private func screenHost(_ model: OnlineBattlePresentation, _ lang: AppLanguage) async -> NSView {
        let provider = OnlineBattleSyntheticNameProvider()
        let names = PokemonNameDisplayStore()
        for id in [25, 26, 129] { _ = await names.load(.init(kind: .pokemonSpecies, name: String(id)), provider: provider) }
        let host = NSHostingView(rootView: OnlineBattleScreen(model: model, l: L(lang), artwork: false, readInvitationClipboard: { nil },
                                                             speciesNameProvider: provider, speciesNameStore: names,
                                                             onClosePopover: {}, onClose: {})
            .background(Color.white).environment(\.colorScheme, .light))
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 610)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 360, height: 610),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
        window.contentView = host; window.orderFront(nil); self.window?.close(); self.window = window
        await settle(host, milliseconds: 600)
        return host
    }

    // MARK: the bar itself

    /// Draws the bar alone at a known width and reads its middle row: coloured pixels are the fill, grey ones the track.
    private func fill(_ state: OnlineBattleTurnClock.State, dim: Bool = false) async throws -> (fraction: Double, red: Double, blue: Double) {
        let width: CGFloat = 200
        let host = NSHostingView(rootView: OnlineBattleTurnBar(state: state, dim: dim).frame(width: width).padding(.vertical, 8).background(Color.white)
            .environment(\.colorScheme, .light))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 30)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
        window.contentView = host; window.orderFront(nil); self.window?.close(); self.window = window
        await settle(host)
        let bitmap = try PracticeScreenRenderingTests.capture2x(host)
        let y = bitmap.pixelsHigh / 2
        var coloured = 0, red = 0.0, blue = 0.0
        for x in 0..<bitmap.pixelsWide {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            let high = max(color.redComponent, color.greenComponent, color.blueComponent), low = min(color.redComponent, color.greenComponent, color.blueComponent)
            if high - low > 0.3 { coloured += 1; red += color.redComponent; blue += color.blueComponent }
        }
        return (Double(coloured) / Double(bitmap.pixelsWide), coloured == 0 ? 0 : red / Double(coloured), coloured == 0 ? 0 : blue / Double(coloured))
    }

    func testTheBarsFillFollowsTheFractionAndAnEmptyOrIdleBarDrawsNoFill() async throws {
        let half = try await fill(.counting(remaining: 15, fraction: 0.5, mine: true))
        XCTAssertEqual(half.fraction, 0.5, accuracy: 0.08)
        let full = try await fill(.counting(remaining: 30, fraction: 1, mine: true))
        XCTAssertGreaterThan(full.fraction, 0.9)
        let quarter = try await fill(.counting(remaining: 8, fraction: 0.25, mine: true))
        XCTAssertLessThan(quarter.fraction, half.fraction); XCTAssertEqual(quarter.fraction, 0.25, accuracy: 0.08)
        for state in [OnlineBattleTurnClock.State.preparing, .idle, .counting(remaining: 0, fraction: 0, mine: true)] {
            let none = try await fill(state)
            XCTAssertEqual(none.fraction, 0, accuracy: 0.001, "\(state)")
        }
    }

    func testTheLastFiveSecondsTurnOrangeAndOnlyThen() async throws {
        let calm = try await fill(.counting(remaining: 12, fraction: 0.4, mine: true))
        let urgent = try await fill(.counting(remaining: 4, fraction: 0.13, mine: true))
        let waiting = try await fill(.counting(remaining: 4, fraction: 0.13, mine: false))
        XCTAssertGreaterThan(urgent.red, 0.85); XCTAssertLessThan(urgent.blue, 0.6, "orange: red high, blue low")
        XCTAssertGreaterThan(calm.blue, calm.red, "the calm bar is not orange")
        XCTAssertGreaterThan(waiting.blue, waiting.red, "after my choice the last seconds are not an alarm")
    }

    func testThePulseDimsTheFillWithoutMovingIt() async throws {
        let state = OnlineBattleTurnClock.State.counting(remaining: 4, fraction: 0.5, mine: true)
        let bright = try await fill(state, dim: false), dim = try await fill(state, dim: true)
        XCTAssertEqual(bright.fraction, dim.fraction, accuracy: 0.02)
        XCTAssertGreaterThan(dim.fraction, 0.3, "dimmed, not gone")
    }

    // MARK: the board

    /// The bar, the nickname label, the record line, the longest caption and the splash all live inside the board's
    /// one height, in both languages, with the tallest foe card (four revealed moves with long names).
    func testTheBoardKeepsItsHeightWithTheBarTheLineAndTheLongestCaptions() async throws {
        let longNames = ["ko": "아주아주긴닉네임의동료친구분", "en": "Wolfgang-Amadeus-Mozart-Jr"]
        for lang in [AppLanguage.ko, .en] {
            let fixture = try arena(); defer { fixture.close() }
            let model = fixture.model, foeID = try XCTUnwrap(model.room).p2.trainerId
            model.members = [.init(trainerId: foeID, displayEmail: longNames[lang == .ko ? "ko" : "en"], role: .member, status: .active, joinedAt: 0, online: true)]
            let me = try XCTUnwrap(model.room).p1.trainerId
            model.battles = (0..<23).map { index in
                let base = OnlineBattleScreenRenderingTests.room(state: .completed, id: "done-\(index)")
                let winner: OnlineBattleWinner = index < 12 ? .p1 : index < 15 ? .draw : .p2
                return OnlineBattleView(battleId: "done-\(index)", state: .completed, revision: 1, mode: .manual,
                                        p1: .init(trainerId: me, snapshot: nil, publicInfo: nil, hpPercent: nil),
                                        p2: .init(trainerId: foeID, snapshot: nil, publicInfo: nil, hpPercent: nil),
                                        createdAt: base.createdAt, expiresAt: 100, startedAt: 0, reportedAt: nil, confirmed: true, config: nil,
                                        roundSeq: 1, deadline: nil, ownChoice: nil, journal: [],
                                        result: .init(readyToken: "t", engineHash: "e", terminalSeq: 1, winner: winner, logHash: "l", journalHash: "j",
                                                      finalHp: .init(p1: 1, p2: 0)),
                                        reason: nil, rematchOf: nil)
            }
            model.standings = .init(groupId: "g", championTrainerId: nil, rows: [
                .init(trainerId: foeID, displayName: "x", wins: 99, losses: 0, draws: 0, streak: 12, bestStreak: 99, winRate: 1)])
            let seen = try XCTUnwrap(model.arena), foe = seen.p2
            model.arena = BattleView(turn: seen.turn, ended: false, p1: seen.p1,
                                     p2: .init(speciesNum: foe.speciesNum, species: foe.species, level: foe.level, types: foe.types, hp: foe.hp,
                                               maxhp: foe.maxhp, status: "par", moves: ["hyperbeam", "earthquake", "flamethrower", "thunderwave"],
                                               ability: "intimidate"))
            model.moveSlugs[.p2] = ["hyperbeam": "hyper-beam", "earthquake": "earthquake", "flamethrower": "flamethrower", "thunderwave": "thunder-wave"]
            model.abilitySlugs[.p2] = ["intimidate": "intimidate"]
            let host = await arenaHost(model, lang)
            var states: [(String, () throws -> Void)] = []
            func set(_ name: String, _ change: @escaping () throws -> Void) { states.append((name, change)) }
            set("counting") { model.deadline = Date().addingTimeInterval(28.5) }
            set("urgent") { model.deadline = Date().addingTimeInterval(3.5) }
            set("sent") { model.choiceSubmitted = true }
            set("preparing") { model.choiceSubmitted = false; model.deadline = nil }
            set("playing") { try fixture.play(rounds: 1); model.deadline = Date().addingTimeInterval(20) }
            set("forced") { fixture.staging.skipToEnd(); model.request = .init(kind: "none", moves: []) }
            for (name, change) in states {
                try change()
                await settle(host)
                XCTAssertEqual(try inkBelowTheBoard(host), 0, "\(lang) \(name): ink under the board")
            }
            let auto = try OnlineBattleArenaFixture.arena(seat: .p2, name: "auto")
            defer { auto.close() }
            try auto.play(rounds: 1, mode: .auto, secondsLeft: nil)
            auto.model.room = try OnlineBattleArenaFixture.liveRoom("auto", seat: .p2, deadline: nil)
            let autoHost = await arenaHost(auto.model, lang)
            XCTAssertEqual(try inkBelowTheBoard(autoHost), 0, "\(lang) auto")
        }
    }

    /// The bar is drawn: the same board at 28 seconds and at 9 seconds differs above the picker, and the picker is
    /// the same in both.
    func testTheBarChangesTheHeaderAndLeavesThePickerAlone() async throws {
        let fixture = try arena(); defer { fixture.close() }
        fixture.model.deadline = Date().addingTimeInterval(28.5)
        let host = await arenaHost(fixture.model, .en)
        let early = try band(host, fromPoint: 0, toPoint: footerTop), earlyPicker = try band(host, fromPoint: footerTop, toPoint: OnlineBattleArena.boardHeight)
        fixture.model.deadline = Date().addingTimeInterval(9.5)
        await settle(host)
        let late = try band(host, fromPoint: 0, toPoint: footerTop), latePicker = try band(host, fromPoint: footerTop, toPoint: OnlineBattleArena.boardHeight)
        XCTAssertNotEqual(early, late, "the bar and its seconds moved")
        XCTAssertEqual(earlyPicker, latePicker, "nothing about the clock reaches the picker")
    }

    // MARK: splash

    /// Click where the splash is: the middle of the cards. A synthetic mouse press, or the button where there is one.
    private func click(_ host: NSView, x: CGFloat, y: CGFloat) throws {
        let window = try XCTUnwrap(host.window)
        let hostPoint = NSPoint(x: x, y: host.isFlipped ? y : host.bounds.height - y)
        var hit = host.hitTest(host.convert(hostPoint, to: host.superview))
        while let current = hit, !(current is NSButton) { hit = current.superview }
        if let button = hit as? NSButton { button.performClick(nil); return }
        let point = host.convert(hostPoint, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                         windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            window.sendEvent(event)
        }
    }

    /// The splash covers the cards only: the picker underneath it is pixel for pixel the one without it, a click skips
    /// it, and nothing hangs out of the board either way. It is not shown again to a view built after it.
    func testTheSplashCoversTheCardsNotThePickerAndASkipClearsIt() async throws {
        let fixture = try arena(splash: true); defer { fixture.close() }
        fixture.model.deadline = nil
        let host = await arenaHost(fixture.model, .ko)
        await settle(host, milliseconds: 500)
        XCTAssertTrue(fixture.staging.playback.introShown, "the screen claimed the splash when it appeared")
        let withSplash = try band(host, fromPoint: 0, toPoint: footerTop), pickerWith = try band(host, fromPoint: footerTop, toPoint: OnlineBattleArena.boardHeight)
        XCTAssertEqual(try inkBelowTheBoard(host), 0, "splash")
        try click(host, x: PopoverMetrics.scrollContentWidth / 2, y: 130)
        await settle(host, milliseconds: 600)
        let without = try band(host, fromPoint: 0, toPoint: footerTop), pickerWithout = try band(host, fromPoint: footerTop, toPoint: OnlineBattleArena.boardHeight)
        XCTAssertNotEqual(withSplash, without, "the click took the splash away")
        XCTAssertEqual(pickerWith, pickerWithout, "the picker was never covered")
        XCTAssertEqual(try inkBelowTheBoard(host), 0)
        // A screen built after the splash was shown: the same battle, no splash.
        let reopened = await arenaHost(fixture.model, .ko)
        await settle(reopened, milliseconds: 500)
        XCTAssertEqual(try band(reopened, fromPoint: 0, toPoint: footerTop), without)
    }

    func testTheSplashLeavesByItselfInAboutThreeSeconds() async throws {
        let fixture = try arena(splash: true); defer { fixture.close() }
        fixture.model.deadline = nil
        let host = await arenaHost(fixture.model, .en)
        await settle(host, milliseconds: 500)
        let during = try band(host, fromPoint: 0, toPoint: footerTop)
        try await Task.sleep(for: .milliseconds(3_200)); host.layoutSubtreeIfNeeded()
        let after = try band(host, fromPoint: 0, toPoint: footerTop)
        XCTAssertNotEqual(during, after, "gone after about three seconds without a click")
    }

    // MARK: kept for review

    func testRendersTheBarTheLineAndTheSplashForReview() async throws {
        for lang in [AppLanguage.ko, .en] {
            let tag = lang == .ko ? "ko" : "en"
            let fixture = try arena(splash: true); defer { fixture.close() }
            let model = fixture.model, foeID = try XCTUnwrap(model.room).p2.trainerId, me = try XCTUnwrap(model.room).p1.trainerId
            model.members = [.init(trainerId: foeID, displayEmail: lang == .ko ? "연습친구" : "Misty", role: .member, status: .active, joinedAt: 0, online: true)]
            model.battles = (0..<3).map { index in
                let base = OnlineBattleScreenRenderingTests.room(state: .completed, id: "done-\(index)")
                return OnlineBattleView(battleId: "done-\(index)", state: .completed, revision: 1, mode: .manual,
                                        p1: .init(trainerId: me, snapshot: nil, publicInfo: nil, hpPercent: nil),
                                        p2: .init(trainerId: foeID, snapshot: nil, publicInfo: nil, hpPercent: nil),
                                        createdAt: base.createdAt, expiresAt: 100, startedAt: 0, reportedAt: nil, confirmed: true, config: nil,
                                        roundSeq: 1, deadline: nil, ownChoice: nil, journal: [],
                                        result: .init(readyToken: "t", engineHash: "e", terminalSeq: 1, winner: index == 2 ? .p2 : .p1, logHash: "l",
                                                      journalHash: "j", finalHp: .init(p1: 1, p2: 0)),
                                        reason: nil, rematchOf: nil)
            }
            model.standings = .init(groupId: "g", championTrainerId: nil, rows: [
                .init(trainerId: foeID, displayName: "x", wins: 5, losses: 0, draws: 0, streak: 3, bestStreak: 5, winRate: 1)])
            model.deadline = Date().addingTimeInterval(29.5)
            let host = await screenHost(model, lang)
            try keep(host, as: "t18-splash-\(tag).png")
            fixture.staging.playback.introShown = true
            // The fill drains over a second per tick, so each state settles for longer than one before it is kept.
            for (name, change) in [("counting", { model.deadline = Date().addingTimeInterval(28.5) }),
                                   ("urgent", { model.deadline = Date().addingTimeInterval(3.5) }),
                                   ("sent", { model.choiceSubmitted = true }),
                                   ("preparing", { model.choiceSubmitted = false; model.deadline = nil })] as [(String, () -> Void)] {
                change()
                await settle(host, milliseconds: 1_300)
                try keep(host, as: "t18-\(name)-\(tag).png")
            }
            try fixture.play(rounds: 1)
            model.deadline = Date().addingTimeInterval(21.5)
            await settle(host, milliseconds: 1_300)
            try keep(host, as: "t18-playing-\(tag).png")
        }
    }
}
