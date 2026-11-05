import AppKit
import SwiftUI
import XCTest
@testable import PokeTokenBar

/// T19 on the real screen: the result's controls follow the rematch beside it. Synthetic data only. What the screen
/// says and what each control sends is read from `resultScreen(l:)`, which the view draws without adding words or
/// logic; SwiftUI keeps bordered buttons out of the AppKit tree, so nothing here presses or searches pixels for small
/// text. The renders prove each state draws, differs from the others and fits. Set PTB_SNAPSHOT_SCREENSHOT_DIR to keep
/// the 720px PNGs.
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
                             others: [OnlineBattleView] = []) -> OnlineBattlePresentation {
        let source = view(Self.sourceID, .completed, winner: kind == .win ? .p1 : .p2)
        let model = OnlineBattleScreenRenderingTests.model()
        model.battles = [source] + others; model.room = source; model.phase = .result
        model.result = .init(kind: kind, effects: effects)
        return model
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
        window.contentView = host; window.orderFront(nil); self.window?.close(); self.window = window
        try? await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        return host
    }
    private func capture(_ model: OnlineBattlePresentation, l: L = L(.ko), named name: String) async throws -> Data {
        let host = await host(model, l: l)
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
    private func screen(_ model: OnlineBattlePresentation, _ l: L? = nil, file: StaticString = #filePath, line: UInt = #line) throws -> OnlineBattleResultScreen {
        try XCTUnwrap(model.resultScreen(l: l ?? ko), "no result screen", file: file, line: line)
    }
    private func hasHangul(_ text: String) -> Bool { text.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) } }

    // MARK: the loss

    func testALossRendersItsLocalizedTitleTheFaintedLineAndTheRematchButton() async throws {
        let model = resultModel(.loss)
        let shown = try screen(model)
        XCTAssertEqual(shown.title, ko.onlineResultTitle(.loss))
        XCTAssertEqual(shown.title, "패배")
        XCTAssertEqual(shown.effects.count, 1)
        XCTAssertTrue(shown.effects.first?.contains("기절했어요") == true, "the receipt says 0 HP: \(shown.effects)")
        XCTAssertFalse(shown.effects.joined().contains("경험치"), "a loss has no XP line")
        XCTAssertEqual(shown.rematch, .request(enabled: true))
        XCTAssertTrue(shown.primaryEnabled)
        XCTAssertNil(shown.note)
        XCTAssertTrue(shown.opponent.contains("연습친구"))
        guard case .prepareRematch(let id)? = shown.primaryAction else { return XCTFail("the main button asks for a rematch: \(String(describing: shown.primaryAction))") }
        XCTAssertEqual(id, Self.sourceID, "it names the finished room")
        XCTAssertNil(shown.secondaryAction)
        let korean = try await capture(model, named: "t19-result-loss.png")
        let english = try screen(model, L(.en))
        XCTAssertEqual(english.title, "Defeat")
        XCTAssertTrue(english.effects.first?.contains("fainted") == true, "\(english.effects)")
        XCTAssertFalse(hasHangul(english.title + (english.note ?? "")), "\(english)")
        let englishData = try await capture(model, l: L(.en), named: "t19-result-loss-en.png")
        XCTAssertNotEqual(korean, englishData, "the view draws the language it is given")
    }

    // MARK: waiting

    func testAfterTheRequestTheSameButtonWaitsAndCancelsTheRematchRoom() async throws {
        let model = resultModel(.loss, others: [rematch(me: .p1)])
        let before = try await capture(resultModel(.loss), named: "t19-result-before-request.png")
        let shown = try screen(model)
        XCTAssertEqual(shown.rematch, .waiting(label: ko.onlineRematchWaitingCancel("연습친구"), battleID: "synthetic-rematch"),
                       "the request button is gone while one is out")
        XCTAssertTrue(shown.primaryEnabled)
        guard case .cancel(let id)? = shown.primaryAction else { return XCTFail("the same button now cancels: \(String(describing: shown.primaryAction))") }
        XCTAssertEqual(id, "synthetic-rematch", "cancel names the rematch room, not the result")
        var sent: [String] = []
        model.onAction = { action in if case .cancel(let id) = action { sent.append("cancel \(id)") } }
        model.send(.cancel(id))
        XCTAssertEqual(sent, ["cancel synthetic-rematch"])
        let waiting = try await capture(model, named: "t19-result-waiting.png")
        XCTAssertNotEqual(before, waiting)
    }

    // MARK: a request over the result

    func testAnIncomingRematchShowsABannerWithAcceptAndLater() async throws {
        let model = resultModel(.loss, others: [rematch(me: .p2)])
        let shown = try screen(model)
        XCTAssertEqual(shown.rematch, .answer(banner: ko.onlineRematchReceived("연습친구"), battleID: "synthetic-rematch"))
        XCTAssertEqual(shown.note, ko.onlineRematchAnswerEntry("피카츄"), "who enters is said next to the button")
        var sent: [String] = []
        model.onAction = { action in
            if case .accept(let id) = action { sent.append("accept \(id)") }
            if case .deferRematch = action { sent.append("later reached the session") }
        }
        guard case .accept(let acceptID)? = shown.primaryAction, case .deferRematch(let laterID)? = shown.secondaryAction else {
            return XCTFail("accept and later: \(String(describing: shown.primaryAction)) \(String(describing: shown.secondaryAction))")
        }
        XCTAssertEqual([acceptID, laterID], ["synthetic-rematch", "synthetic-rematch"])
        let withBanner = try await capture(model, named: "t19-result-incoming.png")
        model.send(.accept(acceptID))
        model.send(.deferRematch(laterID))
        XCTAssertEqual(sent, ["accept synthetic-rematch"], "later is pure presentation and sends nothing")
        XCTAssertEqual(model.deferredRematchIDs, ["synthetic-rematch"])
        let later = try screen(model)
        XCTAssertEqual(later.rematch, .request(enabled: false), "later puts the banner away; asking again would cross their request")
        XCTAssertFalse(later.primaryEnabled)
        XCTAssertEqual(later.note, ko.onlineRematchBlockLine(.requestWaiting))
        let after = try await capture(model, named: "t19-result-incoming-later.png")
        XCTAssertNotEqual(withBanner, after)
    }

    func testARequestWithNobodyHealthyCannotBeAcceptedAndSaysWhy() throws {
        let model = resultModel(.loss, others: [rematch(me: .p2)])
        model.entryHP = ["synthetic-pikachu": 0]
        let shown = try screen(model)
        XCTAssertEqual(shown.note, ko.onlineRematchBlockLine(.noHealthyPokemon))
        var reached = false
        model.onAction = { _ in reached = true }
        model.send(.accept("synthetic-rematch"))
        XCTAssertFalse(reached, "nobody can enter, so accepting is refused before it is sent")
    }

    func testARematchThatMovedOnIsAnOpenRoomButton() throws {
        let model = resultModel(.loss, others: [rematch(me: .p1, state: .accepted)])
        let shown = try screen(model)
        XCTAssertEqual(shown.rematch, .open(battleID: "synthetic-rematch"))
        guard case .followAttention(let id)? = shown.primaryAction else { return XCTFail("\(String(describing: shown.primaryAction))") }
        XCTAssertEqual(id, "synthetic-rematch")
    }

    // MARK: why it is off

    func testAFaintedTeamTurnsTheButtonOffAndSaysWhyBelowIt() async throws {
        let model = resultModel(.loss)
        model.entryHP = ["synthetic-pikachu": 0]
        let shown = try screen(model)
        XCTAssertEqual(shown.rematch, .request(enabled: false))
        XCTAssertFalse(shown.primaryEnabled)
        XCTAssertEqual(shown.note, ko.onlineRematchBlockLine(.noHealthyPokemon))
        var reached = false
        model.onAction = { _ in reached = true }
        model.send(.prepareRematch(Self.sourceID))
        XCTAssertFalse(reached, "an off button sends nothing even if something presses it")
        let blocked = try await capture(model, named: "t19-result-blocked.png")
        let ready = try await capture(resultModel(.loss), named: "t19-result-ready.png")
        XCTAssertNotEqual(blocked, ready)
    }

    func testAnOfflineOpponentIsToldButTheButtonStaysOn() throws {
        let model = resultModel(.win, effects: .init(instanceID: "synthetic-pikachu", xp: 10_000_000, hpShare: 0.8))
        model.members = [.init(trainerId: "synthetic-foe", displayEmail: "연습친구", role: .host, status: .active, joinedAt: 0, online: false)]
        let shown = try screen(model)
        XCTAssertEqual(shown.rematch, .request(enabled: true))
        XCTAssertTrue(shown.primaryEnabled)
        XCTAssertEqual(shown.note, ko.onlineRematchOpponentOffline)
    }

    // MARK: effects are the receipt's

    func testTheEffectLinesFollowTheReceiptAndAnOtherSaveRecordClaimsNone() async throws {
        let win = resultModel(.win, effects: .init(instanceID: "synthetic-pikachu", xp: 10_000_000, hpShare: 0.8))
        let winScreen = try screen(win)
        XCTAssertEqual(winScreen.effects, [ko.onlineXP(10_000_000), "남은 체력 80%를 반영했어요"])
        XCTAssertEqual(winScreen.title, "승리")
        let winData = try await capture(win, named: "t19-result-win.png")

        let record = resultModel(.record, effects: nil)
        let recordScreen = try screen(record)
        XCTAssertEqual(recordScreen.title, ko.onlineResultTitle(.record))
        XCTAssertEqual(recordScreen.effects, [])
        for claim in ["체력", "경험치", "기절"] {
            XCTAssertFalse((recordScreen.title + recordScreen.subtitle + (recordScreen.note ?? "")).contains(claim), claim)
        }
        let recordData = try await capture(record, named: "t19-result-record.png")

        let void = resultModel(.void, effects: nil)
        void.room = view(Self.sourceID, .void)
        let voidScreen = try screen(void)
        XCTAssertEqual(voidScreen.title, ko.onlineResultTitle(.void))
        XCTAssertEqual(voidScreen.rematch, .none, "a voided match has no rematch")
        XCTAssertNil(voidScreen.primaryAction)
        let voidData = try await capture(void, named: "t19-result-void.png")
        XCTAssertNotEqual(winData, recordData); XCTAssertNotEqual(recordData, voidData)

        let draw = resultModel(.draw, effects: .init(instanceID: "synthetic-pikachu", xp: 0, hpShare: 0.5))
        XCTAssertEqual(try screen(draw).effects, ["남은 체력 50%를 반영했어요"])
        _ = try await capture(draw, named: "t19-result-draw.png")
    }

    // MARK: totals

    func testTotalsShowOnlyWhenTheStageIsWhole() async throws {
        let arena = try OnlineBattleArenaFixture.arena(seat: .p1)
        defer { arena.close() }
        let model = resultModel(.win, effects: .init(instanceID: "synthetic-pikachu", xp: 10_000_000, hpShare: 0.8))
        try adoptGolden(model, arena)
        model.stage = arena.staging
        XCTAssertNil(try screen(model).totals, "nothing was staged")
        let bare = try await capture(model, named: "t19-result-without-totals.png")
        try arena.play(rounds: arena.battle.journal.count)
        arena.staging.skipToEnd()
        model.stage = arena.staging
        let totals = try XCTUnwrap(try screen(model).totals)
        XCTAssertGreaterThanOrEqual(totals.turns, arena.battle.result?.terminalSeq ?? Int.max)
        let withTotals = try await capture(model, named: "t19-result-totals.png")
        XCTAssertNotEqual(bare, withTotals)
    }

    // MARK: fit

    func testTheHeaviestResultStillFitsTheScrollArea() async throws {
        let arena = try OnlineBattleArenaFixture.arena(seat: .p1)
        defer { arena.close() }
        let model = resultModel(.win, effects: .init(instanceID: "synthetic-pikachu", xp: 10_000_000, hpShare: 0.8))
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
        _ = try await capture(model, named: "t19-result-heaviest.png")
    }
}

// MARK: - Review C, F4 item 2: crossed requests on the result screen

extension OnlineBattleResultRenderingTests {
    /// Both seats asked at once and my own request holds the only Pokémon. The banner fits with its extra button, says
    /// what is really in the way and lets me cancel mine.
    func testCrossedRequestsDrawTheWayOutInBothLanguages() async throws {
        let mine = view("synthetic-mine", .pending, me: .p1, createdAt: 1_793_683_550_000, rematchOf: Self.sourceID)
        let theirs = view("synthetic-theirs", .pending, me: .p2, createdAt: 1_793_683_600_000, rematchOf: Self.sourceID)
        let model = resultModel(.win, effects: .init(instanceID: "synthetic-pikachu", xp: 10_000_000, hpShare: 0.42), others: [mine, theirs])
        model.blockedEntryIDs = Set(model.roster.map(\.id))
        for (l, name) in [(ko, "f4-result-crossed-ko.png"), (L(.en), "f4-result-crossed-en.png")] {
            let shown = try screen(model, l)
            XCTAssertEqual(shown.cancelOwnRequest, "synthetic-mine")
            XCTAssertEqual(shown.note, l.onlineRematchCrossedNote)
            XCTAssertNotEqual(shown.note, l.onlineRematchBlockLine(.noHealthyPokemon))
            XCTAssertFalse(model.canAccept(model.actionRoom("synthetic-theirs")))
            _ = try await capture(model, l: l, named: name)
        }
        var sent: [String] = []
        model.onAction = { if case .cancel(let id) = $0 { sent.append(id) } }
        model.send(.cancel("synthetic-mine"))
        XCTAssertEqual(sent, ["synthetic-mine"], "a room action may name my own crossed request")
    }
}
