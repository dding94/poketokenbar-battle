import AppKit
import SwiftUI
import XCTest
@testable import PokeTokenBar

/// T19 on the real screen: the result's controls follow the rematch beside it. Synthetic data only. What the screen
/// says is read from `resultScreen(l:)`, which the view draws without adding words; controls are pressed by position
/// and no small text is read back from pixels. Set PTB_SNAPSHOT_SCREENSHOT_DIR to keep the 720px PNGs.
@MainActor
final class OnlineBattleResultRenderingTests: XCTestCase {
    private var window: NSWindow?
    override func tearDown() async throws { window?.close(); window = nil }

    private let ko = L(.ko)
    private static let sourceID = "synthetic-battle"

    private func view(_ id: String, _ state: OnlineBattleState, me: OnlineBattleSide = .p1, createdAt: Double = 1_793_683_500_000,
                      rematchOf: String? = nil, winner: OnlineBattleWinner? = nil) -> OnlineBattleView {
        let snapshot = OnlineBattleScreenRenderingTests.snapshot()
        let mine = OnlineBattlePlayer(trainerId: "synthetic-me", snapshot: .init(snapshot: snapshot, hp: 88), publicInfo: nil, hpPercent: nil)
        let theirs = OnlineBattlePlayer(trainerId: "synthetic-foe", snapshot: nil, publicInfo: snapshot.publicInfo, hpPercent: 0)
        let report = winner.map { OnlineBattleReport(readyToken: "t", engineHash: "h", terminalSeq: 5, winner: $0, logHash: "l", journalHash: "j", finalHp: .init(p1: 0, p2: 30)) }
        return .init(battleId: id, state: state, revision: 1, mode: .manual, p1: me == .p1 ? mine : theirs, p2: me == .p1 ? theirs : mine,
                     createdAt: createdAt, expiresAt: 9_999_999_999_999, startedAt: 0, reportedAt: nil, confirmed: false,
                     config: nil, roundSeq: 5, deadline: nil, ownChoice: nil, journal: [], result: report, reason: nil, rematchOf: rematchOf)
    }
    private func resultModel(_ kind: OnlineBattleUIResult.Kind = .loss, effects: OnlineBattleResultEffects? = .init(instanceID: "synthetic-pikachu", xp: 0, hpShare: 0),
                             others: [OnlineBattleView] = []) -> (OnlineBattlePresentation, OnlineBattleView) {
        let source = view(Self.sourceID, .completed, winner: kind == .win ? .p1 : .p2)
        let model = OnlineBattleScreenRenderingTests.model()
        model.battles = [source] + others; model.room = source; model.phase = .result
        model.result = .init(kind: kind, effects: effects)
        return (model, source)
    }
    /// The golden battle as the finished room, seen by its first player, with the real staged rounds behind it.
    private func adoptGolden(_ model: OnlineBattlePresentation, _ arena: OnlineBattleArenaFixture.Arena, rematch state: OnlineBattleState? = nil) throws {
        model.account = .init(trainer: .init(trainerId: "trainer-one", displayEmail: "나래", role: .member, status: .active),
                              group: .init(groupId: "synthetic-group", name: "동료들의 배틀", hostTrainerId: "trainer-two"))
        model.members = [.init(trainerId: "trainer-two", displayEmail: "연습친구", role: .host, status: .active, joinedAt: 0, online: true)]
        model.room = arena.battle; model.localSide = .p1
        var listed = [arena.battle]
        if let state {
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(arena.battle)) as? [String: Any])
            json["battleId"] = "golden-rematch"; json["state"] = state.rawValue; json["rematchOf"] = arena.battle.battleId
            json["p1"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(arena.battle.p2))
            json["p2"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(arena.battle.p1))
            json["result"] = NSNull(); json["createdAt"] = arena.battle.createdAt + 1000
            listed.append(try JSONDecoder().decode(OnlineBattleView.self, from: JSONSerialization.data(withJSONObject: json)))
        }
        model.battles = listed
    }
    private func rematch(me: OnlineBattleSide, state: OnlineBattleState = .pending) -> OnlineBattleView {
        view("synthetic-rematch", state, me: me, createdAt: 1_793_683_600_000, rematchOf: Self.sourceID)
    }

    private func host(_ model: OnlineBattlePresentation, l: L = L(.ko)) async -> NSView {
        let provider = OnlineBattleSyntheticNameProvider()
        let names = PokemonNameDisplayStore()
        for id in [25, 129] { _ = await names.load(.init(kind: .pokemonSpecies, name: String(id)), provider: provider) }
        let host = NSHostingView(rootView: OnlineBattleScreen(model: model, l: l, artwork: false, speciesNameProvider: provider,
                                                             speciesNameStore: names, onClose: {})
            .background(Color.white).environment(\.colorScheme, .light))
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 610)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 360, height: 610), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
        window.contentView = host; window.orderFront(nil); self.window = window
        try? await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        return host
    }
    private func settle(_ host: NSView) async {
        try? await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
    }
    private func capture(_ host: NSView, named name: String) async throws -> Data {
        await settle(host)
        XCTAssertEqual(host.fittingSize.width, 360, accuracy: 0.5)
        let bitmap = try PracticeScreenRenderingTests.capture2x(host)
        XCTAssertEqual(bitmap.pixelsWide, 720)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 8000, "A blank hosting view must not pass as a rendered stage")
        if let path = ProcessInfo.processInfo.environment["PTB_SNAPSHOT_SCREENSHOT_DIR"] {
            let directory = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(name))
        }
        return data
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    /// Top to bottom. The first is always the header's Home button.
    private func buttons(in host: NSView) -> [NSButton] {
        func top(_ button: NSButton) -> CGFloat {
            let y = host.convert(button.bounds, from: button).minY
            return host.isFlipped ? y : -y
        }
        return descendants(host).compactMap { $0 as? NSButton }.sorted { top($0) < top($1) }
    }
    private func screen(_ model: OnlineBattlePresentation, _ l: L? = nil, file: StaticString = #filePath, line: UInt = #line) throws -> OnlineBattleResultScreen {
        try XCTUnwrap(model.resultScreen(l: l ?? ko), "no result screen", file: file, line: line)
    }
    private func hasHangul(_ text: String) -> Bool { text.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) } }

    // MARK: the loss

    func testALossRendersItsLocalizedTitleTheFaintedLineAndTheRematchButton() async throws {
        let (model, _) = resultModel(.loss)
        let shown = try screen(model)
        XCTAssertEqual(shown.title, ko.onlineResultTitle(.loss))
        XCTAssertEqual(shown.title, "패배")
        XCTAssertEqual(shown.effects.count, 1)
        XCTAssertTrue(shown.effects.first?.contains("기절했어요") == true, "the receipt says 0 HP: \(shown.effects)")
        XCTAssertFalse(shown.effects.joined().contains("경험치"), "a loss has no XP line")
        XCTAssertEqual(shown.rematch, .request(enabled: true))
        XCTAssertNil(shown.note)
        XCTAssertTrue(shown.opponent.contains("연습친구"))
        let host = await host(model)
        XCTAssertEqual(buttons(in: host).count, 3, "Home, the rematch and back to the lobby")
        _ = try await capture(host, named: "t19-result-loss.png")
        let english = try screen(model, L(.en))
        XCTAssertEqual(english.title, "Defeat")
        XCTAssertFalse(hasHangul(english.title + english.effects.joined() + (english.note ?? "")), "\(english)")
        let englishHost = await self.host(model, l: L(.en))
        XCTAssertEqual(buttons(in: englishHost).count, 3)
    }

    func testPressingTheRematchButtonOpensTheDraftForThisBattle() async throws {
        let (model, _) = resultModel(.win, effects: .init(instanceID: "synthetic-pikachu", xp: 10_000_000, hpShare: 0.8))
        var sent: [String] = []
        model.onAction = { action in if case .prepareRematch(let id) = action { sent.append(id) }; if case .dismissResult = action { sent.append("dismiss") } }
        let host = await host(model)
        let all = buttons(in: host)
        XCTAssertEqual(all.count, 3)
        guard all.count == 3 else { return }
        all[1].performClick(nil)
        XCTAssertEqual(sent, [Self.sourceID])
        all[2].performClick(nil)
        XCTAssertEqual(sent, [Self.sourceID, "dismiss"])
    }

    // MARK: waiting

    func testAfterTheRequestTheSameButtonWaitsAndCancelsTheRematchRoom() async throws {
        let (model, _) = resultModel(.loss, others: [rematch(me: .p1)])
        XCTAssertEqual(try screen(model).rematch, .waiting(label: ko.onlineRematchWaitingCancel("연습친구"), battleID: "synthetic-rematch"),
                       "the request button is gone while one is out")
        var sent: [String] = []
        model.onAction = { action in if case .cancel(let id) = action { sent.append("cancel \(id)") }; if case .prepareRematch = action { sent.append("prepare") } }
        let host = await host(model)
        let all = buttons(in: host)
        XCTAssertEqual(all.count, 3)
        guard all.count == 3 else { return }
        all[1].performClick(nil)
        XCTAssertEqual(sent, ["cancel synthetic-rematch"], "cancel names the rematch room, not the result")
        _ = try await capture(host, named: "t19-result-waiting.png")
    }

    // MARK: a request over the result

    func testAnIncomingRematchShowsABannerWithAcceptAndLater() async throws {
        let (model, _) = resultModel(.loss, others: [rematch(me: .p2)])
        XCTAssertEqual(try screen(model).rematch, .answer(banner: ko.onlineRematchReceived("연습친구"), battleID: "synthetic-rematch"))
        var sent: [String] = []
        model.onAction = { action in
            if case .accept(let id) = action { sent.append("accept \(id)") }
            if case .deferRematch(let id) = action { sent.append("later \(id)") }
        }
        let host = await host(model)
        let all = buttons(in: host)
        XCTAssertEqual(all.count, 4, "Home, accept, later and back to the lobby")
        guard all.count == 4 else { return }
        let withBanner = try await capture(host, named: "t19-result-incoming.png")
        all[1].performClick(nil)
        all[2].performClick(nil)
        XCTAssertEqual(sent, ["accept synthetic-rematch", "later synthetic-rematch"])
        await settle(host)
        let later = try screen(model)
        XCTAssertEqual(later.rematch, .request(enabled: false), "later puts the banner away; asking again would cross their request")
        XCTAssertEqual(later.note, ko.onlineRematchBlockLine(.requestWaiting))
        XCTAssertEqual(buttons(in: host).count, 3)
        let after = try await capture(host, named: "t19-result-incoming-later.png")
        XCTAssertNotEqual(withBanner, after)
    }

    func testARematchThatMovedOnIsAnOpenRoomButton() async throws {
        let (model, _) = resultModel(.loss, others: [rematch(me: .p1, state: .accepted)])
        XCTAssertEqual(try screen(model).rematch, .open(battleID: "synthetic-rematch"))
        var followed: [String] = []
        model.onAction = { action in if case .followAttention(let id) = action { followed.append(id) } }
        let host = await host(model)
        let all = buttons(in: host)
        XCTAssertEqual(all.count, 3)
        guard all.count == 3 else { return }
        all[1].performClick(nil)
        XCTAssertEqual(followed, ["synthetic-rematch"])
    }

    // MARK: why it is off

    func testAFaintedTeamTurnsTheButtonOffAndSaysWhyBelowIt() async throws {
        let (model, _) = resultModel(.loss)
        model.entryHP = ["synthetic-pikachu": 0]
        let shown = try screen(model)
        XCTAssertEqual(shown.rematch, .request(enabled: false))
        XCTAssertEqual(shown.note, ko.onlineRematchBlockLine(.noHealthyPokemon))
        let host = await host(model)
        let all = buttons(in: host)
        XCTAssertEqual(all.count, 3)
        guard all.count == 3 else { return }
        XCTAssertFalse(all[1].isEnabled)
        XCTAssertTrue(all[2].isEnabled)
        _ = try await capture(host, named: "t19-result-blocked.png")
    }

    func testAnOfflineOpponentIsToldButTheButtonStaysOn() async throws {
        let (model, _) = resultModel(.win, effects: .init(instanceID: "synthetic-pikachu", xp: 10_000_000, hpShare: 0.8))
        model.members = [.init(trainerId: "synthetic-foe", displayEmail: "연습친구", role: .host, status: .active, joinedAt: 0, online: false)]
        let shown = try screen(model)
        XCTAssertEqual(shown.rematch, .request(enabled: true))
        XCTAssertEqual(shown.note, ko.onlineRematchOpponentOffline)
        let host = await host(model)
        XCTAssertTrue(buttons(in: host).dropFirst().first?.isEnabled == true)
    }

    // MARK: effects are the receipt's

    func testTheEffectLinesFollowTheReceiptAndAnOtherSaveRecordClaimsNone() async throws {
        let (win, _) = resultModel(.win, effects: .init(instanceID: "synthetic-pikachu", xp: 10_000_000, hpShare: 0.8))
        let winScreen = try screen(win)
        XCTAssertEqual(winScreen.effects, [ko.onlineXP(10_000_000), "남은 체력 80%를 반영했어요"])
        XCTAssertEqual(winScreen.title, "승리")
        _ = try await capture(await host(win), named: "t19-result-win.png")

        let (record, _) = resultModel(.record, effects: nil)
        let recordScreen = try screen(record)
        XCTAssertEqual(recordScreen.title, ko.onlineResultTitle(.record))
        XCTAssertEqual(recordScreen.effects, [])
        for claim in ["체력", "경험치", "기절"] {
            XCTAssertFalse((recordScreen.title + recordScreen.subtitle + (recordScreen.note ?? "")).contains(claim), claim)
        }
        _ = try await capture(await host(record), named: "t19-result-record.png")

        let (void, _) = resultModel(.void, effects: nil)
        void.room = view(Self.sourceID, .void)
        let voidScreen = try screen(void)
        XCTAssertEqual(voidScreen.title, ko.onlineResultTitle(.void))
        XCTAssertEqual(voidScreen.rematch, .none, "a voided match has no rematch")
        let voidHost = await host(void)
        XCTAssertEqual(buttons(in: voidHost).count, 2, "Home and back to the lobby")
        _ = try await capture(voidHost, named: "t19-result-void.png")
    }

    // MARK: totals

    func testTotalsShowOnlyWhenTheStageIsWhole() async throws {
        let arena = try OnlineBattleArenaFixture.arena(seat: .p1)
        defer { arena.close() }
        let (model, _) = resultModel(.win, effects: .init(instanceID: "synthetic-pikachu", xp: 10_000_000, hpShare: 0.8))
        try adoptGolden(model, arena)
        model.stage = arena.staging
        XCTAssertNil(try screen(model).totals, "nothing was staged")
        try arena.play(rounds: arena.battle.journal.count)
        arena.staging.skipToEnd()
        model.stage = arena.staging
        let totals = try XCTUnwrap(try screen(model).totals)
        XCTAssertGreaterThanOrEqual(totals.turns, arena.battle.result?.terminalSeq ?? Int.max)
        let host = await host(model)
        _ = try await capture(host, named: "t19-result-totals.png")
    }

    // MARK: fit

    func testTheHeaviestResultStillFitsTheScrollArea() async throws {
        let arena = try OnlineBattleArenaFixture.arena(seat: .p1)
        defer { arena.close() }
        let (model, _) = resultModel(.win, effects: .init(instanceID: "synthetic-pikachu", xp: 10_000_000, hpShare: 0.8))
        try adoptGolden(model, arena, rematch: .pending)
        try arena.play(rounds: arena.battle.journal.count); arena.staging.skipToEnd()
        model.stage = arena.staging
        model.members = [.init(trainerId: "trainer-two", displayEmail: String(repeating: "아주긴닉네임", count: 8), role: .host, status: .active, joinedAt: 0, online: true)]
        let heavy = try screen(model)
        guard case .answer = heavy.rematch else { return XCTFail("the heaviest state has the banner too: \(heavy.rematch)") }
        XCTAssertNotNil(heavy.totals)
        let probe = NSHostingView(rootView: OnlineBattleResultView(model: model, l: ko, artwork: false)
            .frame(width: PopoverMetrics.scrollContentWidth).background(Color.white))
        probe.frame = NSRect(x: 0, y: 0, width: PopoverMetrics.scrollContentWidth, height: 900)
        let probeWindow = NSWindow(contentRect: probe.frame, styleMask: .borderless, backing: .buffered, defer: false)
        probeWindow.isReleasedWhenClosed = false; probeWindow.contentView = probe; probeWindow.orderFront(nil); self.window = probeWindow
        try? await Task.sleep(for: .milliseconds(200))
        probe.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(probe.fittingSize.height, 520, "the result must not need the scroll bar in its heaviest state")
        XCTAssertEqual(probe.fittingSize.width, PopoverMetrics.scrollContentWidth, accuracy: 0.5)
    }
}
