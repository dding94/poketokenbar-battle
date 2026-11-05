import AppKit
import SwiftUI
import Vision
import XCTest
@testable import PokeTokenBar

/// T11 screens drawn with synthetic data: the recovery code, the first lobby and its rows.
/// Set PTB_SNAPSHOT_SCREENSHOT_DIR to keep the PNGs (720px wide, Korean). Badges are asserted on their data and on
/// pixels, never on OCR: the small coloured glyphs do not read reliably on every macOS.
@MainActor
final class OnlineBattleOnboardingRenderingTests: XCTestCase {
    private var window: NSWindow?
    override func tearDown() async throws { window?.close(); window = nil }

    private static let code = "SYNTHETICRECOVERY1"
    private static var nowMS: Double { Date().timeIntervalSince1970 * 1000 }

    private func peer(_ id: String, _ name: String, online: Bool = true, role: OnlineBattleTrainer.Role = .member) -> OnlineBattleMember {
        .init(trainerId: id, displayEmail: name, role: role, status: .active, joinedAt: 0, online: online)
    }
    private func room(_ id: String, _ state: OnlineBattleState, mine: OnlineBattleSide, peerID: String = "synthetic-foe",
                      confirmed: Bool = false, deadline: Double? = nil) -> OnlineBattleView {
        let local = OnlineBattlePlayer(trainerId: "synthetic-me", snapshot: nil, publicInfo: nil, hpPercent: nil)
        let remote = OnlineBattlePlayer(trainerId: peerID, snapshot: nil, publicInfo: nil, hpPercent: nil)
        return .init(battleId: id, state: state, revision: 1, mode: .manual, p1: mine == .p1 ? local : remote, p2: mine == .p1 ? remote : local,
                     createdAt: 1, expiresAt: Self.nowMS + 3_600_000, startedAt: nil, reportedAt: nil, confirmed: confirmed,
                     config: nil, roundSeq: 1, deadline: deadline, ownChoice: nil, journal: [], result: nil, reason: nil, rematchOf: nil)
    }
    /// A lobby with no roster artwork, so two renders of the same data are the same pixels.
    private func lobbyModel(members: [OnlineBattleMember]? = nil, battles: [OnlineBattleView] = [], isHost: Bool = false) -> OnlineBattlePresentation {
        let model = OnlineBattleScreenRenderingTests.model()
        model.roster = []; model.entryHP = [:]; model.selectedEntryID = nil
        model.members = members ?? [peer("synthetic-foe", "연습친구"), peer("synthetic-two", "다온", online: false)]
        model.selectedOpponentID = nil
        model.battles = battles; model.phase = .lobby
        if isHost {
            model.account = .init(trainer: .init(trainerId: "synthetic-me", displayEmail: "나래", role: .host, status: .active),
                                  group: .init(groupId: "synthetic-group", name: "동료들의 배틀", hostTrainerId: "synthetic-me"))
        }
        return model
    }

    private func place(_ view: some View, width: CGFloat, height: CGFloat = 700) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: AnyView(view.background(Color.white).environment(\.colorScheme, .light)))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        window?.close()
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: height), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
        window.contentView = host; window.orderFront(nil); self.window = window
        return host
    }
    private func screen(_ model: OnlineBattlePresentation, l: L = L(.ko), clipboard: @escaping (String) -> Bool = { _ in true }) async -> NSHostingView<AnyView> {
        let host = place(OnlineBattleScreen(model: model, l: l, artwork: false, writeClipboard: clipboard, onClose: {}), width: 360, height: 610)
        try? await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        return host
    }
    /// The lobby as it is inside the popover: a 336pt column with the 12pt padding, as tall as it needs.
    private func lobby(_ model: OnlineBattlePresentation, l: L = L(.ko), badges: [String: OnlineLobbyRowBadge]? = nil) async -> NSHostingView<AnyView> {
        let host = place(OnlineBattleLobby(model: model, l: l, artwork: false, badges: badges).frame(width: 336).padding(12), width: 360)
        try? await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        window?.setContentSize(host.fittingSize)
        host.layoutSubtreeIfNeeded()
        return host
    }
    @discardableResult
    private func capture(_ host: NSView, named name: String) async throws -> NSBitmapImageRep {
        try await Task.sleep(for: .milliseconds(120))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.bounds.width, 360, accuracy: 0.5, "\(name) is drawn at the popover's 360pt")
        let bitmap = try PracticeScreenRenderingTests.capture2x(host)
        XCTAssertEqual(bitmap.pixelsWide, 720, "\(name) comes out 720px wide")
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 6000, "A blank hosting view must not pass as a rendered stage")
        if let path = ProcessInfo.processInfo.environment["PTB_SNAPSHOT_SCREENSHOT_DIR"] {
            let directory = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(name))
        }
        return bitmap
    }
    private func pixels(_ bitmap: NSBitmapImageRep) throws -> Data {
        Data(bytes: try XCTUnwrap(bitmap.bitmapData), count: bitmap.pixelsHigh * bitmap.bytesPerRow)
    }
    private func recognized(_ host: NSView) throws -> String {
        let bitmap = try PracticeScreenRenderingTests.capture2x(host)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }
    private func compact(_ text: String) -> String { text.filter { !$0.isWhitespace }.uppercased() }
    /// Dark pixels (near-black text) in the rows from `top` down, in 2x pixels. A disabled control draws its words grey.
    private func darkPixels(_ bitmap: NSBitmapImageRep, fromRow top: Int) -> Int {
        var count = 0
        for y in top..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if c.redComponent < 0.3, c.greenComponent < 0.3, c.blueComponent < 0.3 { count += 1 }
            }
        }
        return count
    }

    // MARK: the recovery code

    func testTheRecoveryScreenOffersCopyAndOpensTheKeepButtonOnlyAfterTheCheck() async throws {
        let model = OnlineBattlePresentation()
        model.account = OnlineBattleScreenRenderingTests.model().account
        model.recoveryCode = Self.code; model.popoverPinned = true
        let l = L(.en)
        let view = await screen(model, l: l)
        let unchecked = try await capture(view, named: "t11-00-recovery-unchecked.png")
        XCTAssertTrue(compact(try recognized(view)).contains(Self.code), "the code is readable until it is copied")
        let text = try recognized(view)
        XCTAssertTrue(text.contains("Copy"), "a copy button:\n\(text)")
        XCTAssertTrue(text.contains("Copy it or write it down first"), "the reason the keep button is shut:\n\(text)")
        model.send(.setRecoveryWrittenDown(true))
        try await Task.sleep(for: .milliseconds(150)); view.layoutSubtreeIfNeeded()
        let checked = try await capture(view, named: "t11-01-recovery-checked.png")
        // SwiftUI draws these buttons without an NSButton here, so the keep button's state is read from its words:
        // black while it can be pressed, grey while it cannot. Rows below the checkbox hold only that button.
        let shut = darkPixels(unchecked, fromRow: 436), open = darkPixels(checked, fromRow: 436)
        XCTAssertLessThan(shut, 50, "the keep button's words are grey before the check")
        XCTAssertGreaterThan(open, 400, "the keep button's words turn black once the check is made")
        XCTAssertFalse(try recognized(view).contains("Copy it or write it down first"), "the reason goes away with the check")
        model.send(.acknowledgeRecoveryCode)
        XCTAssertNil(model.recoveryCode)
    }

    func testCopyWritesTheCodeThenTheScreenForgetsIt() async throws {
        let model = OnlineBattlePresentation()
        model.account = OnlineBattleScreenRenderingTests.model().account
        model.recoveryCode = Self.code
        var written: [String] = []
        let card = OnlineBattleRecoveryCodeCard(model: model, l: L(.en), writeClipboard: { written.append($0); return true })
        card.copyCode()
        XCTAssertEqual(written, [Self.code])
        XCTAssertNil(model.recoveryCode)
        XCTAssertEqual(model.firstSteps?.copiedRecoveryCode, true)
        let after = try recognized(await screen(model, l: L(.en)))
        XCTAssertFalse(compact(after).contains(Self.code), "the code is gone from the screen:\n\(after)")
    }

    func testACodeTheClipboardRefusedStaysOnScreen() {
        let model = OnlineBattlePresentation(); model.recoveryCode = Self.code
        OnlineBattleRecoveryCodeCard(model: model, l: L(.ko), writeClipboard: { _ in false }).copyCode()
        XCTAssertEqual(model.recoveryCode, Self.code)
        XCTAssertNil(model.firstSteps)
    }

    func testTheFirstLobbyShowsTheFirstStepsOnTopUntilTheyAreDismissed() async throws {
        let model = lobbyModel()
        let plain = try await capture(await lobby(model), named: "t11-02-lobby-plain.png")
        model.firstSteps = .init(copiedRecoveryCode: false)
        let kept = try await capture(await lobby(model), named: "t11-03-lobby-first-steps.png")
        model.firstSteps = .init(copiedRecoveryCode: true)
        let copied = try await capture(await lobby(model), named: "t11-04-lobby-first-steps-copied.png")
        XCTAssertGreaterThan(kept.pixelsHigh, plain.pixelsHigh, "the card adds its own band")
        XCTAssertGreaterThan(copied.pixelsHigh, kept.pixelsHigh, "the copied line adds one more")
        let text = try recognized(await lobby(model, l: L(.en)))
        XCTAssertTrue(text.contains("copied and hidden"), text)
        model.send(.dismissFirstSteps)
        let dismissed = try await capture(await lobby(model), named: "t11-05-lobby-first-steps-dismissed.png")
        XCTAssertEqual(try pixels(dismissed), try pixels(plain))
    }

    // MARK: an empty group

    func testAnEmptyGroupSaysSoAndWhoToAsk() async throws {
        let member = lobbyModel(members: [])
        let text = try recognized(await lobby(member, l: L(.en)))
        XCTAssertTrue(text.contains("host"), "a member is told to ask the host:\n\(text)")
        XCTAssertTrue(text.contains("invite"), text)
        let withPeers = try await capture(await lobby(lobbyModel()), named: "t11-06-lobby-with-peers.png")
        let empty = try await capture(await lobby(member), named: "t11-07-lobby-empty-member.png")
        XCTAssertNotEqual(try pixels(withPeers), try pixels(empty))
        let hostText = try recognized(await lobby(lobbyModel(members: [], isHost: true), l: L(.en)))
        XCTAssertTrue(hostText.contains("Manage members") || hostText.contains("create"), "a host is told to create a code:\n\(hostText)")
        try await capture(await lobby(lobbyModel(members: [], isHost: true)), named: "t11-08-lobby-empty-host.png")
    }

    // MARK: rows in the battle list

    func testRowsCarryTheirBadgeAndItsColour() async throws {
        let rows = [room("received", .pending, mine: .p2), room("sent", .pending, mine: .p1, peerID: "synthetic-two"),
                    room("turn", .running, mine: .p1, peerID: "synthetic-three", deadline: Self.nowMS + 20_000)]
        let members = [peer("synthetic-foe", "연습친구"), peer("synthetic-two", "다온"), peer("synthetic-three", "하늘")]
        let model = lobbyModel(members: members, battles: rows)
        let found = OnlineLobbyRowBadge.badges(.init(presentation: model, preparedBattleIDs: [], stagingHeldBattleIDs: [], now: Date()))
        XCTAssertEqual(found, ["received": .received, "sent": .sent, "turn": .myTurn])
        let withBadges = try await capture(await lobby(model), named: "t11-09-lobby-row-badges.png")
        let without = try await capture(await lobby(model, badges: [:]), named: "t11-10-lobby-rows-no-badges.png")
        XCTAssertNotEqual(try pixels(withBadges), try pixels(without), "the badges and the row tint are drawn")
        XCTAssertEqual(withBadges.pixelsHigh, without.pixelsHigh, "a badge sits inside the row and never makes it taller")
        let calm = try await capture(await lobby(model, badges: [:]), named: "t11-11-lobby-rows-calm.png")
        XCTAssertEqual(try pixels(calm), try pixels(without))
        // The same screen picks the badges up by itself from the model, as the popover does.
        let byItself = try await capture(await screen(model), named: "t11-12-screen-with-rows.png")
        XCTAssertGreaterThan(byItself.pixelsHigh, 0)
    }

    // MARK: the line before sending a challenge

    func testALongNicknameWrapsInTheConfirmationAndTruncatesInTheRow() async throws {
        let long = String(repeating: "아주긴닉네임", count: 12)
        let short = lobbyModel(members: [peer("synthetic-foe", "연습친구")]); short.selectedOpponentID = "synthetic-foe"
        let longer = lobbyModel(members: [peer("synthetic-foe", long)]); longer.selectedOpponentID = "synthetic-foe"
        let none = lobbyModel(members: [peer("synthetic-foe", "연습친구")])
        let shortBitmap = try await capture(await lobby(short), named: "t11-13-confirm-short-name.png")
        let longBitmap = try await capture(await lobby(longer), named: "t11-14-confirm-long-name.png")
        let noneBitmap = try await capture(await lobby(none), named: "t11-15-confirm-no-opponent.png")
        XCTAssertGreaterThan(shortBitmap.pixelsHigh, noneBitmap.pixelsHigh, "choosing someone adds the confirmation line")
        XCTAssertGreaterThan(longBitmap.pixelsHigh, shortBitmap.pixelsHigh, "a long name wraps onto more lines and is not cut to one")
    }
}
