import AppKit
import SwiftUI
import XCTest
@testable import PokeTokenBar

private struct BannerProvider: UsageProvider {
    let id = "fixture"
    let displayName = "Fixture"
    let reportsCost = false
    func fetchDaily() async throws -> DailyUsage? { nil }
    func fetchEnrichment() async -> ProviderEnrichment { ProviderEnrichment() }
}
private struct BannerClaude: ClaudeLimitsProviding {
    func fetch(allowKeychainPrompt: Bool) async throws -> LimitStatus { throw LimitsError.keychainInteractionNotAllowed }
}
private struct BannerCodex: CodexLimitsProviding { func fetch() async throws -> CodexRateLimitStatus? { nil } }
private struct BannerAntigravity: AntigravityLimitsProviding {
    func fetch(allowKeychainPrompt: Bool) async throws -> AntigravityRateLimitStatus { throw LimitsError.keychainInteractionNotAllowed }
}
private struct BannerCursor: CursorLimitsProviding { func fetch() async throws -> CursorRateLimitStatus? { nil } }
private struct BannerStatus: ProviderStatusProviding { func fetch() async -> [String: ProviderStatus] { [:] } }
private struct BannerPokemon: PokeProviding {
    func line(baseSpeciesID: Int) async throws -> EvoLine { throw URLError(.notConnectedToInternet) }
    func baseSpeciesIndex() async throws -> [BaseSpecies] { [] }
    func baseSpecies(id: Int) async throws -> BaseSpecies? { nil }
}

/// The banner in the real `PopoverView`: it fits 360pt, reaches every screen, and leaves the content alone.
/// Synthetic data only. Set PTB_SNAPSHOT_SCREENSHOT_DIR to keep the 720px PNGs.
@MainActor
final class OnlineAttentionBannerRenderingTests: XCTestCase {
    private var suite = ""
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        windows.forEach { $0.close() }
        windows = []
        if !suite.isEmpty {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("\(suite).json"))
        }
    }

    private func makeStores() throws -> (CompanionStore, UsageStore, UserDefaults) {
        suite = "AttentionBanner-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(suite).json")
        var state = PracticeScreenRenderingTests.syntheticState()
        state.language = .ko
        try JSONEncoder().encode(state).write(to: file)
        let companion = CompanionStore(provider: BannerPokemon(), fileURL: file, defaults: defaults)
        let store = UsageStore(providers: [BannerProvider()],
            claudeLimitsProvider: BannerClaude(), discoverClaudeConfigDirs: { [] },
            readDefaultIdentity: { nil }, claudeUsageEntries: { _ in [] },
            codexLimitsProvider: BannerCodex(), antigravityLimitsProvider: BannerAntigravity(),
            cursorLimitsProvider: BannerCursor(), statusProvider: BannerStatus(),
            autoRefresh: false, defaults: defaults)
        return (companion, store, defaults)
    }

    /// No roster: its artwork loads remotely and would make two renders differ.
    private func model(_ battles: [OnlineBattleView], displayed: OnlineBattleView? = nil, phase: OnlineBattlePresentation.Phase = .lobby) -> OnlineBattlePresentation {
        let model = OnlineBattleScreenRenderingTests.model()
        model.roster = []; model.entryHP = [:]; model.selectedEntryID = nil
        model.battles = battles; model.room = displayed; model.phase = phase
        model.members = [.init(trainerId: "synthetic-foe", displayEmail: "연습친구", role: .host, status: .active, joinedAt: 0, online: true)]
        return model
    }
    private func incoming(_ id: String = "synthetic-in", createdAt: Double = 1, rematchOf: String? = nil) -> OnlineBattleView {
        room(id, .pending, mine: .p2, createdAt: createdAt, rematchOf: rematchOf)
    }
    private func room(_ id: String, _ state: OnlineBattleState, mine: OnlineBattleSide, createdAt: Double = 1, rematchOf: String? = nil) -> OnlineBattleView {
        let local = OnlineBattlePlayer(trainerId: "synthetic-me", snapshot: nil, publicInfo: nil, hpPercent: nil)
        let remote = OnlineBattlePlayer(trainerId: "synthetic-foe", snapshot: nil, publicInfo: nil, hpPercent: nil)
        return .init(battleId: id, state: state, revision: 1, mode: .manual, p1: mine == .p1 ? local : remote, p2: mine == .p1 ? remote : local,
                     createdAt: createdAt, expiresAt: Date().timeIntervalSince1970 * 1000 + 3_600_000, startedAt: nil, reportedAt: nil, confirmed: false,
                     config: nil, roundSeq: 0, deadline: nil, ownChoice: nil, journal: [], result: nil, reason: nil, rematchOf: rematchOf)
    }

    private func host(_ view: some View) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: AnyView(view.background(Color.white).environment(\.colorScheme, .light)))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: PopoverMetrics.width, height: 700),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
        window.contentView = host; window.orderFront(nil); windows.append(window)
        return host
    }
    private func popover(_ model: OnlineBattlePresentation, source: OnlineAttentionSource?, nav: PopoverNavigation = PopoverNavigation()) throws -> NSHostingView<AnyView> {
        let (companion, store, defaults) = try makeStores()
        let popover = PopoverView().environment(store).environment(companion).environment(UpdateChecker(defaults: defaults)).environment(nav)
            .environment(model)
        if let source { return host(popover.environment(source)) }
        return host(popover)
    }
    /// Sizes the host to what it wants and draws at 2x, so 360pt comes out 720px wide.
    private func capture(_ host: NSHostingView<AnyView>, named name: String? = nil) async throws -> NSBitmapImageRep {
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        XCTAssertEqual(size.width, PopoverMetrics.width, accuracy: 0.5, "The popover stays 360pt wide")
        host.frame = NSRect(origin: .zero, size: size)
        host.window?.setContentSize(size)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let bitmap = try PracticeScreenRenderingTests.capture2x(host)
        if let name, let path = ProcessInfo.processInfo.environment["PTB_SNAPSHOT_SCREENSHOT_DIR"] {
            let directory = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name))
        }
        return bitmap
    }
    private func rows(_ bitmap: NSBitmapImageRep, from first: Int, count: Int) throws -> Data {
        let data = try XCTUnwrap(bitmap.bitmapData)
        return Data(bytes: data + first * bitmap.bytesPerRow, count: count * bitmap.bytesPerRow)
    }

    // MARK: no banner, no change

    /// The online screen drawn on its own is the baseline: the banner slot must add nothing while it is empty.
    func testWithoutAnEventThePopoverDrawsExactlyWhatTheScreenDrawsAlone() async throws {
        let model = model([])
        let (companion, _, _) = try makeStores()
        let alone = host(OnlineBattleScreen(model: model, l: companion.l, onClose: {}).frame(width: PopoverMetrics.width)
            .environment(\.locale, companion.language.displayLocale))
        let expected = try await capture(alone)
        let nav = PopoverNavigation(); nav.showingOnlineBattle = true
        let inPopover = try popover(model, source: OnlineAttentionSource(presentation: model), nav: nav)
        let actual = try await capture(inPopover)
        XCTAssertEqual(actual.pixelsHigh, expected.pixelsHigh)
        XCTAssertEqual(try rows(actual, from: 0, count: actual.pixelsHigh), try rows(expected, from: 0, count: expected.pixelsHigh))
    }

    func testABannerAddsItsBandOnTopAndLeavesEveryPixelBelowAlone() async throws {
        let model = model([incoming()])
        let nav = PopoverNavigation(); nav.showingOnlineBattle = true
        let without = try await capture(try popover(model, source: nil, nav: nav))
        let with = try await capture(try popover(model, source: OnlineAttentionSource(presentation: model), nav: nav), named: "F2-banner-online-lobby.png")
        let band = with.pixelsHigh - without.pixelsHigh
        XCTAssertGreaterThan(band, 0, "The banner has to show")
        XCTAssertLessThanOrEqual(band, 200, "A two-line banner at 2x, not a screen of its own")
        XCTAssertEqual(try rows(with, from: band, count: without.pixelsHigh), try rows(without, from: 0, count: without.pixelsHigh))
    }

    // MARK: reaches every screen

    private func bandHeight(_ model: OnlineBattlePresentation, setUp: (PopoverNavigation) -> Void, named name: String) async throws -> Int {
        let nav = PopoverNavigation()
        setUp(nav)
        let without = try await capture(try popover(model, source: nil, nav: nav))
        let with = try await capture(try popover(model, source: OnlineAttentionSource(presentation: model), nav: nav), named: name)
        return with.pixelsHigh - without.pixelsHigh
    }

    func testTheBannerReachesHomeTheShopSettingsAndTheRecap() async throws {
        let model = model([incoming()])
        let screens: [(String, (PopoverNavigation) -> Void)] = [
            ("home", { _ in }), ("shop", { $0.tab = .shop }), ("settings", { $0.showSettings = true }), ("recap", { $0.showingRecap = true })]
        for (name, setUp) in screens {
            let band = try await bandHeight(model, setUp: setUp, named: "F2-banner-\(name).png")
            XCTAssertGreaterThan(band, 0, name)
        }
    }

    func testARematchOverAnOpenResultIsAskedInPlaceAndAnEndedRequestStillGetsABanner() async throws {
        let old = room("synthetic-old", .completed, mine: .p2)
        let result = model([old, incoming("synthetic-new", createdAt: 2, rematchOf: "synthetic-old")], displayed: old, phase: .result)
        result.result = .init(kind: .win, effects: .init(instanceID: "synthetic-pikachu", xp: 10, hpShare: 1))
        let onResult = try await bandHeight(result, setUp: { $0.showingOnlineBattle = true }, named: "F2-banner-rematch-over-result.png")
        XCTAssertEqual(onResult, 0, "the result asks in place with accept and later, so a bar above it would say it twice")
        let onHomeToo = try await bandHeight(result, setUp: { _ in }, named: "F2-banner-rematch-over-home.png")
        XCTAssertGreaterThan(onHomeToo, 0, "off the online screen the bar still tells it")

        let ended = model([room("synthetic-out", .declined, mine: .p1)])
        ended.unreadEndedBattleIDs = ["synthetic-out"]
        let onHome = try await bandHeight(ended, setUp: { _ in }, named: "F2-banner-request-declined.png")
        XCTAssertGreaterThan(onHome, 0)
    }

    func testALongNicknameWrapsInsideTheWidth() async throws {
        let model = model([incoming()])
        model.members = [.init(trainerId: "synthetic-foe", displayEmail: String(repeating: "아주긴닉네임", count: 12), role: .host, status: .active, joinedAt: 0, online: true)]
        let nav = PopoverNavigation(); nav.showSettings = true
        let with = try await capture(try popover(model, source: OnlineAttentionSource(presentation: model), nav: nav), named: "F2-banner-long-nickname.png")
        XCTAssertEqual(with.pixelsWide, 720)
    }

    // MARK: pressing it

    /// Native clicks on the real view: `.plain` buttons have no NSButton to press on some systems.
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

    func testPressingTheBannerOnSettingsOpensThatRoom() async throws {
        let model = model([incoming()])
        var followed: [String] = []
        model.onAction = { action in if case .followAttention(let id) = action { followed.append(id) } }
        let nav = PopoverNavigation(); nav.showSettings = true
        let host = try popover(model, source: OnlineAttentionSource(presentation: model), nav: nav)
        _ = try await capture(host)
        try click(host, x: 60, y: PopoverMetrics.padding + 12)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(followed, ["synthetic-in"])
        XCTAssertTrue(nav.showingOnlineBattle)
        XCTAssertFalse(nav.showSettings)
    }

    func testClosingAnEndedBannerLeavesTheScreenAlone() async throws {
        let model = model([room("synthetic-out", .declined, mine: .p1)])
        model.unreadEndedBattleIDs = ["synthetic-out"]
        var reachedSession = false
        model.onAction = { _ in reachedSession = true }
        let nav = PopoverNavigation(); nav.showSettings = true
        let host = try popover(model, source: OnlineAttentionSource(presentation: model), nav: nav)
        _ = try await capture(host)
        // The close button sits at the far end of the bar, inside its 10pt padding.
        try click(host, x: PopoverMetrics.width - PopoverMetrics.padding - 15, y: PopoverMetrics.padding + 16)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(model.unreadEndedBattleIDs, [])
        XCTAssertTrue(nav.showSettings)
        XCTAssertFalse(reachedSession)
    }

    func testTheHomeRowGoesToTheEventNotTheOldResult() async throws {
        let old = room("synthetic-old", .completed, mine: .p2)
        let model = model([old, incoming("synthetic-new", createdAt: 2, rematchOf: "synthetic-old")], displayed: old, phase: .result)
        model.result = .init(kind: .win, effects: .init(instanceID: "synthetic-pikachu", xp: 10, hpShare: 1))
        let nav = PopoverNavigation()
        let source = OnlineAttentionSource(presentation: model)
        XCTAssertEqual(source.openRoute()?.battleId, "synthetic-new")
        var followed: [String] = []
        model.onAction = { action in if case .followAttention(let id) = action { followed.append(id) } }
        // The row's action, read off the view: a text search on rendered pixels would prove less.
        PopoverView.openOnlineFromHome(nav: nav, source: source, model: model, l: L(.ko))
        XCTAssertEqual(followed, ["synthetic-new"])
        XCTAssertTrue(nav.showingOnlineBattle)
    }
}
