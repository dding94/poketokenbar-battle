import XCTest
@testable import PokeTokenBar

/// The menu-bar online mark and the home row subtitle. Both read the T02 attention core.
@MainActor
final class OnlineBattleMenuMarkTests: XCTestCase {
    private static let me = "synthetic-me"
    private static let foe = "synthetic-foe"
    private static let now = Date(timeIntervalSince1970: 1_793_683_600)
    private static var nowMS: Double { now.timeIntervalSince1970 * 1000 }
    private let ko = L(.ko)
    private let en = L(.en)

    private func battle(_ id: String, _ state: OnlineBattleState, mine: OnlineBattleSide = .p2, mode: OnlineBattleMode = .manual,
                        confirmed: Bool = false, deadline: Double? = nil, ownChoice: String? = nil,
                        createdAt: Double = 1, rematchOf: String? = nil) -> OnlineBattleView {
        let local = OnlineBattlePlayer(trainerId: Self.me, snapshot: nil, publicInfo: nil, hpPercent: nil)
        let remote = OnlineBattlePlayer(trainerId: Self.foe, snapshot: nil, publicInfo: nil, hpPercent: nil)
        return .init(battleId: id, state: state, revision: 1, mode: mode, p1: mine == .p1 ? local : remote, p2: mine == .p1 ? remote : local,
                     createdAt: createdAt, expiresAt: Self.nowMS + 3_600_000, startedAt: nil, reportedAt: nil, confirmed: confirmed,
                     config: nil, roundSeq: 1, deadline: deadline, ownChoice: ownChoice, journal: [], result: nil, reason: nil, rematchOf: rematchOf)
    }
    private func incoming(_ id: String = "bt-in", createdAt: Double = 1, rematch: Bool = false) -> OnlineBattleView {
        battle(id, .pending, createdAt: createdAt, rematchOf: rematch ? "bt-old" : nil)
    }
    private func turn(_ id: String = "bt-turn", seconds: Double) -> OnlineBattleView {
        battle(id, .running, confirmed: true, deadline: Self.nowMS + seconds * 1000)
    }
    private func input(_ battles: [OnlineBattleView], joined: Bool = true, prepared: Set<String> = []) -> OnlineAttentionInput {
        let model = OnlineBattlePresentation()
        if joined {
            model.account = .init(trainer: .init(trainerId: Self.me, displayEmail: "나래", role: .member, status: .active),
                                  group: .init(groupId: "synthetic-group", name: "동료들", hostTrainerId: Self.foe))
        }
        model.members = [.init(trainerId: Self.foe, displayEmail: "연습친구", role: .host, status: .active, joinedAt: 0, online: true)]
        model.battles = battles
        model.phase = .lobby
        return .init(presentation: model, preparedBattleIDs: prepared, stagingHeldBattleIDs: [], now: Self.now)
    }

    // MARK: The mark

    func testNothingToShowMeansNoMark() {
        XCTAssertNil(ko.onlineMenuMark(input([])))
        XCTAssertNil(ko.onlineMenuMark(input([battle("bt-out", .pending, mine: .p1)])), "My own outgoing request waits on the opponent")
        XCTAssertNil(ko.onlineMenuMark(input([battle("bt-done", .completed)])))
        XCTAssertNil(ko.onlineMenuMark(input([incoming()], joined: false)), "Without an account nothing is mine")
    }

    func testOneEventIsADotWithItsTooltip() {
        let mark = ko.onlineMenuMark(input([incoming()]))
        XCTAssertEqual(mark?.text, "●")
        XCTAssertEqual(mark?.tone, .attention)
        XCTAssertEqual(mark?.tooltip, "연습친구님이 대결을 신청했어요")
        XCTAssertEqual(en.onlineMenuMark(input([incoming()]))?.tooltip, "연습친구 challenged you to a battle")
    }

    func testSeveralEventsShowTheCountAndTheRestInTheTooltip() {
        let mark = ko.onlineMenuMark(input([incoming("bt-a", createdAt: 1), incoming("bt-b", createdAt: 2), incoming("bt-c", rematch: true)]))
        XCTAssertEqual(mark?.text, "●3")
        XCTAssertEqual(mark?.tone, .attention)
        XCTAssertEqual(mark?.tooltip, "연습친구님이 대결을 신청했어요 (외 2건)")
        XCTAssertEqual(en.onlineMenuMark(input([incoming("bt-a"), incoming("bt-b", createdAt: 2)]))?.tooltip,
                       "연습친구 challenged you to a battle (+1 more)")
    }

    func testMyTurnTurnsUrgentAtTenSecondsAndNoSoonerOrLater() {
        XCTAssertEqual(ko.onlineMenuMark(input([turn(seconds: 20)]))?.tone, .attention)
        XCTAssertEqual(ko.onlineMenuMark(input([turn(seconds: 10.5)]))?.tone, .attention)
        XCTAssertEqual(ko.onlineMenuMark(input([turn(seconds: 10)]))?.tone, .urgent, "Exactly ten seconds counts as ten or less")
        XCTAssertEqual(ko.onlineMenuMark(input([turn(seconds: 3)]))?.tone, .urgent)
        XCTAssertEqual(ko.onlineMenuMark(input([turn(seconds: 3)]))?.text, "●", "Only the color changes, not the mark")
        XCTAssertEqual(ko.onlineMenuMark(input([turn(seconds: -1)]))?.tone, .ongoing, "A passed deadline asks nothing, yet the room still runs")
    }

    func testOnlyMyTurnCanBeUrgent() {
        // The challenge never expires within ten seconds here, and a challenge has no countdown.
        XCTAssertEqual(ko.onlineMenuMark(input([incoming()]))?.tone, .attention)
        XCTAssertEqual(ko.onlineMenuMark(input([incoming(), turn(seconds: 4)]))?.tone, .urgent, "An urgent turn colors the whole mark")
        XCTAssertEqual(ko.onlineMenuMark(input([incoming(), turn(seconds: 4)]))?.text, "●2")
    }

    func testRunningAndReportedRoomsStayVisibleEvenWhenNothingIsPending() {
        for state in [OnlineBattleState.running, .reported] {
            let room = battle("bt-run", state, confirmed: true, deadline: Self.nowMS + 20_000, ownChoice: "move 1")
            let mark = ko.onlineMenuMark(input([room]))
            XCTAssertEqual(mark?.text, "○", "\(state)")
            XCTAssertEqual(mark?.tone, .ongoing, "\(state)")
            XCTAssertEqual(mark?.tooltip, "진행 중인 온라인 대전이 있어요", "\(state)")
        }
        XCTAssertEqual(en.onlineMenuMark(input([battle("bt-auto", .running, mode: .auto, confirmed: true)]))?.tooltip,
                       "An online battle is in progress")
    }

    func testAnEventOutranksAnOngoingRoom() {
        let ongoing = battle("bt-run", .running, confirmed: true, deadline: Self.nowMS + 20_000, ownChoice: "move 1")
        let mark = ko.onlineMenuMark(input([ongoing, incoming()]))
        XCTAssertEqual(mark?.text, "●")
        XCTAssertEqual(mark?.tone, .attention)
    }

    func testPressingReadyClearsTheConfirmedMark() {
        let confirmed = battle("bt-conf", .accepted, confirmed: true)
        XCTAssertEqual(ko.onlineMenuMark(input([confirmed]))?.text, "●")
        XCTAssertNil(ko.onlineMenuMark(input([confirmed], prepared: ["bt-conf"])), "Waiting for the opponent to get ready is not an action")
    }

    // MARK: The mark beside the practice badge

    func testTheOnlineMarkJoinsThePracticeBadgeWithoutCoveringIt() {
        let faint = AppDelegate.faintedMark
        XCTAssertEqual(AppDelegate.menuBadge(practice: "⚔︎", fainted: false, online: "●"), "⚔︎ ●")
        XCTAssertEqual(AppDelegate.menuBadge(practice: "⚔︎", fainted: true, online: "●2"), "⚔︎ " + faint + " ●2")
        XCTAssertEqual(AppDelegate.menuBadge(practice: nil, fainted: false, online: "○"), "○")
        XCTAssertEqual(AppDelegate.menuBadge(practice: "⚑", fainted: false, online: nil), "⚑", "Without an online mark the badge is as before")
        XCTAssertEqual(AppDelegate.menuLines(["5h 12%", "1.2M"], badge: AppDelegate.menuBadge(practice: "⚔︎", fainted: false, online: "●")),
                       ["5h 12% ⚔︎ ●", "1.2M"])
    }

    func testTheOnlineTooltipLineComesAfterThePracticeLine() {
        XCTAssertEqual(AppDelegate.menuToolTip(base: "tip", badge: "⚔︎", resultReady: false, faintedName: nil, onlineLine: "온라인 한 줄", l: en),
                       "tip\n" + en.practiceStatusRunning + "\n온라인 한 줄")
        XCTAssertEqual(AppDelegate.menuToolTip(base: nil, badge: nil, resultReady: false, faintedName: nil, onlineLine: "온라인 한 줄", l: en),
                       "온라인 한 줄")
        XCTAssertEqual(AppDelegate.menuToolTip(base: "tip", badge: nil, resultReady: false, faintedName: nil, onlineLine: nil, l: en), "tip")
    }

    // MARK: The home row subtitle

    func testSubtitleBeforeJoining() {
        XCTAssertEqual(ko.onlineHomeSubtitle(input([], joined: false), connection: nil), "동료와 겨루기 · 아직 가입 안 함")
        XCTAssertEqual(en.onlineHomeSubtitle(input([], joined: false), connection: nil), "Battle your group · Not joined yet")
    }

    func testSubtitleCountsReceivedRequests() {
        XCTAssertEqual(ko.onlineHomeSubtitle(input([incoming()]), connection: .connected), "받은 신청 1건")
        XCTAssertEqual(ko.onlineHomeSubtitle(input([incoming("bt-a"), incoming("bt-b", createdAt: 2, rematch: true)]), connection: .connected), "받은 신청 2건")
        XCTAssertEqual(en.onlineHomeSubtitle(input([incoming()]), connection: .connected), "1 request received")
        XCTAssertEqual(en.onlineHomeSubtitle(input([incoming("bt-a"), incoming("bt-b", createdAt: 2)]), connection: .connected), "2 requests received")
    }

    func testSubtitleWhileReconnectingWinsOverEverythingButNotJoining() {
        for status in [OnlineBattleConnectionState.connecting, .retryWaiting] {
            XCTAssertEqual(ko.onlineHomeSubtitle(input([incoming()]), connection: status), "다시 연결하는 중", "\(status)")
            XCTAssertEqual(en.onlineHomeSubtitle(input([]), connection: status), "Reconnecting", "\(status)")
        }
        XCTAssertEqual(ko.onlineHomeSubtitle(input([], joined: false), connection: .connecting), "동료와 겨루기 · 아직 가입 안 함")
    }

    /// On a network that blocks the socket polling can last, and the read it still does brings news worth showing.
    func testPollingDoesNotHideARequestBehindReconnecting() {
        XCTAssertEqual(ko.onlineHomeSubtitle(input([incoming()]), connection: .polling), "받은 신청 1건")
        XCTAssertEqual(ko.onlineHomeSubtitle(input([]), connection: .polling), "동료와 겨루기")
    }

    func testEveryConnectionLineHasBothLanguages() {
        XCTAssertNil(ko.onlineConnectionLine(.unknown))
        XCTAssertNil(en.onlineConnectionLine(.unknown))
        let states: [OnlineBattleConnectionState] = [.unconfigured, .credentialsRequired, .connecting, .connected, .retryWaiting, .polling, .replaced, .revoked, .protocolError]
        func hasHangul(_ text: String?) -> Bool { text?.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) } ?? false }
        for status in states.map(OnlineConnectionStatus.connection) + [.accessOff, .accessStopped] {
            XCTAssertTrue(hasHangul(ko.onlineConnectionLine(status)), "\(status)")
            XCTAssertEqual(en.onlineConnectionLine(status)?.isEmpty, false, "\(status)")
            XCTAssertFalse(hasHangul(en.onlineConnectionLine(status)), "\(status) still reads Korean in English")
        }
        XCTAssertEqual(ko.onlineConnectionLine(.connection(.polling)), "다시 연결하는 중")
        XCTAssertEqual(en.onlineConnectionLine(.connection(.polling)), "Reconnecting")
    }

    func testSubtitleForOtherEventsOngoingRoomsAndIdle() {
        XCTAssertEqual(ko.onlineHomeSubtitle(input([turn(seconds: 20)]), connection: .connected), "연습친구님과 대전 중 · 내 차례")
        XCTAssertEqual(ko.onlineHomeSubtitle(input([battle("bt-conf", .accepted, confirmed: true)]), connection: .connected),
                       "연습친구님과 대결 확정 · 전투 준비 필요")
        let ongoing = battle("bt-run", .running, confirmed: true, deadline: Self.nowMS + 20_000, ownChoice: "move 1")
        XCTAssertEqual(ko.onlineHomeSubtitle(input([ongoing]), connection: .connected), "진행 중인 대전이 있어요")
        XCTAssertEqual(en.onlineHomeSubtitle(input([ongoing]), connection: .connected), "A battle is in progress")
        XCTAssertEqual(ko.onlineHomeSubtitle(input([]), connection: .connected), "동료와 겨루기 · 접속 중")
        XCTAssertEqual(en.onlineHomeSubtitle(input([]), connection: .connected), "Battle your group · Online")
        XCTAssertEqual(ko.onlineHomeSubtitle(input([]), connection: nil), "동료와 겨루기", "Before the first connection report")
        XCTAssertEqual(ko.onlineHomeSubtitle(input([]), connection: .credentialsRequired), "동료와 겨루기")
    }
}
