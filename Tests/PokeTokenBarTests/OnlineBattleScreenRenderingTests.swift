import AppKit
import SwiftUI
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
        model.result = .init(title: "정식전 승리", detail: "양쪽 결과가 일치해 저장했어요.", xpAwarded: 10_000_000,
                             hpApplied: true, isVoid: false)
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
        model.result = .init(title: "경기 무효", detail: "양쪽 결과를 확인할 수 없어 무효로 끝났어요.", xpAwarded: 0,
                             hpApplied: false, isVoid: true)
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
        model.result = .init(title: "정식전 승리", detail: "결과가 저장됐어요.", xpAwarded: 10_000_000,
                             hpApplied: true, isVoid: false)
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
}
