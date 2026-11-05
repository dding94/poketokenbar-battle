import AppKit
import SwiftUI
import Vision
import XCTest
@testable import PokeTokenBar

/// The host panel drawn in the whole online screen. Synthetic data only: no network, Keychain or real save.
/// Set PTB_SNAPSHOT_SCREENSHOT_DIR to keep the PNGs (720px wide, Korean).
@MainActor
final class OnlineBattleHostPanelRenderingTests: XCTestCase {
    private var window: NSWindow?
    override func tearDown() async throws { window?.close(); window = nil }

    private static let now = Date().timeIntervalSince1970 * 1000
    private func invite(_ id: String, uses: Int, maxUses: Int = 30, createdHoursAgo: Double = 5, expiresInDays: Double = 7) -> OnlineBattleInvite {
        .init(inviteId: id, createdAt: Self.now - createdHoursAgo * 3_600_000, expiresAt: Self.now + expiresInDays * 86_400_000,
              maxUses: maxUses, uses: uses, revoked: false, revokedAt: nil)
    }
    private func peer(_ id: String, _ name: String, online: Bool = true) -> OnlineBattleMember {
        .init(trainerId: id, displayEmail: name, role: .member, status: .active, joinedAt: 0, online: online)
    }
    /// A host looking at the open panel: two members, two live invites, nothing held.
    private func hostModel(members: [OnlineBattleMember]? = nil, invites: [OnlineBattleInvite]? = nil, open: Bool = true) -> OnlineBattlePresentation {
        let model = OnlineBattleScreenRenderingTests.model()
        model.account = .init(trainer: .init(trainerId: "synthetic-me", displayEmail: "나래", role: .host, status: .active),
                              group: .init(groupId: "synthetic-group", name: "동료들의 배틀", hostTrainerId: "synthetic-me"))
        model.members = members ?? [peer("synthetic-foe", "연습친구"), peer("synthetic-two", "다온", online: false)]
        model.roster = []; model.entryHP = [:]; model.selectedEntryID = nil; model.battles = []; model.phase = .lobby
        model.serverIsEmbedded = true   // the usual build: a copied invite is the code alone
        model.host.visible = open
        model.host.invites = invites ?? [invite("inv_1", uses: 3), invite("inv_2", uses: 0, maxUses: 1, createdHoursAgo: 1, expiresInDays: 6)]
        return model
    }
    private func screen(_ model: OnlineBattlePresentation, l: L = L(.ko), clipboard: @escaping (String) -> Bool = { _ in true }) async -> NSView {
        let host = NSHostingView(rootView: OnlineBattleScreen(model: model, l: l, artwork: false, writeClipboard: clipboard, onClose: {})
            .background(Color.white).environment(\.colorScheme, .light))
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 610)
        window?.close()
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 360, height: 610), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
        window.contentView = host; window.orderFront(nil); self.window = window
        try? await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        return host
    }
    @discardableResult
    private func capture(_ host: NSView, named name: String) async throws -> Data {
        try await Task.sleep(for: .milliseconds(120))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.fittingSize.width, 360, accuracy: 0.5, "\(name) must not widen the popover")
        XCTAssertLessThanOrEqual(host.fittingSize.height, 628, name)
        let data = try XCTUnwrap(PracticeScreenRenderingTests.capture2x(host).representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 8000, "A blank hosting view must not pass as a rendered stage")
        if let path = ProcessInfo.processInfo.environment["PTB_SNAPSHOT_SCREENSHOT_DIR"] {
            let directory = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(name))
        }
        return data
    }
    private func recognized(_ host: NSView) throws -> String {
        let bitmap = try PracticeScreenRenderingTests.capture2x(host)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }
    private func compact(_ text: String) -> String { text.filter { !$0.isWhitespace }.uppercased() }

    // MARK: the way in

    func testOnlyAHostSeesTheEntryInTheLobbyHeader() async throws {
        let host = hostModel(open: false)
        let member = OnlineBattleScreenRenderingTests.model()
        member.roster = []; member.entryHP = [:]; member.selectedEntryID = nil; member.battles = []; member.phase = .lobby
        XCTAssertTrue(OnlineBattleScreen(model: host, l: L(.ko), onClose: {}).showsHostEntry)
        XCTAssertFalse(OnlineBattleScreen(model: member, l: L(.ko), onClose: {}).showsHostEntry)
        let withEntry = try await capture(await screen(host), named: "t10-00-lobby-host-entry.png")
        let without = try await capture(await screen(member), named: "t10-01-lobby-member-no-entry.png")
        XCTAssertNotEqual(withEntry, without)
        host.phase = .room
        XCTAssertFalse(OnlineBattleScreen(model: host, l: L(.ko), onClose: {}).showsHostEntry, "the panel opens from the lobby only")
    }

    // MARK: the panel

    func testThePanelListsInvitesAndMembersAndFitsThePopover() async throws {
        let model = hostModel()
        let view = await screen(model, l: L(.en))
        let text = try recognized(view)
        for needle in ["Create invite code", "Active invite codes", "Members", "Reconnect code", "Remove"] {
            XCTAssertTrue(text.contains(needle), "\(needle) in:\n\(text)")
        }
        try await capture(view, named: "t10-02-panel-en.png")
        try await capture(await screen(model), named: "t10-03-panel.png")
    }

    func testAnEmptyPanelSaysThereIsNobodyYetAndNoActiveInvite() async throws {
        let model = hostModel(members: [], invites: [])
        let text = try recognized(await screen(model, l: L(.en)))
        XCTAssertTrue(text.contains("No active invite codes"), text)
        XCTAssertTrue(text.contains("other members"), text)
        try await capture(await screen(model), named: "t10-04-panel-empty.png")
    }

    func testAnInviteCodeIsShownUntilItIsCopiedThenHidden() async throws {
        let model = hostModel()
        model.host.secret = .init(kind: .invite(maxUses: 30), code: "ABCDEFGHJKMN", expiresAt: Self.now + 7 * 86_400_000)
        var copied: [String] = []
        let view = await screen(model, l: L(.en)) { copied.append($0); return true }
        let shown = try recognized(view)
        XCTAssertTrue(compact(shown).contains("ABCDEFGHJKMN"), "the code is readable before it is copied:\n\(shown)")
        XCTAssertTrue(shown.contains("Copy"), shown)
        try await capture(await screen(model), named: "t10-05-invite-code-shown.png")
        // The same copy the button runs.
        let panel = OnlineBattleHostPanel(model: model, l: L(.en), writeClipboard: { copied.append($0); return true })
        panel.copySecret()
        XCTAssertEqual(copied, ["ABCDEFGHJKMN"])
        XCTAssertNil(model.host.secret)
        let after = await screen(model, l: L(.en))
        let hidden = try recognized(after)
        XCTAssertFalse(compact(hidden).contains("ABCDEFGHJKMN"), "the code is gone after the copy:\n\(hidden)")
        XCTAssertTrue(hidden.contains("copied"), hidden)
        try await capture(await screen(model), named: "t10-06-invite-code-copied.png")
    }

    func testACodeTheClipboardRefusedStaysOnScreen() {
        let model = hostModel()
        model.host.secret = .init(kind: .invite(maxUses: 1), code: "ABCDEFGHJKMN", expiresAt: Self.now + 86_400_000)
        OnlineBattleHostPanel(model: model, l: L(.ko), writeClipboard: { _ in false }).copySecret()
        XCTAssertEqual(model.host.secret?.code, "ABCDEFGHJKMN")
        XCTAssertNil(model.host.copied)
    }

    func testAManualBuildCopiesTheAddressWithTheInviteCode() {
        let model = hostModel()
        model.serverAddress = "https://battle.example.invalid"
        model.serverIsEmbedded = false
        model.host.secret = .init(kind: .invite(maxUses: 30), code: "ABCDEFGHJKMN", expiresAt: Self.now + 86_400_000)
        var text = ""
        OnlineBattleHostPanel(model: model, l: L(.ko), writeClipboard: { text = $0; return true }).copySecret()
        XCTAssertTrue(text.contains("https://battle.example.invalid") && text.contains("ABCDEFGHJKMN"), text)
        let embedded = hostModel()
        embedded.serverAddress = "https://battle.example.invalid"; embedded.serverIsEmbedded = true
        embedded.host.secret = .init(kind: .invite(maxUses: 30), code: "ABCDEFGHJKMN", expiresAt: Self.now + 86_400_000)
        OnlineBattleHostPanel(model: embedded, l: L(.ko), writeClipboard: { text = $0; return true }).copySecret()
        XCTAssertEqual(text, "ABCDEFGHJKMN")
    }

    func testAReconnectCodeNamesTheMemberAndHowItIsUsed() async throws {
        let model = hostModel()
        model.host.secret = .init(kind: .reconnect(trainerId: "synthetic-foe"), code: "RECONNECTCODE16", expiresAt: Self.now + 86_400_000)
        let text = try recognized(await screen(model, l: L(.en)))
        XCTAssertTrue(text.contains("Reconnect code for"), text)
        XCTAssertTrue(compact(text).contains("RECONNECTCODE16"), text)
        try await capture(await screen(model), named: "t10-07-reconnect-code-shown.png")
    }

    func testRemovingAMemberAsksOnceMoreAndTheResultSaysWhatHappenedToTheInvites() async throws {
        let model = hostModel()
        model.host.pendingRemoval = "synthetic-foe"
        let asking = try recognized(await screen(model, l: L(.en)))
        XCTAssertTrue(asking.contains("Remove"), asking)
        XCTAssertTrue(asking.contains("Cancel"), asking)
        try await capture(await screen(model), named: "t10-08-remove-confirm.png")
        model.host.pendingRemoval = nil
        model.host.notice = L(.ko).onlineHostRemoved(name: "연습친구", revokedInvites: 2)
        try await capture(await screen(model), named: "t10-09-removed-notice.png")
    }

    func testALongNicknameWrapsInTheConfirmationAndTruncatesInTheRow() async throws {
        let long = String(repeating: "아주긴닉네임", count: 12)
        let model = hostModel(members: [peer("synthetic-foe", long), peer("synthetic-two", "다온")])
        try await capture(await screen(model), named: "t10-10-long-nickname-row.png")
        model.host.pendingRemoval = "synthetic-foe"
        try await capture(await screen(model), named: "t10-11-long-nickname-confirm.png")
    }

    func testAnInviteListFailureOffersARetry() async throws {
        let model = hostModel(invites: nil)
        model.host.invitesFailed = true
        let text = try recognized(await screen(model, l: L(.en)))
        XCTAssertTrue(text.contains("Try again"), text)
        try await capture(await screen(model), named: "t10-12-invites-failed.png")
    }

    func testAnOpenPanelWithACodeShowsThePinnedHeader() async throws {
        let model = hostModel()
        model.host.secret = .init(kind: .invite(maxUses: 30), code: "ABCDEFGHJKMN", expiresAt: Self.now + 7 * 86_400_000)
        model.popoverPinned = true
        try await capture(await screen(model), named: "t10-13-invite-code-pinned.png")
    }
}
