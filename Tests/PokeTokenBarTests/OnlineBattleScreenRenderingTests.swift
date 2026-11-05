import AppKit
import SwiftUI
import Vision
import XCTest
@testable import PokeTokenBar

/// Synthetic data only. No network, Keychain, real saves or OCR; optional PNGs are native SwiftUI renders.
@MainActor
final class OnlineBattleScreenRenderingTests: XCTestCase {
    private struct Golden: Decodable { let battle: OnlineBattleView }
    private var window: NSWindow?
    override func tearDown() async throws { window?.close(); window = nil }

    static func snapshot(_ id: String = "synthetic-pikachu") -> BattleSnapshot {
        .init(schemaVersion: 1, instanceID: id, engineHash: "synthetic", rulesVersion: BattleSnapshot.rules,
              policyVersion: BattleSnapshot.policy,
              set: .init(speciesNum: 25, form: nil, level: 50, gender: .male, nature: "Hardy", ability: "static",
                         moves: ["thunderbolt", "quick-attack"], ivs: [:], shiny: false),
              publicInfo: .init(speciesNum: 25, species: "Pikachu", level: 50, types: ["Electric"],
                                stats: ["hp": 110, "atk": 75, "def": 60, "spa": 70, "spd": 70, "spe": 110]))
    }
    static func room(state: OnlineBattleState = .running, mode: OnlineBattleMode = .manual, confirmed: Bool = true,
                     id: String = "synthetic-battle", createdAt: Double = 1_793_683_500_000) -> OnlineBattleView {
        let snapshot = snapshot()
        return .init(battleId: id, state: state, revision: 1, mode: mode,
                     p1: .init(trainerId: "synthetic-me", snapshot: .init(snapshot: snapshot, hp: 88), publicInfo: nil, hpPercent: nil),
                     p2: .init(trainerId: "synthetic-foe", snapshot: nil, publicInfo: snapshot.publicInfo, hpPercent: 90),
                     createdAt: createdAt, expiresAt: 100, startedAt: 0, reportedAt: nil, confirmed: confirmed,
                     config: nil, roundSeq: 1, deadline: nil, ownChoice: nil, journal: [], result: nil, reason: nil, rematchOf: nil)
    }
    static func model() -> OnlineBattlePresentation {
        let model = OnlineBattlePresentation()
        model.serverAddress = "https://battle.example.invalid"
        model.account = .init(trainer: .init(trainerId: "synthetic-me", displayEmail: "나래", role: .member, status: .active),
                              group: .init(groupId: "synthetic-group", name: "동료들의 배틀", hostTrainerId: "synthetic-foe"))
        model.members = [.init(trainerId: "synthetic-foe", displayEmail: "연습친구", role: .host, status: .active,
                               joinedAt: 0, online: true)]
        let snapshot = snapshot()
        model.roster = [.init(id: snapshot.instanceID, name: "피카츄", snapshot: snapshot, blockedReason: nil)]
        model.entryHP = [snapshot.instanceID: 88]
        model.selectedEntryID = snapshot.instanceID
        model.selectedOpponentID = "synthetic-foe"
        model.battles = [room(state: .pending, confirmed: false)]
        return model
    }
    static func arena(_ model: OnlineBattlePresentation) {
        model.phase = .arena; model.room = room()
        model.deadline = Date().addingTimeInterval(30)
        model.moveSlugs = [.p1: ["thunderbolt": "thunderbolt", "quickattack": "quick-attack"], .p2: ["splash": "splash"]]
        model.abilitySlugs = [.p1: ["static": "static"]]
        model.arena = .init(turn: 3, ended: false,
                            p1: .init(speciesNum: 25, species: "Pikachu", level: 50, types: ["Electric"], hp: 88, maxhp: 110,
                                      status: "", moves: ["thunderbolt", "quickattack"], ability: "static"),
                            p2: .init(speciesNum: 129, species: "Magikarp", level: 50, types: ["Water"], hp: 42, maxhp: 100,
                                      status: "", moves: ["splash"], ability: nil))
        model.request = .init(kind: "move", moves: [
            .init(slot: 1, id: "thunderbolt", name: "Thunderbolt", type: "Electric", pp: 14, maxpp: 15, disabled: false),
            .init(slot: 2, id: "quickattack", name: "Quick Attack", type: "Normal", pp: 30, maxpp: 30, disabled: false)])
    }

    private func host(_ model: OnlineBattlePresentation, clipboard: @escaping () -> String? = { nil },
                      onClose: @escaping () -> Void = {}, onClosePopover: @escaping () -> Void = {}) async -> NSView {
        let provider = OnlineBattleSyntheticNameProvider()
        let names = PokemonNameDisplayStore()
        for id in [25, 129] { _ = await names.load(.init(kind: .pokemonSpecies, name: String(id)), provider: provider) }
        let host = NSHostingView(rootView: OnlineBattleScreen(model: model, l: L(.ko), artwork: false, readInvitationClipboard: clipboard,
                                                             speciesNameProvider: provider, speciesNameStore: names,
                                                             onClosePopover: onClosePopover, onClose: onClose)
            .background(Color.white).environment(\.colorScheme, .light))
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 610)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 360, height: 610),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
        window.contentView = host; window.orderFront(nil); self.window = window
        return host
    }
    private func capture(_ host: NSView, named name: String) async throws -> Data {
        try await Task.sleep(for: .milliseconds(120))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.fittingSize.width, 360, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(host.fittingSize.height, 596)
        XCTAssertLessThanOrEqual(host.fittingSize.height, 628)
        let bitmap = try PracticeScreenRenderingTests.capture2x(host)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 8000, "A blank hosting view must not pass as a rendered stage")
        if let path = ProcessInfo.processInfo.environment["PTB_SNAPSHOT_SCREENSHOT_DIR"] {
            let directory = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(name))
        }
        return data
    }
    private func editableFields(in view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { $0.isEditable ? [$0] : [] } ?? view.subviews.flatMap { editableFields(in: $0) }
    }
    private func enter(_ value: String, into field: NSTextField) {
        field.stringValue = value
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
    }
    private func settle(_ host: NSView) async throws {
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
    }
    func testOnlineBattleSetupDraftSurvivesActualHostingViewRecreation() async throws {
        let model = OnlineBattlePresentation()
        model.serverAddress = "https://saved.example.invalid"
        model.setupRecoveryExpanded = true
        model.setupAdvancedExpanded = true
        var first: NSView? = await host(model)
        _ = try await capture(try XCTUnwrap(first), named: "online-synthetic-setup-before-edit.png")
        let fields = editableFields(in: try XCTUnwrap(first))
        XCTAssertEqual(fields.count, 5)
        guard fields.count == 5 else { return }
        // Nickname, invite code, the two recovery fields, then the advanced server address last.
        enter("나래", into: fields[0])
        enter("ABCD-EFGH-JKMN", into: fields[1])
        enter("synthetic-recovery", into: fields[2]); enter("synthetic-reconnect", into: fields[3])
        enter("https://draft.example.invalid", into: fields[4])
        _ = try await capture(try XCTUnwrap(first), named: "online-synthetic-setup-draft-before-close.png")
        window?.contentView = nil; window?.close(); window = nil; first = nil
        let recreated = await host(model)
        _ = try await capture(recreated, named: "online-synthetic-setup-draft-after-reopen.png")
        XCTAssertEqual(editableFields(in: recreated).map(\.stringValue),
                       ["나래", "ABCD-EFGH-JKMN", "synthetic-recovery", "synthetic-reconnect", "https://draft.example.invalid"])
    }
    func testEmbeddedSetupShowsOnlyNicknameAndInviteCodeWithNoServerControls() async throws {
        let model = OnlineBattlePresentation()
        model.serverAddress = "https://embedded.example.invalid"; model.serverIsEmbedded = true
        model.setupInput.server = model.serverAddress
        // A stale 'advanced open' flag from a manual build must not bring the server field back.
        model.setupAdvancedExpanded = true
        let host = await host(model)
        _ = try await capture(host, named: "online-synthetic-setup-embedded.png")
        XCTAssertEqual(editableFields(in: host).count, 2, "nickname and invite code only")
        model.setupRecoveryExpanded = true
        try await settle(host)
        XCTAssertEqual(editableFields(in: host).count, 4, "recovery stays reachable below the join path")
        model.setupInput.nickname = "나래"; model.setupInput.invite = "ABCD-EFGH-JKMN"
        _ = try await capture(host, named: "online-synthetic-setup-embedded-ready.png")
    }
    func testManualSetupKeepsServerEntryCollapsedUnderAdvanced() async throws {
        let model = OnlineBattlePresentation()
        let host = await host(model)
        _ = try await capture(host, named: "online-synthetic-setup-manual-collapsed.png")
        XCTAssertEqual(editableFields(in: host).count, 2, "the server address stays hidden until Advanced is opened")
        model.setupAdvancedExpanded = true
        try await settle(host)
        XCTAssertEqual(editableFields(in: host).count, 3)
        XCTAssertEqual(editableFields(in: host).last?.stringValue, "")
        _ = try await capture(host, named: "online-synthetic-setup-manual-advanced.png")
    }
    private func clickPasteButton(in host: NSView) throws {
        let window = try XCTUnwrap(host.window)
        // The first setup action sits right under the headline; no OCR or system input access.
        let hostPoint = NSPoint(x: 80, y: host.isFlipped ? 88 : host.bounds.height - 88)
        // Where this button is an NSButton, a mouse-down starts a tracking loop that waits for a mouse-up, and a
        // synchronous sendEvent can never deliver it: the test would hang. Press that one directly.
        var hit = host.hitTest(host.convert(hostPoint, to: host.superview))
        while let current = hit, !(current is NSButton) { hit = current.superview }
        if let button = hit as? NSButton { button.performClick(nil); return }
        // Other systems draw it without an NSButton, so native mouse events are the way in.
        let point = host.convert(hostPoint, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                       windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            window.sendEvent(event)
        }
    }
    // MARK: T05 pinned header

    /// SwiftUI borderless buttons are `SwiftUIAppKitButton` views; the header ones sit above the scroll area.
    private func headerButtons(in view: NSView) -> [NSButton] {
        let found = (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { headerButtons(in: $0) }
        return found.filter { headerBand($0) }
    }
    private func headerBand(_ button: NSButton) -> Bool {
        guard let root = button.window?.contentView else { return false }
        return root.convert(button.bounds, from: button).midY < 44 || root.convert(button.bounds, from: button).midY > root.bounds.height - 44
    }
    private func pinnedModel(_ pinned: Bool) -> OnlineBattlePresentation {
        let model = Self.model()
        model.phase = .room; model.room = Self.room(state: .pending, confirmed: false)
        model.popoverPinned = pinned
        return model
    }
    func testPinnedHeaderAddsOneCloseButtonAndLeavesEverythingBelowItUntouched() async throws {
        let unpinnedHost = await host(pinnedModel(false))
        _ = try await capture(unpinnedHost, named: "online-synthetic-unpinned-header.png")
        let before = try PracticeScreenRenderingTests.capture2x(unpinnedHost)
        XCTAssertEqual(headerButtons(in: unpinnedHost).count, 1, "only the Home button")
        window?.close()
        let pinnedHost = await host(pinnedModel(true))
        _ = try await capture(pinnedHost, named: "online-synthetic-pinned-header.png")
        let after = try PracticeScreenRenderingTests.capture2x(pinnedHost)
        XCTAssertEqual(headerButtons(in: pinnedHost).count, 2, "Home plus the visible close button")
        XCTAssertEqual(after.pixelsWide, before.pixelsWide); XCTAssertEqual(after.pixelsHigh, before.pixelsHigh)
        // 360pt layout stays stable: the marker and close button live in the header strip, nothing else moves.
        let bytesPerRow = before.bytesPerRow, headerRows = 2 * 48
        let below = headerRows * bytesPerRow..<before.pixelsHigh * bytesPerRow
        XCTAssertEqual(Array(UnsafeBufferPointer(start: before.bitmapData, count: before.pixelsHigh * bytesPerRow))[below],
                       Array(UnsafeBufferPointer(start: after.bitmapData, count: after.pixelsHigh * bytesPerRow))[below])
        let above = 0..<headerRows * bytesPerRow
        XCTAssertNotEqual(Array(UnsafeBufferPointer(start: before.bitmapData, count: headerRows * bytesPerRow))[above],
                          Array(UnsafeBufferPointer(start: after.bitmapData, count: headerRows * bytesPerRow))[above], "the marker is drawn")
    }
    func testCloseButtonClosesThePopoverAndNotJustTheScreen() async throws {
        var closed = 0, backed = 0
        let host = await host(pinnedModel(true), onClose: { backed += 1 }, onClosePopover: { closed += 1 })
        _ = try await capture(host, named: "online-synthetic-pinned-close.png")
        let buttons = headerButtons(in: host).sorted { $0.frame.minX < $1.frame.minX }
        XCTAssertEqual(buttons.count, 2)
        buttons.last?.performClick(nil)
        XCTAssertEqual(closed, 1); XCTAssertEqual(backed, 0)
    }
    func testEscapeClosesThePopoverWhilePinnedAndGoesBackToHomeOtherwise() async throws {
        func escape(_ host: NSView) throws {
            let window = try XCTUnwrap(host.window)
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                                     isARepeat: false, keyCode: 53))
            XCTAssertTrue(window.performKeyEquivalent(with: event))
        }
        var closed = 0, backed = 0
        let pinned = await host(pinnedModel(true), onClose: { backed += 1 }, onClosePopover: { closed += 1 })
        _ = try await capture(pinned, named: "online-synthetic-pinned-escape.png")
        try escape(pinned)
        XCTAssertEqual(closed, 1); XCTAssertEqual(backed, 0)
        window?.close()
        var closed2 = 0, backed2 = 0
        let plain = await host(pinnedModel(false), onClose: { backed2 += 1 }, onClosePopover: { closed2 += 1 })
        _ = try await capture(plain, named: "online-synthetic-unpinned-escape.png")
        try escape(plain)
        XCTAssertEqual(closed2, 0); XCTAssertEqual(backed2, 1)
    }

    func testOnlineBattleEmbeddedPasteReadsOnlyOnExplicitClickAndTakesAOneLineCode() async throws {
        let model = OnlineBattlePresentation()
        model.serverAddress = "https://saved.example.invalid"; model.serverIsEmbedded = true
        model.setupInput = .init(server: model.serverAddress, invite: "old", nickname: "나래")
        let original = model.setupInput
        var reads = 0, actions = 0
        var clipboard = "invalid"
        model.onAction = { _ in actions += 1 }
        let host = await host(model, clipboard: { reads += 1; return clipboard })
        _ = try await capture(host, named: "online-synthetic-setup-paste-before.png")
        XCTAssertEqual(reads, 0, "the clipboard is never read without a click")
        try clickPasteButton(in: host)
        XCTAssertEqual(reads, 1); XCTAssertEqual(model.setupInput, original); XCTAssertEqual(model.setupPasteFailure, .noInviteCode)
        try await settle(host)
        _ = try await capture(host, named: "online-synthetic-setup-paste-failed.png")
        clipboard = "  abcd-efgh-jkmn \n"
        try clickPasteButton(in: host)
        _ = try await capture(host, named: "online-synthetic-setup-paste-after.png")
        XCTAssertEqual(reads, 2); XCTAssertEqual(actions, 0)
        XCTAssertEqual(model.setupInput.invite, "ABCDEFGHJKMN"); XCTAssertEqual(model.setupInput.nickname, "나래")
        XCTAssertEqual(model.setupInput.server, "https://saved.example.invalid")
        XCTAssertNil(model.setupPasteFailure)
        XCTAssertEqual(editableFields(in: host).prefix(2).map(\.stringValue), ["나래", "ABCDEFGHJKMN"])
    }
    func testOnlineBattleManualPasteTakesTwoLinesAndNeverAppliesOrJoins() async throws {
        let model = OnlineBattlePresentation()
        model.serverAddress = "https://saved.example.invalid"
        model.setupInput = .init(server: model.serverAddress, invite: "old", nickname: "나래")
        var reads = 0, actions = 0
        var clipboard = "ABCD-EFGH-JKMN\nhttp://insecure.example.invalid"
        model.onAction = { _ in actions += 1 }
        let host = await host(model, clipboard: { reads += 1; return clipboard })
        try await settle(host)
        XCTAssertEqual(reads, 0)
        try clickPasteButton(in: host)
        XCTAssertEqual(model.setupPasteFailure, .invalidServer)
        XCTAssertEqual(model.setupInput, .init(server: model.serverAddress, invite: "old", nickname: "나래"))
        clipboard = "서버 주소: https://next.example.invalid\n초대코드: ABCD-EFGH-JKMN"
        try clickPasteButton(in: host)
        XCTAssertEqual(reads, 2); XCTAssertEqual(actions, 0)
        XCTAssertEqual(model.serverAddress, "https://saved.example.invalid", "paste never applies the address")
        XCTAssertEqual(model.setupInput.server, "https://next.example.invalid")
        XCTAssertEqual(model.setupInput.invite, "ABCDEFGHJKMN"); XCTAssertEqual(model.setupInput.nickname, "나래")
        XCTAssertNil(model.setupPasteFailure)
        guard case .applyingServer? = model.setupInput.joinAction(appliedServer: model.serverAddress, isBusy: false, serverIsEmbedded: false) else {
            return XCTFail("join applies the pasted address itself")
        }
    }
    func testSyntheticSetupLobbyArenaAndResultRenderInsidePopover() async throws {
        let model = Self.model()
        let host = await host(model)
        let setup = try await capture(host, named: "online-synthetic-setup.png")
        model.phase = .lobby
        let lobby = try await capture(host, named: "online-synthetic-lobby.png")
        Self.arena(model)
        let arena = try await capture(host, named: "online-synthetic-arena.png")
        model.phase = .result
        model.result = .init(kind: .win, effects: .init(instanceID: "synthetic-pikachu", xp: 10_000_000, hpShare: 0.8))
        let result = try await capture(host, named: "online-synthetic-result.png")
        XCTAssertNotEqual(setup, lobby); XCTAssertNotEqual(lobby, arena); XCTAssertNotEqual(arena, result)
    }
    func testPublicRoomVerificationAndVoidStagesRender() async throws {
        let model = Self.model(); model.phase = .room
        model.room = Self.room(state: .accepted, confirmed: false)
        let host = await host(model)
        let room = try await capture(host, named: "online-synthetic-room.png")
        model.phase = .verifying
        let verifying = try await capture(host, named: "online-synthetic-verifying.png")
        model.phase = .result
        model.result = .init(kind: .void, effects: nil)
        let void = try await capture(host, named: "online-synthetic-void.png")
        XCTAssertNotEqual(room, verifying); XCTAssertNotEqual(verifying, void)
    }
    func testArenaClockKeepsServerDeadlineWhenViewIsAbsent() {
        let deadline = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(OnlineBattleArena.remainingSeconds(deadline: deadline, now: Date(timeIntervalSince1970: 71.2)), 29)
        XCTAssertEqual(OnlineBattleArena.remainingSeconds(deadline: deadline, now: Date(timeIntervalSince1970: 105)), 0)
    }
    func testLongRosterAndMemberNamesStayWithinPopover() async throws {
        let model = Self.model(); model.phase = .lobby
        model.members = (0..<18).map { .init(trainerId: "synthetic-\($0)", displayEmail: String(repeating: "long", count: 14) + "@example.invalid",
                                                   role: .member, status: .active, joinedAt: 0, online: $0 % 2 == 0) }
        _ = try await capture(await host(model), named: "online-synthetic-long-lobby.png")
    }
    func testHistoryIsDistinctFromLobbyAndNeverShowsLiveArena() async throws {
        let model = Self.model(); model.phase = .lobby
        model.battles = [Self.room(state: .completed, id: "completed"), Self.room(state: .void, id: "void")]
        let host = await host(model)
        let lobby = try await capture(host, named: "online-synthetic-before-history.png")
        model.showsHistory = true
        let history = try await capture(host, named: "online-synthetic-history.png")
        XCTAssertNotEqual(lobby, history, "The archive must have a distinct screen")
        Self.arena(model)
        let whileLive = try await capture(host, named: "online-synthetic-history-while-live.png")
        XCTAssertEqual(history, whileLive, "A live update must not replace the selected archive screen")
    }
    func testSyntheticStandingsAndFailureRenderInsidePopover() async throws {
        let model = Self.model(); model.phase = .lobby
        let host = await host(model)
        let before = try await capture(host, named: "online-synthetic-before-standings.png")
        model.showsStandings = true
        model.standings = .init(groupId: "synthetic-group", championTrainerId: "synthetic-foe", rows: [
            .init(trainerId: "synthetic-foe", displayName: "연습친구", wins: 3, losses: 1, draws: 1,
                  streak: 2, bestStreak: 3, winRate: 0.6),
            .init(trainerId: "synthetic-me", displayName: "나래", wins: 2, losses: 2, draws: 0,
                  streak: 0, bestStreak: 2, winRate: nil)
        ])
        let standings = try await capture(host, named: "online-synthetic-standings.png")
        model.standingsError = "서버에서 전적판을 불러오지 못했어요."
        let error = try await capture(host, named: "online-synthetic-standings-error.png")
        XCTAssertNotEqual(before, standings)
        XCTAssertNotEqual(standings, error, "Failure must show an error and retry instead of stale rankings")
        model.standingsError = nil
        Self.arena(model)
        let whileLive = try await capture(host, named: "online-synthetic-standings-while-live.png")
        XCTAssertEqual(standings, whileLive, "A live battle update must not replace the standings screen")
    }
    func testSyntheticRematchPreparationIsDistinctFromCompletedResult() async throws {
        let model = Self.model(); model.phase = .result
        model.room = Self.room(state: .completed)
        model.result = .init(kind: .win, effects: .init(instanceID: "synthetic-pikachu", xp: 10_000_000, hpShare: 0.8))
        let host = await host(model)
        let result = try await capture(host, named: "online-synthetic-before-rematch.png")
        model.rematchSourceID = "synthetic-battle"
        let preparation = try await capture(host, named: "online-synthetic-rematch-preparation.png")
        XCTAssertNotEqual(result, preparation)
    }
    func testVerifiedP2ReplayRendersReadOnlyScenesInsidePopover() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "golden", withExtension: "json", subdirectory: "OnlineBattle"))
        let archived = try XCTUnwrap(JSONDecoder().decode([Golden].self, from: Data(contentsOf: url)).first?.battle)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: BattleJSON.encoder().encode(archived)) as? [String: Any])
        json["createdAt"] = 1_793_683_500_000
        let battle = try JSONDecoder().decode(OnlineBattleView.self, from: JSONSerialization.data(withJSONObject: json))
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let replay = try OnlineBattleReplay(battle: battle, localTrainerID: "trainer-two", engineFactory: { _ in
            try BattleEngine(url: sourceRoot.appendingPathComponent("engine/dist/battle-engine.js"))
        })
        let model = Self.model()
        model.account = .init(trainer: .init(trainerId: "trainer-two", displayEmail: "나래", role: .member, status: .active),
                              group: .init(groupId: "synthetic-group", name: "동료들의 배틀", hostTrainerId: "trainer-one"))
        model.members = [.init(trainerId: "trainer-one", displayEmail: "연습친구", role: .host, status: .active,
                               joinedAt: 0, online: true)]
        model.battles = [battle]
        model.showsHistory = true
        model.selectedHistoryBattle = battle
        model.replay = replay
        let host = await host(model)
        let first = try await capture(host, named: "online-synthetic-replay-first.png")
        model.send(.seekReplay(1))
        try await Task.sleep(for: .milliseconds(650)) // Wait for the shared HP card's 0.5 s animation.
        let next = try await capture(host, named: "online-synthetic-replay-next.png")
        XCTAssertNotEqual(first, next)
        Self.arena(model)
        let whileLive = try await capture(host, named: "online-synthetic-replay-while-live.png")
        XCTAssertEqual(next, whileLive)
    }

    // MARK: T14 arena board

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    /// SwiftUI buttons carry no title, label or identifier on their AppKit view here, so they are told apart by
    /// position: top to bottom.
    private func buttons(in view: NSView) -> [NSButton] {
        func top(_ button: NSButton) -> CGFloat {
            let y = view.convert(button.bounds, from: button).minY
            return view.isFlipped ? y : -y
        }
        return descendants(view).compactMap { $0 as? NSButton }.sorted { top($0) < top($1) }
    }
    private static let arenaFiller: CGFloat = 200
    private func arenaHost(_ model: OnlineBattlePresentation, width: CGFloat = PopoverMetrics.scrollContentWidth) async -> NSView {
        let provider = OnlineBattleSyntheticNameProvider()
        // Blank room under the board: whatever hangs out of it shows up there.
        let host = NSHostingView(rootView: VStack(alignment: .leading, spacing: 0) {
            OnlineBattleArena(model: model, l: L(.en), artwork: false, speciesNameProvider: provider, speciesNameStore: PokemonNameDisplayStore())
            Color.clear.frame(height: Self.arenaFiller)
        }.frame(width: width).background(Color.white).environment(\.colorScheme, .light))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 700)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
        window.contentView = host; window.orderFront(nil); self.window = window
        try? await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        return host
    }
    /// Nothing may draw under the board's fixed height: a footer taller than its room would hang out of the scroll area.
    private func assertNothingBelowTheBoard(_ host: NSView, _ state: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let bitmap = try PracticeScreenRenderingTests.capture2x(host)
        let first = Int(OnlineBattleArena.boardHeight * 2) + 2
        XCTAssertGreaterThan(bitmap.pixelsHigh, first + 20, file: file, line: line)
        var inked = 0
        for y in first..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.alphaComponent > 0.01, color.redComponent < 0.99 || color.greenComponent < 0.99 || color.blueComponent < 0.99 { inked += 1 }
            }
        }
        XCTAssertEqual(inked, 0, "\(state) draws \(inked) pixels below the board", file: file, line: line)
    }
    private func recognized(_ host: NSView) throws -> String {
        let bitmap = try PracticeScreenRenderingTests.capture2x(host)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    /// The board has one height whatever the state, so the move picker never moves or leaves the scroll area.
    func testArenaKeepsOneHeightInEveryStateAndFitsTheScrollArea() async throws {
        let manual = try OnlineBattleArenaFixture.arena(seat: .p1)
        defer { manual.close() }
        try manual.play(rounds: 1); manual.staging.skipToEnd(); manual.publish()
        let host = await arenaHost(manual.model)
        manual.staging.skipToEnd(); manual.publish()
        var heights = [("choosing", (host.fittingSize.height - Self.arenaFiller))]
        try manual.play(rounds: 1)
        XCTAssertTrue(manual.staging.isPlaying)
        try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded()
        heights.append(("playing", (host.fittingSize.height - Self.arenaFiller))); try assertNothingBelowTheBoard(host, "playing")
        manual.model.choiceSubmitted = true
        try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded()
        heights.append(("sent", (host.fittingSize.height - Self.arenaFiller))); try assertNothingBelowTheBoard(host, "sent")
        manual.model.choiceSubmitted = false
        manual.staging.skipToEnd()
        manual.model.request = .init(kind: "none", moves: [])
        try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded()
        heights.append(("forced", (host.fittingSize.height - Self.arenaFiller))); try assertNothingBelowTheBoard(host, "forced")
        manual.model.request = .init(kind: "move", moves: [.init(slot: 1, id: "thunderbolt", name: "Thunderbolt", type: "Electric", pp: 1, maxpp: 1, disabled: false)])
        try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded()
        heights.append(("one move", (host.fittingSize.height - Self.arenaFiller)))
        let four = ["Thunderbolt", "Quick Attack", "Volt Tackle", "Iron Tail"].enumerated().map { index, name in
            BattleMove(slot: index + 1, id: OnlineBattleArenaFixture.normalized(name), name: name, type: "Electric", pp: 15, maxpp: 15, disabled: false)
        }
        manual.model.request = .init(kind: "move", moves: four)
        try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded()
        heights.append(("four moves", (host.fittingSize.height - Self.arenaFiller))); try assertNothingBelowTheBoard(host, "four moves")
        // The tallest foe card: four revealed moves and an ability with long names wrap onto a second line.
        let seen = try XCTUnwrap(manual.model.arena), foe = seen.p2
        manual.model.arena = BattleView(turn: seen.turn, ended: false, p1: seen.p1,
                                        p2: .init(speciesNum: foe.speciesNum, species: foe.species, level: foe.level, types: foe.types, hp: foe.hp,
                                                  maxhp: foe.maxhp, status: "par", moves: ["hyperbeam", "earthquake", "flamethrower", "thunderwave"],
                                                  ability: "intimidate"))
        manual.model.moveSlugs[.p2] = ["hyperbeam": "hyper-beam", "earthquake": "earthquake", "flamethrower": "flamethrower", "thunderwave": "thunder-wave"]
        manual.model.abilitySlugs[.p2] = ["intimidate": "intimidate"]
        try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded()
        heights.append(("wrapped foe card", (host.fittingSize.height - Self.arenaFiller))); try assertNothingBelowTheBoard(host, "wrapped foe card")
        let auto = try OnlineBattleArenaFixture.arena(seat: .p2, name: "auto")
        defer { auto.close() }
        try auto.play(rounds: 1, mode: .auto, secondsLeft: nil)
        auto.model.room = try OnlineBattleArenaFixture.liveRoom("auto", seat: .p2, deadline: nil)
        let autoHost = await self.host2(auto.model)
        heights.append(("auto", (autoHost.fittingSize.height - Self.arenaFiller))); try assertNothingBelowTheBoard(autoHost, "auto")
        for (name, height) in heights { XCTAssertEqual(height, heights[0].1, accuracy: 0.5, "\(name) must not change the board height") }
        // The popover's scroll area is 520pt and its group-back row (about 16pt) and one 12pt gap come first.
        XCTAssertLessThanOrEqual(heights[0].1, 520 - 16 - 12, "the move picker must stay inside the scroll area")
    }
    /// T15: after my choice the grid stays, the picked card is drawn differently from the rest, and one line says
    /// what the other side is doing, all inside the board's fixed height.
    func testArenaShowsTheWaitLineAndTheMarkedCardAfterMyChoiceWithoutChangingHeight() async throws {
        let fixture = try OnlineBattleArenaFixture.arena(seat: .p1)
        defer { fixture.close() }
        let model = fixture.model
        func settleHost(_ host: NSView) async throws { try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded() }
        let host = await arenaHost(model)
        let restingHeight = host.fittingSize.height
        let before = try PracticeScreenRenderingTests.capture2x(host).representation(using: .png, properties: [:])
        model.send(.chooseMove(1)); try await settleHost(host)
        let first = try PracticeScreenRenderingTests.capture2x(host).representation(using: .png, properties: [:])
        model.choiceSubmitted = false; model.send(.chooseMove(2)); try await settleHost(host)
        let second = try PracticeScreenRenderingTests.capture2x(host).representation(using: .png, properties: [:])
        XCTAssertNotEqual(first, second, "the marked card moves with the choice")
        XCTAssertNotEqual(before, first)
        let text = try recognized(host)
        XCTAssertTrue(text.contains("Thunderbolt"), "the grid stays after the choice: \(text)")
        XCTAssertTrue(text.contains("Quick Attack"), text)
        XCTAssertTrue(text.contains("choosing"), "the opponent line shows: \(text)")
        XCTAssertEqual(host.fittingSize.height, restingHeight, accuracy: 0.5)
        try assertNothingBelowTheBoard(host, "sent")

        // Disconnected, and the maybe wording: the longest lines, with the tallest foe card and the beats playing.
        let seen = try XCTUnwrap(model.arena), foe = seen.p2
        model.arena = BattleView(turn: seen.turn, ended: false, p1: seen.p1,
                                 p2: .init(speciesNum: foe.speciesNum, species: foe.species, level: foe.level, types: foe.types, hp: foe.hp,
                                           maxhp: foe.maxhp, status: "par", moves: ["hyperbeam", "earthquake", "flamethrower", "thunderwave"],
                                           ability: "intimidate"))
        model.moveSlugs[.p2] = ["hyperbeam": "hyper-beam", "earthquake": "earthquake", "flamethrower": "flamethrower", "thunderwave": "thunder-wave"]
        model.abilitySlugs[.p2] = ["intimidate": "intimidate"]
        let foeID = model.room.map { $0.p2.trainerId } ?? ""
        for (online, status, needle) in [(false, OnlineConnectionStatus.connection(.connected), "disconnected"), (false, .unknown, "offline")] {
            model.members = [.init(trainerId: foeID, displayEmail: "foe", role: .member, status: .active, joinedAt: 0, online: online)]
            model.connectionStatus = status
            try await settleHost(host)
            let shown = try recognized(host)
            XCTAssertTrue(shown.lowercased().contains(needle), "\(needle) line is readable: \(shown)")
            XCTAssertEqual(host.fittingSize.height, restingHeight, accuracy: 0.5, needle)
            try assertNothingBelowTheBoard(host, "sent \(needle)")
        }
        try fixture.play(rounds: 1)
        try await settleHost(host)
        XCTAssertEqual(host.fittingSize.height, restingHeight, accuracy: 0.5, "sent while the beats play")
        try assertNothingBelowTheBoard(host, "sent while the beats play")
    }

    /// T16: the flag shows while I am still choosing (the pressure) and after I have chosen, in the same board.
    func testArenaSaysTheOpponentHasChosenBeforeAndAfterMyChoiceWithoutChangingHeight() async throws {
        let fixture = try OnlineBattleArenaFixture.arena(seat: .p1)
        defer { fixture.close() }
        let model = fixture.model
        func settleHost(_ host: NSView) async throws { try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded() }
        let host = await arenaHost(model)
        let restingHeight = host.fittingSize.height
        XCTAssertFalse(try recognized(host).contains("has chosen"), "nothing is said before the flag")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: BattleJSON.encoder().encode(XCTUnwrap(model.room))) as? [String: Any])
        json["opponentSubmitted"] = true
        model.room = try JSONDecoder().decode(OnlineBattleView.self, from: JSONSerialization.data(withJSONObject: json))
        try await settleHost(host)
        let before = try recognized(host)
        XCTAssertTrue(before.contains("has chosen"), "while I still choose: \(before)")
        XCTAssertTrue(before.contains("Thunderbolt"), "the picker is untouched: \(before)")
        XCTAssertEqual(host.fittingSize.height, restingHeight, accuracy: 0.5)
        try assertNothingBelowTheBoard(host, "opponent has chosen")
        model.send(.chooseMove(1)); try await settleHost(host)
        let after = try recognized(host)
        XCTAssertTrue(after.contains("has chosen"), "after my choice: \(after)")
        XCTAssertFalse(after.contains("choosing"), after)
        XCTAssertEqual(host.fittingSize.height, restingHeight, accuracy: 0.5)
        try assertNothingBelowTheBoard(host, "both chosen")
        try fixture.play(rounds: 1); try await settleHost(host)
        XCTAssertEqual(host.fittingSize.height, restingHeight, accuracy: 0.5, "while the beats play")
        try assertNothingBelowTheBoard(host, "opponent has chosen while the beats play")
    }

    /// The waiting states drawn in the whole screen for review: with `PTB_SNAPSHOT_SCREENSHOT_DIR` set the PNGs are
    /// written (720px wide); without it the states still render and must differ from each other.
    func testWaitingStatesRenderInTheWholeScreenForReview() async throws {
        let fixture = try OnlineBattleArenaFixture.arena(seat: .p1)
        defer { fixture.close() }
        let model = fixture.model
        model.localSide = .p1
        let foeID = try XCTUnwrap(model.room).p2.trainerId
        func presence(_ online: Bool) {
            model.members = [.init(trainerId: foeID, displayEmail: "연습친구", role: .member, status: .active, joinedAt: 0, online: online)]
        }
        func flagged(_ value: Bool) throws {
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: BattleJSON.encoder().encode(XCTUnwrap(model.room))) as? [String: Any])
            json["opponentSubmitted"] = value
            model.room = try JSONDecoder().decode(OnlineBattleView.self, from: JSONSerialization.data(withJSONObject: json))
        }
        try fixture.play(rounds: 2); fixture.staging.skipToEnd(); fixture.publish()
        presence(true); model.connectionStatus = .connection(.connected)
        let host = await host(model)
        var shots: [Data] = []
        func shot(_ name: String) async throws { shots.append(try await capture(host, named: name)) }
        try await shot("t15-00-my-turn.png")
        model.send(.chooseMove(1)); try await settle(host)
        try await shot("t15-01-opponent-choosing.png")
        presence(false); try await settle(host)
        try await shot("t15-02-opponent-disconnected.png")
        model.connectionStatus = .connection(.polling); try await settle(host)
        try await shot("t15-03-opponent-maybe-offline.png")
        model.connectionStatus = .connection(.connected); presence(true)
        model.choiceSubmitted = false; try flagged(true); try await settle(host)
        try await shot("t15-04-opponent-chosen-before-mine.png")
        model.send(.chooseMove(2)); try await settle(host)
        try await shot("t15-05-both-chosen.png")
        XCTAssertEqual(Set(shots).count, shots.count, "every waiting state looks different from the others")
    }

    private func host2(_ model: OnlineBattlePresentation) async -> NSView {
        window?.close()
        return await arenaHost(model)
    }

    /// My moves are the picker's cards only: the old card also listed them as chips, so each name showed twice.
    func testArenaShowsEachOfMyMoveNamesOnce() async throws {
        // Before the first beat the lines hold no move name, so the picker's cards are the only place for them.
        let fixture = try OnlineBattleArenaFixture.arena(seat: .p1)
        defer { fixture.close() }
        let text = try recognized(await arenaHost(fixture.model))
        func count(_ needle: String) -> Int { text.components(separatedBy: needle).count - 1 }
        XCTAssertEqual(count("Thunderbolt"), 1, text)
        XCTAssertEqual(count("Quick Attack"), 1, text)
    }

    func testSkipButtonsAppearOnlyWhileTheBeatsPlay() async throws {
        let manual = try OnlineBattleArenaFixture.arena(seat: .p1)
        defer { manual.close() }
        var skips = 0
        manual.model.onAction = { if case .skipStage = $0 { skips += 1 } }
        try manual.play(rounds: 1); manual.staging.skipToEnd(); manual.publish()
        let host = await arenaHost(manual.model)
        XCTAssertTrue(buttons(in: host).isEmpty, "nothing to skip at rest, and a manual battle has no result button")
        try manual.play(rounds: 1)
        try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded()
        let found = buttons(in: host)
        XCTAssertEqual(found.count, 1)
        let skip = try XCTUnwrap(found.first)
        XCTAssertTrue(skip.isEnabled)
        skip.performClick(nil)
        XCTAssertEqual(skips, 1)
    }

    func testAutomaticBattleOffersShowResultWhilePlayingAndKeepsItsPlaceAtRest() async throws {
        let auto = try OnlineBattleArenaFixture.arena(seat: .p2, name: "auto")
        defer { auto.close() }
        var skips = 0
        auto.model.onAction = { if case .skipStage = $0 { skips += 1 } }
        try auto.play(rounds: 1, mode: .auto, secondsLeft: nil)
        auto.model.room = try OnlineBattleArenaFixture.liveRoom("auto", seat: .p2, deadline: nil)
        XCTAssertTrue(auto.staging.isPlaying)
        let host = await arenaHost(auto.model)
        let playing = buttons(in: host)
        XCTAssertEqual(playing.count, 2, "Skip in the prompt row and the result button in the footer")
        let result = try XCTUnwrap(playing.last)
        XCTAssertTrue(result.isEnabled)
        result.performClick(nil)
        XCTAssertEqual(skips, 1)
        auto.staging.skipToEnd(); auto.publish()
        try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded()
        let rest = buttons(in: host)
        XCTAssertEqual(rest.count, 1, "the result button keeps its place so the card never changes size")
        XCTAssertFalse(try XCTUnwrap(rest.first).isEnabled)
    }

    // MARK: T14 arena board states (PR images)

    /// Four states of the arena the way a real battle reaches them: before a choice, while a staged round plays,
    /// after the choice is sent, and an automatic battle. Set `PTB_SNAPSHOT_SCREENSHOT_DIR` to keep the PNGs.
    func testArenaStatesRenderInsidePopoverForPRImages() async throws {
        let manual = try OnlineBattleArenaFixture.arena(seat: .p1)
        defer { manual.close() }
        try manual.play(rounds: 1)
        manual.staging.skipToEnd()
        manual.publish()
        let host = await host(manual.model)
        let choosing = try await capture(host, named: "arena-1-choosing.png")
        try manual.play(rounds: 1)
        XCTAssertTrue(manual.staging.isPlaying)
        let playing = try await capture(host, named: "arena-2-playing.png")
        manual.model.choiceSubmitted = true
        let sent = try await capture(host, named: "arena-3-choice-sent.png")
        XCTAssertNotEqual(choosing, playing); XCTAssertNotEqual(playing, sent)
        // A full set of four moves is the tallest picker; it must stay inside the scroll area too.
        manual.model.choiceSubmitted = false
        manual.model.request = .init(kind: "move", moves: ["Thunderbolt", "Quick Attack", "Volt Tackle", "Iron Tail"].enumerated().map { index, name in
            BattleMove(slot: index + 1, id: OnlineBattleArenaFixture.normalized(name), name: name, type: ["Electric", "Normal", "Electric", "Steel"][index],
                       pp: 15, maxpp: 15, disabled: false)
        })
        _ = try await capture(host, named: "arena-5-four-moves.png")

        let auto = try OnlineBattleArenaFixture.arena(seat: .p2, name: "auto")
        defer { auto.close() }
        try auto.play(rounds: 1, mode: .auto, secondsLeft: nil)
        auto.model.room = try OnlineBattleArenaFixture.liveRoom("auto", seat: .p2, deadline: nil)
        XCTAssertTrue(auto.staging.isPlaying)
        let autoHost = await self.host(auto.model)
        _ = try await capture(autoHost, named: "arena-4-auto.png")
    }

    /// Review B's wording on the real screens. It has to wrap inside the popover, not clip.
    func testReviewBWordingStaysInsideThePopover() async throws {
        let l = L(.ko)
        let setup = OnlineBattlePresentation()
        setup.serverAddress = "https://embedded.example.invalid"; setup.serverIsEmbedded = true
        setup.setupInput.server = setup.serverAddress
        let setupHost = await host(setup)
        let plain = try await capture(setupHost, named: "f3-setup-plain.png")
        setup.serverMoved = true
        let moved = try await capture(setupHost, named: "f3-setup-server-moved.png")
        XCTAssertNotEqual(plain, moved, "the moved line reaches the form")
        setup.serverMoved = false
        setup.connectionStatus = .connection(.revoked)
        setup.notice = l.onlineServerError(.init(code: .invalidCode, retryAfter: nil))
        _ = try await capture(setupHost, named: "f3-setup-revoked-invalid-code.png")

        let recovery = Self.model(); recovery.recoveryCode = "SYNTHETIC-RECOVERY-0001"
        _ = try await capture(await host(recovery), named: "f3-recovery-hint.png")

        let lobby = Self.model(); lobby.phase = .lobby; lobby.notice = l.onlineOtherSaveBattle
        _ = try await capture(await host(lobby), named: "f3-lobby-other-save-battle.png")

        let arena = Self.model(); Self.arena(arena); arena.notice = l.onlineErrorRoundPassed
        _ = try await capture(await host(arena), named: "f3-arena-round-passed.png")

        let record = Self.model(); record.phase = .result; record.room = Self.room(state: .completed)
        record.result = .init(kind: .record, effects: nil)
        _ = try await capture(await host(record), named: "f3-result-other-save-record.png")
    }
}
