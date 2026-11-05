import XCTest
@testable import PokeTokenBar

/// Records every call so a test can pin both the effects and their order. No real notification is ever posted.
@MainActor
private final class FakeCenter: OnlineNotificationCenter {
    var status: OnlineNotificationPermission
    var grantsRequest: Bool
    var log: [String] = []
    var added: [OnlineNotificationRequest] = []
    var withdrawn: [String] = []
    init(status: OnlineNotificationPermission = .allowed, grantsRequest: Bool = true) {
        self.status = status; self.grantsRequest = grantsRequest
    }
    func permission() async -> OnlineNotificationPermission { status }
    func requestPermission() async -> Bool {
        log.append("request")
        if grantsRequest { status = .allowed } else { status = .denied }
        return grantsRequest
    }
    func add(_ request: OnlineNotificationRequest) async { log.append("add"); added.append(request) }
    func withdraw(identifiers: [String]) { log.append("withdraw"); withdrawn += identifiers }
}

private final class MemoryStore: OnlineAttentionStateStoring, @unchecked Sendable {
    var state = OnlineAttentionState()
    var failsToSave = false
    struct SaveFailure: Error {}
    func load() -> OnlineAttentionState { state }
    func save(_ state: OnlineAttentionState) throws {
        if failsToSave { throw SaveFailure() }
        self.state = state
    }
}

@MainActor
final class OnlineAttentionNotifierTests: XCTestCase {
    private static let now = Date(timeIntervalSince1970: 1_793_683_600)
    private static let nickname = "고유닉네임"

    private func room(_ id: String, _ state: OnlineBattleState, confirmed: Bool = false, rematchOf: String? = nil,
                      deadlineIn seconds: Double? = nil, round: Int = 1) -> OnlineBattleView {
        let me = OnlineBattlePlayer(trainerId: "synthetic-me", snapshot: nil, publicInfo: nil, hpPercent: nil)
        let foe = OnlineBattlePlayer(trainerId: "synthetic-foe", snapshot: nil, publicInfo: nil, hpPercent: nil)
        return .init(battleId: id, state: state, revision: 1, mode: .manual, p1: foe, p2: me, createdAt: 1,
                     expiresAt: Self.now.timeIntervalSince1970 * 1000 + 3_600_000, startedAt: nil, reportedAt: nil, confirmed: confirmed,
                     config: nil, roundSeq: round, deadline: seconds.map { (Self.now.timeIntervalSince1970 + $0) * 1000 }, ownChoice: nil,
                     journal: [], result: nil, reason: nil, rematchOf: rematchOf)
    }

    private func input(_ battles: [OnlineBattleView], signedIn: Bool = true, at now: Date = OnlineAttentionNotifierTests.now) -> OnlineAttentionInput {
        let model = OnlineBattlePresentation()
        if signedIn {
            model.account = .init(trainer: .init(trainerId: "synthetic-me", displayEmail: "나래", role: .member, status: .active),
                                  group: .init(groupId: "synthetic-group", name: "동료들", hostTrainerId: "synthetic-foe"))
        }
        model.members = [.init(trainerId: "synthetic-foe", displayEmail: Self.nickname, role: .member, status: .active, joinedAt: 0, online: true)]
        model.battles = battles
        return OnlineAttentionSource(presentation: model).input(now: now)
    }

    private struct Rig {
        let center: FakeCenter
        let store: MemoryStore
        let notifier: OnlineAttentionNotifier
        let hints: HintLog
    }
    @MainActor final class HintLog { var values: [OnlineNotificationHint?] = [] }

    private func rig(status: OnlineNotificationPermission = .allowed, grants: Bool = true, store: MemoryStore = MemoryStore()) -> Rig {
        let center = FakeCenter(status: status, grantsRequest: grants)
        let hints = HintLog()
        let notifier = OnlineAttentionNotifier(center: center, store: store, l: { L(.ko) }, setHint: { hint in
            hints.values.append(hint)
            center.log.append("hint:\(hint.map { "\($0)" } ?? "nil")")
        })
        return Rig(center: center, store: store, notifier: notifier, hints: hints)
    }

    // MARK: delivery

    func testTheSameEventTwiceAddsOneNotification() async {
        let rig = rig()
        let incoming = input([room("bt-in", .pending)])
        await rig.notifier.handle(incoming, popoverOpen: false)
        await rig.notifier.handle(incoming, popoverOpen: false)
        XCTAssertEqual(rig.center.added.map(\.identifier), ["online-attention.bt-in.incomingChallenge"])
        XCTAssertEqual(rig.center.added.first?.battleId, "bt-in")
        XCTAssertTrue(rig.center.added.first?.body.contains(Self.nickname) ?? false)
    }

    func testAnOpenPopoverGetsNoNotificationAndTheEventStaysSeen() async {
        let rig = rig()
        let incoming = input([room("bt-in", .pending)])
        await rig.notifier.handle(incoming, popoverOpen: true)
        XCTAssertEqual(rig.center.added.count, 0)
        await rig.notifier.handle(incoming, popoverOpen: false)
        XCTAssertEqual(rig.center.added.count, 0, "Seen while the popover was open, so closing it must not announce it")
        XCTAssertTrue(rig.store.state.seen.contains(.init(battleId: "bt-in", kind: .incomingChallenge, roundSeq: 0)))
    }

    func testAResolvedEventWithdrawsItsNotificationButNotOthers() async {
        let rig = rig()
        await rig.notifier.handle(input([room("bt-in", .pending), room("bt-other", .pending)]), popoverOpen: false)
        await rig.notifier.handle(input([room("bt-in", .declined), room("bt-other", .pending)]), popoverOpen: false)
        XCTAssertEqual(rig.center.withdrawn, ["online-attention.bt-in.incomingChallenge"])
    }

    func testEveryNotifiableKindIsDeliveredOnceIncludingARematchRequest() async {
        let cases: [(OnlineBattleView, String)] = [
            (room("bt-a", .pending), "incomingChallenge"),
            (room("bt-b", .pending, rematchOf: "bt-old"), "rematchRequested"),
            (room("bt-c", .accepted), "finalConfirmed"),
            (room("bt-d", .running, confirmed: true, deadlineIn: 30), "myTurn.1"),
        ]
        for (battle, stage) in cases {
            let rig = rig()
            await rig.notifier.handle(input([battle]), popoverOpen: false)
            XCTAssertEqual(rig.center.added.map(\.identifier), ["online-attention.\(battle.battleId).\(stage)"], stage)
        }
    }

    func testMyTurnNotificationStatesTheTimeLeft() async {
        let rig = rig()
        await rig.notifier.handle(input([room("bt-t", .running, confirmed: true, deadlineIn: 27)]), popoverOpen: false)
        XCTAssertTrue(rig.center.added.first?.body.contains("27초") ?? false, rig.center.added.first?.body ?? "none")
    }

    func testAnInAppOnlyKindIsNeverNotified() async {
        let rig = rig()
        await rig.notifier.handle(input([room("bt-r", .reported)]), popoverOpen: false)
        XCTAssertEqual(rig.center.added.count, 0)
    }

    // MARK: persistence

    func testARelaunchWithTheSavedRecordDoesNotAnnounceAgain() async {
        let store = MemoryStore()
        let first = rig(store: store)
        let incoming = input([room("bt-in", .pending)])
        await first.notifier.handle(incoming, popoverOpen: false)
        XCTAssertEqual(first.center.added.count, 1)
        let relaunched = rig(store: store)
        await relaunched.notifier.handle(incoming, popoverOpen: false)
        XCTAssertEqual(relaunched.center.added.count, 0)
    }

    func testAFailedSaveNeitherBlocksNorReannouncesInThisRun() async {
        let store = MemoryStore()
        store.failsToSave = true
        let rig = rig(store: store)
        let incoming = input([room("bt-in", .pending)])
        await rig.notifier.handle(incoming, popoverOpen: false)
        await rig.notifier.handle(incoming, popoverOpen: false)
        XCTAssertEqual(rig.center.added.count, 1)
    }

    func testTheStateFileHoldsIdsAndRevisionsOnly() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-attn-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = OnlineAttentionStateFile(directory: directory)
        var evaluation = OnlineAttentionCalculator.evaluate(input([room("bt-in", .pending)]), seen: .init())
        var state = OnlineAttentionState()
        state.seen = evaluation.seen; state.permissionHandled = true
        try file.save(state)
        let raw = try String(contentsOf: directory.appendingPathComponent("online-attention-state.json"), encoding: .utf8)
        XCTAssertTrue(raw.contains("bt-in"))
        for secret in [Self.nickname, "나래", "synthetic-foe", "synthetic-me"] { XCTAssertFalse(raw.contains(secret), secret) }
        XCTAssertEqual(file.load(), state)
        evaluation = OnlineAttentionCalculator.evaluate(input([]), seen: .init())
        XCTAssertEqual(OnlineAttentionStateFile(directory: directory.appendingPathComponent("missing")).load(), OnlineAttentionState())
        try Data("not json".utf8).write(to: directory.appendingPathComponent("online-attention-state.json"))
        XCTAssertEqual(file.load(), OnlineAttentionState(), "A corrupt file starts clean instead of crashing")
        _ = evaluation
    }

    // MARK: permission

    func testDeniedPermissionSendsNothingShowsGuidanceAndStillMarksSeen() async {
        let rig = rig(status: .denied)
        let incoming = input([room("bt-in", .pending)])
        await rig.notifier.handle(incoming, popoverOpen: false)
        XCTAssertEqual(rig.center.added.count, 0)
        XCTAssertEqual(rig.hints.values.last, .denied)
        rig.center.status = .allowed
        await rig.notifier.handle(incoming, popoverOpen: false)
        XCTAssertEqual(rig.center.added.count, 0, "Marked seen while denied, so enabling later does not replay it")
    }

    func testPermissionIsAskedOnceRightAfterSignInWithTheReasonShownFirst() async {
        let rig = rig(status: .notDetermined, grants: true)
        await rig.notifier.handle(input([], signedIn: false), popoverOpen: true)
        XCTAssertEqual(rig.center.log, [], "Nothing to ask before sign-in")
        await rig.notifier.handle(input([]), popoverOpen: false)
        XCTAssertEqual(rig.center.log, [], "A closed popover has nobody to read the reason")
        await rig.notifier.handle(input([]), popoverOpen: true)
        XCTAssertEqual(rig.center.log, ["hint:reason", "request", "hint:nil"])
        await rig.notifier.handle(input([]), popoverOpen: true)
        XCTAssertEqual(rig.center.log.filter { $0 == "request" }.count, 1)
        XCTAssertTrue(rig.store.state.permissionHandled)
    }

    func testRefusingTheSystemDialogLeavesTheGuidance() async {
        let rig = rig(status: .notDetermined, grants: false)
        await rig.notifier.handle(input([]), popoverOpen: true)
        XCTAssertEqual(rig.center.log, ["hint:reason", "request", "hint:denied"])
    }

    func testPermissionIsNeverAskedAgainAfterARelaunch() async {
        let store = MemoryStore()
        let first = rig(status: .notDetermined, store: store)
        await first.notifier.handle(input([]), popoverOpen: true)
        let relaunched = rig(status: .notDetermined, store: store)
        await relaunched.notifier.handle(input([]), popoverOpen: true)
        XCTAssertFalse(relaunched.center.log.contains("request"))
    }

    func testAnAlreadyAnsweredPermissionIsRecordedWithoutAskingOrWithTheRightHint() async {
        let allowed = rig(status: .allowed)
        await allowed.notifier.handle(input([]), popoverOpen: true)
        XCTAssertFalse(allowed.center.log.contains("request"))
        XCTAssertTrue(allowed.store.state.permissionHandled)
        XCTAssertEqual(allowed.hints.values.last ?? .reason, nil)
        let denied = rig(status: .denied)
        await denied.notifier.handle(input([]), popoverOpen: true)
        XCTAssertFalse(denied.center.log.contains("request"))
        XCTAssertEqual(denied.hints.values.last, .denied)
    }

    func testReopeningTheAppRechecksTheGuidance() async {
        let rig = rig(status: .denied)
        await rig.notifier.refreshPermissionHint()
        XCTAssertEqual(rig.hints.values.last, .denied)
        rig.center.status = .allowed
        await rig.notifier.refreshPermissionHint()
        XCTAssertEqual(rig.hints.values.last ?? .reason, nil)
    }

    // MARK: click routing and copy

    func testTheClickedBattleIdComesBackFromTheUserInfo() {
        XCTAssertEqual(OnlineAttentionNotifier.battleId(fromUserInfo: [OnlineAttentionNotifier.userInfoBattleKey: "bt-9"]), "bt-9")
        XCTAssertNil(OnlineAttentionNotifier.battleId(fromUserInfo: [:]))
        XCTAssertNil(OnlineAttentionNotifier.battleId(fromUserInfo: [OnlineAttentionNotifier.userInfoBattleKey: ""]))
        XCTAssertNil(OnlineAttentionNotifier.battleId(fromUserInfo: [OnlineAttentionNotifier.userInfoBattleKey: 7]))
        XCTAssertNil(OnlineAttentionNotifier.battleId(fromUserInfo: ["companion": "bt-9"]), "Other notifications carry no online battle")
    }

    func testAClickOpensTheOnlineScreenAfterTheResetToHome() {
        let navigation = PopoverNavigation()
        navigation.showSettings = true
        AppDelegate.applyOpenRoute(to: navigation, practiceActive: false, route: AppDelegate.openOnlineScreen)
        XCTAssertTrue(navigation.showingOnlineBattle)
        XCTAssertFalse(navigation.showSettings)
    }

    func testTheGuidanceWordingIsPerLanguageAndPointsToSystemSettings() {
        for hint in [OnlineNotificationHint.reason, .denied] {
            let ko = L(.ko).onlineNotificationHint(hint), en = L(.en).onlineNotificationHint(hint)
            XCTAssertFalse(ko.isEmpty); XCTAssertFalse(en.isEmpty)
            XCTAssertNotEqual(ko, en)
        }
        XCTAssertTrue(L(.ko).onlineNotificationHint(.denied).contains("시스템 설정"))
        XCTAssertTrue(L(.en).onlineNotificationHint(.denied).contains("System Settings"))
        XCTAssertNotEqual(L(.ko).onlineNotificationHint(.reason), L(.ko).onlineNotificationHint(.denied))
    }
}
