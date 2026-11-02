import AppKit
import SwiftUI
import XCTest
@testable import PokeTokenBar

/// Synthetic data only. No network, Keychain, real saves or OCR; optional PNGs are native SwiftUI renders.
@MainActor
final class OnlineBattleScreenRenderingTests: XCTestCase {
    private var window: NSWindow?
    override func tearDown() async throws { window?.close(); window = nil }

    static func snapshot(_ id: String = "synthetic-pikachu") -> BattleSnapshot {
        .init(schemaVersion: 1, instanceID: id, engineHash: "synthetic", rulesVersion: BattleSnapshot.rules,
              policyVersion: BattleSnapshot.policy,
              set: .init(speciesNum: 25, form: nil, level: 50, gender: .male, nature: "Hardy", ability: "static",
                         moves: ["thunderbolt"], ivs: [:], shiny: false),
              publicInfo: .init(speciesNum: 25, species: "피카츄", level: 50, types: ["Electric"],
                                stats: ["hp": 110, "atk": 75, "def": 60, "spa": 70, "spd": 70, "spe": 110]))
    }
    static func room(state: OnlineBattleState = .running, mode: OnlineBattleMode = .manual, confirmed: Bool = true) -> OnlineBattleView {
        let snapshot = snapshot()
        return .init(battleId: "synthetic-battle", state: state, revision: 1, mode: mode,
                     p1: .init(trainerId: "synthetic-me", snapshot: .init(snapshot: snapshot, hp: 88), publicInfo: nil, hpPercent: nil),
                     p2: .init(trainerId: "synthetic-foe", snapshot: nil, publicInfo: snapshot.publicInfo, hpPercent: 90),
                     createdAt: 0, expiresAt: 100, startedAt: 0, reportedAt: nil, confirmed: confirmed,
                     config: nil, roundSeq: 1, deadline: nil, ownChoice: nil, journal: [], result: nil, reason: nil, rematchOf: nil)
    }
    static func model() -> OnlineBattlePresentation {
        let model = OnlineBattlePresentation()
        model.serverAddress = "https://battle.example.invalid"
        model.account = .init(trainer: .init(trainerId: "synthetic-me", displayEmail: "me@example.invalid", role: .member, status: .active),
                              group: .init(groupId: "synthetic-group", name: "동료들의 배틀", hostTrainerId: "synthetic-foe"))
        model.members = [.init(trainerId: "synthetic-foe", displayEmail: "friend@example.invalid", role: .host, status: .active,
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
        model.arena = .init(turn: 3, ended: false,
                            p1: .init(speciesNum: 25, species: "피카츄", level: 50, types: ["Electric"], hp: 88, maxhp: 110,
                                      status: "", moves: ["thunderbolt"], ability: "static"),
                            p2: .init(speciesNum: 129, species: "잉어킹", level: 50, types: ["Water"], hp: 42, maxhp: 100,
                                      status: "", moves: ["splash"], ability: nil))
        model.request = .init(kind: "move", moves: [
            .init(slot: 1, id: "thunderbolt", name: "Thunderbolt", type: "Electric", pp: 14, maxpp: 15, disabled: false),
            .init(slot: 2, id: "quickattack", name: "Quick Attack", type: "Normal", pp: 30, maxpp: 30, disabled: false)])
    }

    private func host(_ model: OnlineBattlePresentation) -> NSView {
        let host = NSHostingView(rootView: OnlineBattleScreen(model: model, l: L(.ko), artwork: false, onClose: {})
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
    func testSyntheticSetupLobbyArenaAndResultRenderInsidePopover() async throws {
        let model = Self.model()
        let host = host(model)
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
    func testArenaClockKeepsServerDeadlineWhenViewIsAbsent() {
        let deadline = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(OnlineBattleArena.remainingSeconds(deadline: deadline, now: Date(timeIntervalSince1970: 71.2)), 29)
        XCTAssertEqual(OnlineBattleArena.remainingSeconds(deadline: deadline, now: Date(timeIntervalSince1970: 105)), 0)
    }
    func testLongRosterAndMemberNamesStayWithinPopover() async throws {
        let model = Self.model(); model.phase = .lobby
        model.members = (0..<18).map { .init(trainerId: "synthetic-\($0)", displayEmail: String(repeating: "long", count: 14) + "@example.invalid",
                                                   role: .member, status: .active, joinedAt: 0, online: $0 % 2 == 0) }
        _ = try await capture(host(model), named: "online-synthetic-long-lobby.png")
    }
}
