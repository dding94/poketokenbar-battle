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
    /// Set to leave the system dialog up until `answerRequest()`.
    var holdsRequest = false
    private var answer: CheckedContinuation<Void, Never>?
    private var asked: CheckedContinuation<Void, Never>?
    func waitUntilAsked() async {
        if log.contains("request") { return }
        await withCheckedContinuation { asked = $0 }
    }
    func answerRequest() { answer?.resume(); answer = nil }
    func requestPermission() async -> Bool {
        log.append("request")
        asked?.resume(); asked = nil
        // Only the first: a regression asks twice and has to fail on the count, not hang on a second dialog.
        if holdsRequest { holdsRequest = false; await withCheckedContinuation { answer = $0 } }
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

    private func room(_ id: String, _ state: OnlineBattleState, mine: OnlineBattleSide = .p2, confirmed: Bool = false, rematchOf: String? = nil,
                      deadlineIn seconds: Double? = nil, round: Int = 1, reason: String? = nil, revision: Int = 1, createdAt: Double = 1) -> OnlineBattleView {
        let me = OnlineBattlePlayer(trainerId: "synthetic-me", snapshot: nil, publicInfo: nil, hpPercent: nil)
        let foe = OnlineBattlePlayer(trainerId: "synthetic-foe", snapshot: nil, publicInfo: nil, hpPercent: nil)
        return .init(battleId: id, state: state, revision: revision, mode: .manual, p1: mine == .p1 ? me : foe, p2: mine == .p1 ? foe : me, createdAt: createdAt,
                     expiresAt: Self.now.timeIntervalSince1970 * 1000 + 3_600_000, startedAt: nil, reportedAt: nil, confirmed: confirmed,
                     config: nil, roundSeq: round, deadline: seconds.map { (Self.now.timeIntervalSince1970 + $0) * 1000 }, ownChoice: nil,
                     journal: [], result: nil, reason: reason, rematchOf: rematchOf)
    }

    private func input(_ battles: [OnlineBattleView], signedIn: Bool = true, at now: Date = OnlineAttentionNotifierTests.now,
                       own: Set<String> = [], acknowledged: Set<String> = [], screen: Bool = false,
                       phase: OnlineBattlePresentation.Phase = .lobby) -> OnlineAttentionInput {
        let model = OnlineBattlePresentation()
        if signedIn {
            model.account = .init(trainer: .init(trainerId: "synthetic-me", displayEmail: "나래", role: .member, status: .active),
                                  group: .init(groupId: "synthetic-group", name: "동료들", hostTrainerId: "synthetic-foe"))
        }
        model.members = [.init(trainerId: "synthetic-foe", displayEmail: Self.nickname, role: .member, status: .active, joinedAt: 0, online: true)]
        model.battles = battles
        model.ownEndedBattleIDs = own; model.acknowledgedEndedBattleIDs = acknowledged; model.phase = phase
        return OnlineAttentionSource(presentation: model).input(now: now, onlineScreenShowing: screen)
    }

    private struct Rig {
        let center: FakeCenter
        let store: MemoryStore
        let notifier: OnlineAttentionNotifier
        let hints: HintLog
        let ended: EndedLog
    }
    @MainActor final class HintLog { var values: [OnlineNotificationHint?] = [] }
    @MainActor final class EndedLog { var unread: Set<String> = []; var read: [String] = [] }

    private func rig(status: OnlineNotificationPermission = .allowed, grants: Bool = true, store: MemoryStore = MemoryStore()) -> Rig {
        let center = FakeCenter(status: status, grantsRequest: grants)
        let hints = HintLog()
        let ended = EndedLog()
        let notifier = OnlineAttentionNotifier(center: center, store: store, l: { L(.ko) }, setHint: { hint in
            hints.values.append(hint)
            center.log.append("hint:\(hint.map { "\($0)" } ?? "nil")")
        }, syncEnded: { unread, read in
            ended.unread = unread; ended.read += read
        })
        return Rig(center: center, store: store, notifier: notifier, hints: hints, ended: ended)
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

    /// The old test only pinned "no notification" and read as if the popover showed the event. It did not: on Home, the
    /// shop or another room nothing appeared and the seen record used the event up. The banner is now the other half.
    func testAnOpenPopoverTradesTheNotificationForTheBannerAndTheEventStaysSeen() async {
        let rig = rig()
        let incoming = input([room("bt-in", .pending)])
        await rig.notifier.handle(incoming, popoverOpen: true)
        XCTAssertEqual(rig.center.added.count, 0)
        XCTAssertEqual(OnlineAttentionCalculator.banner(incoming)?.battleId, "bt-in", "Without a notification the banner has to say it")
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
            (room("bt-c", .accepted, confirmed: true), "finalConfirmed"),
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

    /// The exact shape 2.6.0 builds wrote. A strict decode would throw it away and ask for the permission again.
    func testAFileFromBeforeTheWaitRecordKeepsEverythingItHad() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-attn-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let old = #"{"seen":{"entries":[{"key":{"battleId":"bt-old","stage":"incomingChallenge"},"revision":3}]},"permissionHandled":true}"#
        try Data(old.utf8).write(to: directory.appendingPathComponent("online-attention-state.json"))
        let state = OnlineAttentionStateFile(directory: directory).load()
        XCTAssertTrue(state.permissionHandled)
        XCTAssertTrue(state.seen.contains(.init(battleId: "bt-old", kind: .incomingChallenge, roundSeq: 0)))
        XCTAssertEqual(state.waits, .init())
    }

    func testTheWaitRecordInTheFileHoldsIdsAndRevisionsOnly() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-attn-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = OnlineAttentionStateFile(directory: directory)
        let notifier = OnlineAttentionNotifier(center: FakeCenter(), store: file, l: { L(.ko) }, setHint: { _ in })
        await notifier.handle(input([room("bt-wait", .pending, mine: .p1), room("bt-gone", .pending, mine: .p1)]), popoverOpen: false)
        await notifier.handle(input([room("bt-wait", .pending, mine: .p1), room("bt-gone", .declined, mine: .p1)]), popoverOpen: false)
        let raw = try String(contentsOf: directory.appendingPathComponent("online-attention-state.json"), encoding: .utf8)
        XCTAssertTrue(raw.contains("bt-wait")); XCTAssertTrue(raw.contains("bt-gone"))
        for secret in [Self.nickname, "나래", "synthetic-foe", "synthetic-me", "DECLINED"] { XCTAssertFalse(raw.contains(secret), secret) }
        XCTAssertEqual(file.load().waits.waiting.map(\.battleId), ["bt-wait"])
        XCTAssertEqual(file.load().waits.unreadEnded.map(\.battleId), ["bt-gone"])
    }

    // MARK: a room I was waiting on ended

    private func endedIDs(_ rig: Rig) -> [String] { rig.center.added.map(\.identifier) }

    func testTheOpponentEndingMyRequestIsAnnouncedOnceWithItsOwnWording() async {
        let cases: [(OnlineBattleState, String?, String)] = [(.declined, nil, "거절"), (.cancelled, nil, "취소"), (.expired, nil, "시간이 지났"), (.cancelled, "participant_left", "떠나")]
        for (state, reason, word) in cases {
            let rig = rig()
            await rig.notifier.handle(input([room("bt-out", .pending, mine: .p1)]), popoverOpen: false)
            XCTAssertEqual(rig.center.added.count, 0, "Waiting alone never rings")
            let ended = input([room("bt-out", state, mine: .p1, reason: reason, revision: 2)])
            await rig.notifier.handle(ended, popoverOpen: false)
            await rig.notifier.handle(ended, popoverOpen: false)
            XCTAssertEqual(endedIDs(rig), ["online-attention.bt-out.requestEnded"], "\(state)")
            let body = rig.center.added.first?.body ?? ""
            XCTAssertTrue(body.contains(Self.nickname) && body.contains(word), body)
            XCTAssertEqual(rig.ended.unread, ["bt-out"], "The mark and the banner read this")
        }
    }

    func testAnEndingWhileTheAppWasOffIsAnnouncedAfterARelaunchAndOnlyOnce() async {
        let store = MemoryStore()
        let before = rig(store: store)
        await before.notifier.handle(input([room("bt-out", .pending, mine: .p1)]), popoverOpen: false)
        let relaunched = rig(store: store)
        // The publish before hello carries no rooms; that proves nothing about the wait.
        await relaunched.notifier.handle(input([]), popoverOpen: false)
        XCTAssertEqual(relaunched.center.added.count, 0)
        let ended = input([room("bt-out", .expired, mine: .p1, revision: 2)])
        await relaunched.notifier.handle(ended, popoverOpen: false)
        XCTAssertEqual(endedIDs(relaunched), ["online-attention.bt-out.requestEnded"])
        let again = rig(store: store)
        await again.notifier.handle(ended, popoverOpen: false)
        XCTAssertEqual(again.center.added.count, 0, "Saved as announced, so a further relaunch stays quiet")
        XCTAssertEqual(again.ended.unread, ["bt-out"], "But it is still unread, so the mark stays")
    }

    func testAFirstRunOverOldFinishedRoomsStaysSilent() async {
        let rig = rig()
        let history = (0..<30).map { room("bt-\($0)", [OnlineBattleState.declined, .cancelled, .expired][$0 % 3], mine: .p1) }
        await rig.notifier.handle(input(history), popoverOpen: false)
        XCTAssertEqual(rig.center.added.count, 0)
        XCTAssertEqual(rig.ended.unread, [])
    }

    func testMyOwnCancelIsNeverAnnouncedEvenAcrossARelaunch() async {
        let store = MemoryStore()
        let first = rig(store: store)
        await first.notifier.handle(input([room("bt-out", .pending, mine: .p1)]), popoverOpen: false)
        // The press records the id before the server answers.
        await first.notifier.handle(input([room("bt-out", .pending, mine: .p1)], own: ["bt-out"]), popoverOpen: false)
        await first.notifier.handle(input([room("bt-out", .cancelled, mine: .p1, revision: 2)], own: ["bt-out"]), popoverOpen: false)
        XCTAssertEqual(first.center.added.count, 0)
        XCTAssertEqual(first.ended.unread, [])
        let relaunched = rig(store: store)
        await relaunched.notifier.handle(input([room("bt-out", .cancelled, mine: .p1, revision: 2)]), popoverOpen: false)
        XCTAssertEqual(relaunched.center.added.count, 0, "The id set is memory only; the dropped wait is what survives")
    }

    /// The press is saved before the server answers, so quitting in between cannot turn my cancel into news.
    func testQuittingBetweenThePressAndTheAnswerStaysQuiet() async {
        let store = MemoryStore()
        let first = rig(store: store)
        await first.notifier.handle(input([room("bt-out", .pending, mine: .p1)]), popoverOpen: false)
        await first.notifier.handle(input([room("bt-out", .pending, mine: .p1)], own: ["bt-out"]), popoverOpen: false)
        XCTAssertEqual(store.state.waits.waiting, [])
        let relaunched = rig(store: store)
        await relaunched.notifier.handle(input([room("bt-out", .cancelled, mine: .p1, revision: 2)]), popoverOpen: false)
        XCTAssertEqual(relaunched.center.added.count, 0)
    }

    func testAnEndingArrivingWithTheOwnIdInTheSameInputIsDropped() async {
        let rig = rig()
        await rig.notifier.handle(input([room("bt-out", .pending, mine: .p1)]), popoverOpen: false)
        await rig.notifier.handle(input([room("bt-out", .cancelled, mine: .p1, revision: 2)], own: ["bt-out"]), popoverOpen: false)
        XCTAssertEqual(rig.center.added.count, 0)
    }

    func testARequestISimplyReceivedIsNotAWait() async {
        let rig = rig()
        await rig.notifier.handle(input([room("bt-in", .pending, mine: .p2)]), popoverOpen: false)
        rig.center.added = []
        await rig.notifier.handle(input([room("bt-in", .cancelled, mine: .p2, revision: 2)]), popoverOpen: false)
        XCTAssertEqual(rig.center.added.count, 0, "Its notification is withdrawn instead")
        XCTAssertEqual(rig.center.withdrawn, ["online-attention.bt-in.incomingChallenge"])
    }

    func testAcceptingMakesTheReceiverWaitToo() async {
        let rig = rig()
        await rig.notifier.handle(input([room("bt-in", .accepted, mine: .p2)]), popoverOpen: false)
        await rig.notifier.handle(input([room("bt-in", .cancelled, mine: .p2, revision: 2)]), popoverOpen: false)
        XCTAssertEqual(endedIDs(rig), ["online-attention.bt-in.requestEnded"])
    }

    func testAMatchThatStartedStopsBeingAWait() async {
        let rig = rig()
        await rig.notifier.handle(input([room("bt-out", .pending, mine: .p1)]), popoverOpen: false)
        await rig.notifier.handle(input([room("bt-out", .running, mine: .p1, deadlineIn: nil)]), popoverOpen: false)
        await rig.notifier.handle(input([room("bt-out", .void, mine: .p1, reason: "participant_left")]), popoverOpen: false)
        XCTAssertEqual(rig.center.added.count, 0)
        XCTAssertEqual(rig.store.state.waits, .init())
    }

    func testSigningOutTouchesNoWait() async {
        let rig = rig()
        await rig.notifier.handle(input([room("bt-out", .pending, mine: .p1)]), popoverOpen: false)
        await rig.notifier.handle(input([], signedIn: false), popoverOpen: false)
        XCTAssertEqual(rig.store.state.waits.waiting.map(\.battleId), ["bt-out"])
    }

    func testAPopoverInFrontGetsTheBannerAndNoNotificationForAnEnding() async {
        let rig = rig()
        await rig.notifier.handle(input([room("bt-out", .pending, mine: .p1)]), popoverOpen: true)
        await rig.notifier.handle(input([room("bt-out", .declined, mine: .p1, revision: 2)]), popoverOpen: true)
        XCTAssertEqual(rig.center.added.count, 0)
        XCTAssertEqual(rig.ended.unread, ["bt-out"], "Still unread: only the banner says so")
        XCTAssertEqual(rig.ended.read, [])
    }

    func testAnEndingOnTheOpenLobbyIsReadAtOnce() async {
        let rig = rig()
        await rig.notifier.handle(input([room("bt-out", .pending, mine: .p1)], screen: true), popoverOpen: true)
        await rig.notifier.handle(input([room("bt-out", .declined, mine: .p1, revision: 2)], screen: true), popoverOpen: true)
        XCTAssertEqual(rig.center.added.count, 0)
        XCTAssertEqual(rig.ended.unread, [])
        XCTAssertEqual(rig.ended.read, ["bt-out"], "The lobby shows it as the closable notice")
    }

    func testAnEndingIsNotReadWhileAnOverlayCoversTheLobby() async {
        let rig = rig()
        let model = OnlineBattlePresentation()
        model.account = .init(trainer: .init(trainerId: "synthetic-me", displayEmail: "나래", role: .member, status: .active),
                              group: .init(groupId: "synthetic-group", name: "동료들", hostTrainerId: "synthetic-foe"))
        model.battles = [room("bt-out", .pending, mine: .p1)]
        model.phase = .lobby; model.showsHistory = true
        await rig.notifier.handle(OnlineAttentionSource(presentation: model).input(now: Self.now, onlineScreenShowing: true), popoverOpen: true)
        model.battles = [room("bt-out", .declined, mine: .p1, revision: 2)]
        await rig.notifier.handle(OnlineAttentionSource(presentation: model).input(now: Self.now, onlineScreenShowing: true), popoverOpen: true)
        XCTAssertEqual(rig.ended.unread, ["bt-out"])
        XCTAssertEqual(rig.ended.read, [])
    }

    func testReadingAnEndingClearsItWithdrawsItsNotificationAndNeverReturns() async {
        let store = MemoryStore()
        let rig = rig(store: store)
        let ended = room("bt-out", .declined, mine: .p1, revision: 2)
        await rig.notifier.handle(input([room("bt-out", .pending, mine: .p1)]), popoverOpen: false)
        await rig.notifier.handle(input([ended]), popoverOpen: false)
        await rig.notifier.handle(input([ended], acknowledged: ["bt-out"]), popoverOpen: false)
        XCTAssertEqual(rig.ended.unread, [])
        XCTAssertEqual(rig.center.withdrawn, ["online-attention.bt-out.requestEnded"])
        await rig.notifier.handle(input([ended]), popoverOpen: false)
        XCTAssertEqual(rig.ended.unread, [], "An older input without the acknowledgement cannot bring it back")
        let relaunched = self.rig(store: store)
        await relaunched.notifier.handle(input([ended]), popoverOpen: false)
        XCTAssertEqual(relaunched.center.added.count, 0)
        XCTAssertEqual(relaunched.ended.unread, [])
    }

    func testTheWaitRecordStaysBounded() async {
        let rig = rig()
        let capacity = OnlineAttentionWaitRecord.capacity
        let many = (0..<(capacity + 10)).map { room("bt-\($0)", .pending, mine: .p1, createdAt: Double($0)) }
        await rig.notifier.handle(input(many), popoverOpen: false)
        XCTAssertEqual(rig.store.state.waits.waiting.count, capacity)
        XCTAssertEqual(rig.store.state.waits.waiting.last?.battleId, "bt-\(capacity + 9)", "The oldest entries go first")
        let endedAll = many.map { room($0.battleId, .expired, mine: .p1) }
        await rig.notifier.handle(input(endedAll), popoverOpen: false)
        XCTAssertLessThanOrEqual(rig.store.state.waits.unreadEnded.count, capacity)
    }

    // MARK: permission

    /// The system question can stay unanswered while the popover is closed. Nothing is off, so the hint must not say so.
    func testAnUnansweredPermissionIsNotReportedAsOff() async {
        let rig = rig(status: .notDetermined)
        await rig.notifier.handle(input([room("bt-in", .pending)]), popoverOpen: false)
        XCTAssertEqual(rig.center.added.count, 0)
        XCTAssertEqual(rig.hints.values.last, .undecided)
        XCTAssertNotEqual(L(.ko).onlineNotificationHint(.undecided), L(.ko).onlineNotificationHint(.denied))
    }

    func testRecheckingAnUnansweredPermissionLeavesTheHintAlone() async {
        let rig = rig(status: .notDetermined)
        await rig.notifier.refreshPermissionHint()
        XCTAssertEqual(rig.hints.values, [])
    }

    /// The dialog stays up across any number of presentation changes, and each of them calls in here.
    func testAnOverlappingCallWhileTheDialogIsUpDoesNotAskTwice() async {
        let rig = rig(status: .notDetermined)
        rig.center.holdsRequest = true
        let first = Task { await rig.notifier.handle(input([]), popoverOpen: true) }
        await rig.center.waitUntilAsked()
        await rig.notifier.handle(input([]), popoverOpen: true)
        XCTAssertEqual(rig.center.log.filter { $0 == "request" }.count, 1)
        XCTAssertFalse(rig.store.state.permissionHandled, "The overlapping call settled nothing")
        rig.center.answerRequest()
        await first.value
        XCTAssertTrue(rig.store.state.permissionHandled)
    }

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
        for hint in [OnlineNotificationHint.reason, .denied, .undecided] {
            let ko = L(.ko).onlineNotificationHint(hint), en = L(.en).onlineNotificationHint(hint)
            XCTAssertFalse(ko.isEmpty); XCTAssertFalse(en.isEmpty)
            XCTAssertNotEqual(ko, en)
        }
        XCTAssertTrue(L(.ko).onlineNotificationHint(.denied).contains("시스템 설정"))
        XCTAssertTrue(L(.en).onlineNotificationHint(.denied).contains("System Settings"))
        XCTAssertNotEqual(L(.ko).onlineNotificationHint(.reason), L(.ko).onlineNotificationHint(.denied))
    }
}
