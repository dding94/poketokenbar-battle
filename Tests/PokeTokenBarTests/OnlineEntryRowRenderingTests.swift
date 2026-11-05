import AppKit
import SwiftUI
import XCTest
@testable import PokeTokenBar

/// Synthetic renders of the home "Online battle" row in each status. Set PTB_SNAPSHOT_SCREENSHOT_DIR to keep the PNGs.
@MainActor
final class OnlineEntryRowRenderingTests: XCTestCase {
    private var window: NSWindow?

    private func render(_ subtitle: String?, scheme: ColorScheme = .light, named name: String) throws -> CGFloat {
        let host = NSHostingView(rootView: OnlineEntryRow(l: L(.ko), subtitle: subtitle) {}
            .padding(PopoverMetrics.padding).frame(width: PopoverMetrics.width)
            .background(scheme == .light ? Color.white : Color.black).environment(\.colorScheme, scheme))
        let height = host.fittingSize.height
        host.frame = NSRect(x: 0, y: 0, width: PopoverMetrics.width, height: height)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: PopoverMetrics.width, height: height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        window.contentView = host; window.orderFront(nil); self.window = window
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.fittingSize.width, PopoverMetrics.width, accuracy: 0.5, "\(name): the row fits the popover width")
        let data = try XCTUnwrap(PracticeScreenRenderingTests.capture2x(host).representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 2000, "\(name): a blank hosting view must not pass as a rendered row")
        if let path = ProcessInfo.processInfo.environment["PTB_SNAPSHOT_SCREENSHOT_DIR"] {
            let directory = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(name))
        }
        return height
    }

    func testRowRendersEveryStatusAndTheSubtitleAddsALine() throws {
        let l = L(.ko)
        let without = try render(nil, named: "T03-home-row-no-subtitle.png")
        let states: [(String, String)] = [
            ("not-joined", l.onlineHomeSubtitle(Self.input(joined: false), connectionStatus: "")),
            ("online-idle", l.onlineHomeSubtitle(Self.input(joined: true), connectionStatus: "접속 중")),
            ("request-received", l.onlineHomeSubtitle(Self.input(joined: true, incoming: 1), connectionStatus: "접속 중")),
            ("requests-received-2", l.onlineHomeSubtitle(Self.input(joined: true, incoming: 2), connectionStatus: "접속 중")),
            ("reconnecting", l.onlineHomeSubtitle(Self.input(joined: true), connectionStatus: "연결 중")),
        ]
        for (name, subtitle) in states {
            let height = try render(subtitle, named: "T03-home-row-\(name).png")
            XCTAssertGreaterThan(height, without, "\(name): the subtitle line makes the row taller")
        }
        _ = try render(l.onlineHomeSubtitle(Self.input(joined: true, incoming: 1), connectionStatus: "접속 중"), scheme: .dark,
                       named: "T03-home-row-request-received-dark.png")
        let long = try render(String(repeating: "아주 긴 부제 ", count: 20), named: "T03-home-row-long-subtitle.png")
        let one = try render("한 줄", named: "T03-home-row-one-line-check.png")
        XCTAssertEqual(long, one, accuracy: 0.5, "A long subtitle stays on one line")
    }

    private static func input(joined: Bool, incoming: Int = 0) -> OnlineAttentionInput {
        let model = OnlineBattlePresentation()
        if joined {
            model.account = .init(trainer: .init(trainerId: "synthetic-me", displayEmail: "나래", role: .member, status: .active),
                                  group: .init(groupId: "synthetic-group", name: "동료들", hostTrainerId: "synthetic-foe"))
        }
        let local = OnlineBattlePlayer(trainerId: "synthetic-me", snapshot: nil, publicInfo: nil, hpPercent: nil)
        let remote = OnlineBattlePlayer(trainerId: "synthetic-foe", snapshot: nil, publicInfo: nil, hpPercent: nil)
        model.battles = (0..<incoming).map { index in
            .init(battleId: "bt-\(index)", state: .pending, revision: 1, mode: .manual, p1: remote, p2: local, createdAt: Double(index),
                  expiresAt: Date().timeIntervalSince1970 * 1000 + 3_600_000, startedAt: nil, reportedAt: nil, confirmed: false,
                  config: nil, roundSeq: 0, deadline: nil, ownChoice: nil, journal: [], result: nil, reason: nil, rematchOf: nil)
        }
        return .init(presentation: model, preparedBattleIDs: [], stagingHeldBattleIDs: [], now: Date())
    }
}
