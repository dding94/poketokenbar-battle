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

    private func host(_ model: OnlineBattlePresentation) async -> NSView {
        let provider = OnlineBattleSyntheticNameProvider()
        let names = PokemonNameDisplayStore()
        for id in [25, 129] { _ = await names.load(.init(kind: .pokemonSpecies, name: String(id)), provider: provider) }
        let host = NSHostingView(rootView: OnlineBattleScreen(model: model, l: L(.ko), artwork: false,
                                                             speciesNameProvider: provider, speciesNameStore: names, onClose: {})
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
