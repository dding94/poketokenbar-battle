import AppKit
import SwiftUI
import XCTest
@testable import PokeTokenBar

/// Synthetic data only. Renders the battle room and lobby at the popover width (360pt) so a
/// reviewer can look for clipping. PNGs are written only when PTB_SNAPSHOT_SCREENSHOT_DIR is set;
/// PTB_ROOM_GUIDE_TAG ("before" or "after") prefixes the file names.
@MainActor
final class OnlineBattleRoomGuideRenderingTests: XCTestCase {
    private var window: NSWindow?
    override func tearDown() async throws { window?.close(); window = nil }

    static let longNickname = "아주아주아주아주긴닉네임을가진동료입니다"

    struct Scenario {
        let name: String
        let setup: @MainActor (OnlineBattlePresentation) -> Void
    }

    static func challenger(_ model: OnlineBattlePresentation, state: OnlineBattleState, confirmed: Bool = false) {
        model.phase = .room; model.localSide = .p1; model.canStart = true
        model.room = OnlineBattleScreenRenderingTests.room(state: state, confirmed: confirmed)
    }
    static func receiver(_ model: OnlineBattlePresentation, state: OnlineBattleState, confirmed: Bool = false) {
        model.phase = .room; model.localSide = .p2; model.canStart = true
        model.members.append(.init(trainerId: "synthetic-me", displayEmail: "나래", role: .member, status: .active, joinedAt: 0, online: true))
        model.room = OnlineBattleScreenRenderingTests.room(state: state, confirmed: confirmed)
    }
    static func named(_ model: OnlineBattlePresentation, _ name: String) {
        model.members = model.members.map {
            .init(trainerId: $0.trainerId, displayEmail: name, role: $0.role, status: $0.status, joinedAt: $0.joinedAt, online: $0.online)
        }
    }

    static let baseScenarios: [Scenario] = [
        .init(name: "challenger-1-pending") { challenger($0, state: .pending) },
        .init(name: "challenger-2-accepted") { challenger($0, state: .accepted) },
        .init(name: "challenger-3-confirmed") { challenger($0, state: .accepted, confirmed: true) },
        .init(name: "challenger-4-both-ready") { challenger($0, state: .ready, confirmed: true) },
        .init(name: "receiver-1-pending") { receiver($0, state: .pending) },
        .init(name: "receiver-2-accepted") { receiver($0, state: .accepted) },
        .init(name: "receiver-3-confirmed") { receiver($0, state: .accepted, confirmed: true) },
        .init(name: "challenger-1-pending-long-nickname") { challenger($0, state: .pending); named($0, longNickname) },
        .init(name: "receiver-1-pending-long-nickname") { receiver($0, state: .pending); named($0, longNickname) },
        .init(name: "lobby-no-opponent") { $0.phase = .lobby; $0.selectedOpponentID = nil },
        .init(name: "lobby-offline-opponent-long-nickname") {
            $0.phase = .lobby; named($0, longNickname)
            $0.members = $0.members.map {
                .init(trainerId: $0.trainerId, displayEmail: $0.displayEmail, role: $0.role, status: $0.status, joinedAt: $0.joinedAt, online: false)
            }
        },
    ]

#if !BEFORE_BASELINE
    /// States the old screen could not express (my press received, why a button is disabled).
    static let guideScenarios: [Scenario] = [
        .init(name: "challenger-3b-ready-pressed") { challenger($0, state: .accepted, confirmed: true); $0.localReady = true },
        .init(name: "challenger-4b-both-ready-pressed") { challenger($0, state: .ready, confirmed: true); $0.localReady = true },
        .init(name: "challenger-3c-connecting") { challenger($0, state: .accepted, confirmed: true); $0.canStart = false },
        .init(name: "receiver-1b-pending-fainted-entry") { receiver($0, state: .pending); $0.entryHP["synthetic-pikachu"] = 0 },
        .init(name: "receiver-3b-ready-pressed-long-nickname") {
            receiver($0, state: .accepted, confirmed: true); named($0, longNickname); $0.localReady = true
        },
        .init(name: "challenger-2b-accepted-long-nickname") { challenger($0, state: .accepted); named($0, longNickname) },
        .init(name: "lobby-fainted-entry") { $0.phase = .lobby; $0.entryHP["synthetic-pikachu"] = 0 },
        .init(name: "lobby-row-confirmed-and-unconfirmed") {
            $0.phase = .lobby
            $0.battles = [OnlineBattleScreenRenderingTests.room(state: .accepted, confirmed: true, id: "synthetic-a"),
                          OnlineBattleScreenRenderingTests.room(state: .accepted, confirmed: false, id: "synthetic-b")]
        },
    ]
    static let allScenarios = baseScenarios + guideScenarios
#else
    static let allScenarios = baseScenarios
#endif
    /// Scenarios also captured through the real 520pt scroll viewport, to show what is above the fold.
    static let viewportScenarios: Set<String> = ["challenger-1-pending", "challenger-3-confirmed", "receiver-1-pending", "receiver-3-confirmed"]

    private func publish(_ bitmapData: Data, _ name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["PTB_SNAPSHOT_SCREENSHOT_DIR"] else { return }
        let tag = ProcessInfo.processInfo.environment["PTB_ROOM_GUIDE_TAG"] ?? "after"
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try bitmapData.write(to: directory.appendingPathComponent("\(tag)-\(name).png"))
    }

    /// Lays out `root` at the popover width with unconstrained height and writes a 2x PNG.
    private func capture<Content: View>(_ root: Content, named name: String) async throws {
        let host = NSHostingView(rootView: root.background(Color.white).environment(\.colorScheme, .light))
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 1400)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
        window.contentView = host; window.orderFront(nil); self.window?.close(); self.window = window
        try await Task.sleep(for: .milliseconds(120))
        host.layoutSubtreeIfNeeded()
        let fit = host.fittingSize
        XCTAssertEqual(fit.width, 360, accuracy: 0.5, name)
        host.frame = NSRect(x: 0, y: 0, width: 360, height: ceil(fit.height))
        window.setContentSize(host.frame.size)
        try await Task.sleep(for: .milliseconds(60))
        let bitmap = try PracticeScreenRenderingTests.capture2x(host)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 8000, "A blank hosting view must not pass as a rendered screen")
        try publish(data, name)
    }

    func testRoomAndLobbyScenariosRenderAtPopoverWidth() async throws {
        let provider = OnlineBattleSyntheticNameProvider()
        let names = PokemonNameDisplayStore()
        for id in [25, 129] { _ = await names.load(.init(kind: .pokemonSpecies, name: String(id)), provider: provider) }
        let l = L(.ko)
        for scenario in Self.allScenarios {
            let model = OnlineBattleScreenRenderingTests.model()
            scenario.setup(model)
            // Full content as it lays out inside the popover scroll view (width minus the scroller lane).
            let content = Group {
                if model.phase == .room {
                    OnlineBattleRoom(model: model, l: l, artwork: false, speciesNameProvider: provider, speciesNameStore: names)
                } else {
                    OnlineBattleLobby(model: model, l: l, artwork: false)
                }
            }
            .frame(width: PopoverMetrics.scrollContentWidth, alignment: .leading)
            .padding(.leading, PopoverMetrics.padding)
            .frame(width: PopoverMetrics.width, alignment: .leading)
            try await capture(content, named: scenario.name)
            guard Self.viewportScenarios.contains(scenario.name) else { continue }
            try await capture(OnlineBattleScreen(model: model, l: l, artwork: false, readInvitationClipboard: { nil },
                                                 speciesNameProvider: provider, speciesNameStore: names, onClose: {}),
                              named: "viewport-" + scenario.name)
        }
    }
}
