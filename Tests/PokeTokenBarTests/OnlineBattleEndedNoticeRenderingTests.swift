import AppKit
import SwiftUI
import XCTest
@testable import PokeTokenBar

/// Synthetic data only. Renders the T07 screens at the popover width (360pt) so a reviewer can look
/// for clipping. PNGs are written only when PTB_SNAPSHOT_SCREENSHOT_DIR is set.
@MainActor
final class OnlineBattleEndedNoticeRenderingTests: XCTestCase {
    private typealias Fixture = OnlineBattleScreenRenderingTests
    private var window: NSWindow?
    override func tearDown() async throws { window?.close(); window = nil }

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
        guard let path = ProcessInfo.processInfo.environment["PTB_SNAPSHOT_SCREENSHOT_DIR"] else { return }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("\(name).png"))
    }

    private static let longNickname = "아주아주아주아주긴닉네임을가진동료입니다"
    private func room(_ state: OnlineBattleState, confirmed: Bool = false) -> OnlineBattleView {
        // Sent 20 minutes ago; the server's window is 24 hours from creation.
        let created = (Date().timeIntervalSince1970 - 20 * 60) * 1000
        return OnlineBattleEndedNoticeTests.room(state, confirmed: confirmed, expiresAt: created + 24 * 3600 * 1000, createdAt: created)
    }
    private func model(_ side: OnlineBattleSide, _ state: OnlineBattleState, confirmed: Bool = false, name: String? = nil) -> OnlineBattlePresentation {
        let model = Fixture.model(); model.phase = .room; model.localSide = side; model.canStart = true
        if side == .p2 {
            model.members.append(.init(trainerId: "synthetic-me", displayEmail: "나래", role: .member, status: .active, joinedAt: 0, online: true))
        }
        if let name { OnlineBattleRoomGuideRenderingTests.named(model, name) }
        model.room = room(state, confirmed: confirmed)
        return model
    }

    func testWaitingRoomsAndBannersRenderAtPopoverWidth() async throws {
        let provider = OnlineBattleSyntheticNameProvider()
        let names = PokemonNameDisplayStore()
        for id in [25, 129] { _ = await names.load(.init(kind: .pokemonSpecies, name: String(id)), provider: provider) }
        let l = L(.ko)
        func roomContent(_ model: OnlineBattlePresentation) -> some View {
            OnlineBattleRoom(model: model, l: l, artwork: false, speciesNameProvider: provider, speciesNameStore: names)
                .frame(width: PopoverMetrics.scrollContentWidth, alignment: .leading)
                .padding(.leading, PopoverMetrics.padding)
                .frame(width: PopoverMetrics.width, alignment: .leading)
        }
        func screen(_ model: OnlineBattlePresentation) -> some View {
            OnlineBattleScreen(model: model, l: l, artwork: false, readInvitationClipboard: { nil },
                               speciesNameProvider: provider, speciesNameStore: names, onClose: {})
        }
        try await capture(roomContent(model(.p1, .pending)), named: "challenger-pending-expiry-and-cancel")
        try await capture(roomContent(model(.p1, .pending, name: Self.longNickname)), named: "challenger-pending-long-nickname")
        try await capture(roomContent(model(.p2, .pending)), named: "receiver-pending-accept-decline-no-cancel")
        try await capture(roomContent(model(.p2, .accepted)), named: "receiver-accepted-cancel-battle")
        try await capture(roomContent(model(.p1, .accepted, confirmed: true)), named: "challenger-confirmed-expiry")

        let declined = Fixture.model(); declined.phase = .lobby
        declined.announceEnded(OnlineBattleEndedNoticeTests.room(.declined), previous: .pending, l: l)
        try await capture(screen(declined), named: "lobby-declined-notice")
        let expired = Fixture.model(); expired.phase = .lobby; OnlineBattleRoomGuideRenderingTests.named(expired, Self.longNickname)
        expired.announceEnded(OnlineBattleEndedNoticeTests.room(.expired), previous: .pending, l: l)
        try await capture(screen(expired), named: "lobby-expired-notice-long-nickname")
        let error = Fixture.model(); error.phase = .lobby; error.notice = l.onlineErrorPeerCancelled
        try await capture(screen(error), named: "lobby-error-notice")
        let verifying = Fixture.model(); verifying.phase = .verifying; verifying.room = room(.reported)
        try await capture(screen(verifying), named: "verifying-auto-refresh")
    }
}
