import XCTest
@testable import PokeTokenBar

/// T11: what a new member meets right after joining and in the first lobby. Presentation and wording only;
/// the screens are drawn in `OnlineBattleOnboardingRenderingTests`. Synthetic data, no network or Keychain.
@MainActor
final class OnlineBattleOnboardingTests: XCTestCase {
    private static let me = "synthetic-me"
    private static let foe = "synthetic-foe"
    private static let now = Date(timeIntervalSince1970: 1_793_683_600)
    private static var nowMS: Double { now.timeIntervalSince1970 * 1000 }

    private func battle(_ id: String, _ state: OnlineBattleState, mine: OnlineBattleSide, mode: OnlineBattleMode = .manual,
                        confirmed: Bool = false, deadline: Double? = nil, ownChoice: String? = nil,
                        rematchOf: String? = nil) -> OnlineBattleView {
        let local = OnlineBattlePlayer(trainerId: Self.me, snapshot: nil, publicInfo: nil, hpPercent: nil)
        let remote = OnlineBattlePlayer(trainerId: Self.foe, snapshot: nil, publicInfo: nil, hpPercent: nil)
        return .init(battleId: id, state: state, revision: 1, mode: mode, p1: mine == .p1 ? local : remote, p2: mine == .p1 ? remote : local,
                     createdAt: 1, expiresAt: Self.nowMS + 3_600_000, startedAt: nil, reportedAt: nil, confirmed: confirmed,
                     config: nil, roundSeq: 1, deadline: deadline, ownChoice: ownChoice, journal: [], result: nil, reason: nil,
                     rematchOf: rematchOf)
    }
    private func model(_ battles: [OnlineBattleView] = []) -> OnlineBattlePresentation {
        let model = OnlineBattlePresentation()
        model.account = .init(trainer: .init(trainerId: Self.me, displayEmail: "나래", role: .member, status: .active),
                              group: .init(groupId: "synthetic-group", name: "동료들", hostTrainerId: Self.foe))
        model.members = [.init(trainerId: Self.foe, displayEmail: "연습친구", role: .host, status: .active, joinedAt: 0, online: true)]
        model.battles = battles; model.phase = .lobby
        return model
    }
    private func badges(_ model: OnlineBattlePresentation) -> [String: OnlineLobbyRowBadge] {
        OnlineLobbyRowBadge.badges(.init(presentation: model, preparedBattleIDs: [], stagingHeldBattleIDs: [], now: Self.now))
    }

    // MARK: the recovery code screen

    /// The keep button is the only way past the code, so it must not open before the person had a way to keep it.
    func testTheKeepButtonStaysClosedUntilTheCodeIsMarkedWrittenDown() {
        let model = OnlineBattlePresentation(); model.recoveryCode = "SYNTHETIC-RECOVERY"
        var acknowledged = 0
        model.onAction = { if case .acknowledgeRecoveryCode = $0 { acknowledged += 1 } }
        XCTAssertFalse(model.canAcknowledgeRecoveryCode)
        model.send(.acknowledgeRecoveryCode)
        XCTAssertEqual(model.recoveryCode, "SYNTHETIC-RECOVERY", "an unchecked press keeps the only copy of the code")
        XCTAssertEqual(acknowledged, 0)
        model.send(.setRecoveryWrittenDown(true))
        XCTAssertTrue(model.canAcknowledgeRecoveryCode)
        model.send(.acknowledgeRecoveryCode); model.send(.acknowledgeRecoveryCode)
        XCTAssertNil(model.recoveryCode)
        XCTAssertEqual(acknowledged, 1)
    }

    func testTheCheckDoesNotCarryOverToANextCode() {
        let model = OnlineBattlePresentation(); model.recoveryCode = "FIRST"
        model.send(.setRecoveryWrittenDown(true))
        model.recoveryCode = nil
        model.recoveryCode = "SECOND"
        XCTAssertFalse(model.recoveryWrittenDown, "a new code starts unchecked")
        model.recoveryCode = nil
        model.send(.setRecoveryWrittenDown(true))
        XCTAssertFalse(model.recoveryWrittenDown, "there is nothing to check without a code")
    }

    /// Copying hands the code to the clipboard and forgets it, the way a host's one-time code goes (T10).
    func testCopyingTheRecoveryCodeForgetsItAndPointsToTheFirstSteps() {
        let model = OnlineBattlePresentation(); model.recoveryCode = "SYNTHETIC-RECOVERY"
        var actions: [OnlineBattleUIAction] = []
        model.onAction = { actions.append($0) }
        model.send(.recoveryCopied)
        XCTAssertNil(model.recoveryCode)
        XCTAssertEqual(model.firstSteps, OnlineBattleFirstSteps(copiedRecoveryCode: true))
        XCTAssertNil(model.notice)
        XCTAssertFalse(actions.map { String(describing: $0) }.joined().contains("SYNTHETIC-RECOVERY"), "no action carries the code")
        let before = model.firstSteps
        model.send(.recoveryCopied)
        XCTAssertEqual(model.firstSteps, before, "a second copy with nothing on screen changes nothing")
    }

    func testKeepingTheCodeShowsTheFirstStepsOnce() {
        let model = OnlineBattlePresentation(); model.recoveryCode = "SYNTHETIC-RECOVERY"
        model.send(.setRecoveryWrittenDown(true)); model.send(.acknowledgeRecoveryCode)
        XCTAssertEqual(model.firstSteps, OnlineBattleFirstSteps(copiedRecoveryCode: false))
        model.send(.dismissFirstSteps)
        XCTAssertNil(model.firstSteps)
        model.send(.acknowledgeRecoveryCode)
        XCTAssertNil(model.firstSteps, "acknowledging again with no code on screen must not bring it back")
    }

    func testTheFirstStepsBelongToTheAccountThatSawTheCode() {
        let model = model(); model.firstSteps = .init(copiedRecoveryCode: false)
        model.account = .init(trainer: .init(trainerId: "synthetic-other", displayEmail: "다온", role: .member, status: .active),
                              group: .init(groupId: "synthetic-group", name: "동료들", hostTrainerId: Self.foe))
        XCTAssertNil(model.firstSteps)
    }

    func testTheRecoveryCodeNeverReachesTheTextTheScreenAndTheLogCanHold() {
        let model = OnlineBattlePresentation(); model.recoveryCode = "SYNTHETIC-RECOVERY"
        model.send(.recoveryCopied)
        for language in [AppLanguage.ko, .en] {
            let l = L(language)
            let words = [l.onlineRecoveryCopied, l.onlineRecoveryCopy, l.onlineRecoveryWrittenDown, l.onlineRecoveryNeedsCheck,
                         l.onlineFirstStepsTitle, l.onlineFirstStepsDismiss] + l.onlineFirstSteps
            XCTAssertFalse(words.joined().contains("SYNTHETIC-RECOVERY"))
        }
        XCTAssertFalse(String(describing: model.firstSteps).contains("SYNTHETIC-RECOVERY"))
        XCTAssertNil(model.notice)
    }

    func testRecoveryWordsExistInBothLanguagesAndTheCopiedLineIsTheHostsWordingForRecovery() {
        let ko = L(.ko), en = L(.en)
        XCTAssertNotEqual(ko.onlineRecoveryCopy, en.onlineRecoveryCopy)
        XCTAssertNotEqual(ko.onlineRecoveryWrittenDown, en.onlineRecoveryWrittenDown)
        XCTAssertNotEqual(ko.onlineRecoveryNeedsCheck, en.onlineRecoveryNeedsCheck)
        XCTAssertNotEqual(ko.onlineRecoveryCopied, en.onlineRecoveryCopied)
        XCTAssertTrue(en.onlineRecoveryCopied.contains("copied and hidden") && en.onlineRecoveryCopied.contains("cannot be shown again"), en.onlineRecoveryCopied)
        XCTAssertTrue(ko.onlineRecoveryCopied.contains("복사하고 화면에서 가렸어요") && ko.onlineRecoveryCopied.contains("다시 볼 수 없"), ko.onlineRecoveryCopied)
        XCTAssertEqual(ko.onlineFirstSteps.count, 3)
        XCTAssertEqual(en.onlineFirstSteps.count, 3)
        XCTAssertNotEqual(ko.onlineFirstSteps, en.onlineFirstSteps)
    }

    // MARK: an empty group

    func testALobbyWithNobodyElseIsEmptyAndSaysWhatToDoPerRole() {
        let alone = model(); alone.members = []
        XCTAssertTrue(alone.lobbyPeers.isEmpty)
        let removed = model(); removed.members = [.init(trainerId: Self.foe, displayEmail: "연습친구", role: .host, status: .left, joinedAt: 0, online: true),
                                                  .init(trainerId: Self.me, displayEmail: "나래", role: .member, status: .active, joinedAt: 0, online: true)]
        XCTAssertTrue(removed.lobbyPeers.isEmpty, "a removed member and myself are not someone to challenge")
        XCTAssertEqual(model().lobbyPeers.map(\.trainerId), [Self.foe])
        let ko = L(.ko)
        XCTAssertEqual(ko.onlineNoPeers(isHost: false), "아직 다른 동료가 없어요. 방장에게 초대코드를 받아 함께 들어오세요.")
        XCTAssertNotEqual(ko.onlineNoPeers(isHost: true), ko.onlineNoPeers(isHost: false), "a host creates the code; a member asks for it")
        XCTAssertNotEqual(L(.en).onlineNoPeers(isHost: false), ko.onlineNoPeers(isHost: false))
    }

    // MARK: rows in the battle list

    func testARowSaysWhetherTheRequestCameToMeOrWentFromMe() {
        let model = model([battle("received", .pending, mine: .p2), battle("sent", .pending, mine: .p1)])
        XCTAssertEqual(badges(model), ["received": .received, "sent": .sent])
        let rematch = model.battles + [battle("again", .pending, mine: .p2, rematchOf: "old")]
        model.battles = rematch
        XCTAssertEqual(badges(model)["again"], .received, "a rematch request is a request I received")
    }

    func testARowSaysItIsMyTurnWhenTheNextMoveIsMine() {
        let deadline = Self.nowMS + 20_000
        let model = model([battle("confirm", .accepted, mine: .p1), battle("wait", .accepted, mine: .p2),
                           battle("ready", .accepted, mine: .p2, confirmed: true),
                           battle("move", .running, mine: .p1, deadline: deadline),
                           battle("chosen", .running, mine: .p1, deadline: deadline, ownChoice: "move 1")])
        let found = badges(model)
        XCTAssertEqual(found["confirm"], .myTurn, "the challenger confirms next")
        XCTAssertNil(found["wait"], "after accepting, the challenger confirms next")
        XCTAssertEqual(found["ready"], .myTurn, "both sides still have to press ready")
        XCTAssertEqual(found["move"], .myTurn)
        XCTAssertNil(found["chosen"], "my choice is in; the opponent is the one left")
    }

    func testFinishedRoomsAndOtherPeoplesRoomsCarryNoBadge() {
        let stranger = OnlineBattlePlayer(trainerId: "synthetic-other", snapshot: nil, publicInfo: nil, hpPercent: nil)
        let source = battle("foreign", .pending, mine: .p2)
        let foreign = OnlineBattleView(battleId: "foreign", state: .pending, revision: 1, mode: .manual, p1: source.p1, p2: stranger,
                                       createdAt: 1, expiresAt: source.expiresAt, startedAt: nil, reportedAt: nil, confirmed: false, config: nil,
                                       roundSeq: 0, deadline: nil, ownChoice: nil, journal: [], result: nil, reason: nil, rematchOf: nil)
        let model = model([foreign, battle("done", .completed, mine: .p1), battle("reported", .reported, mine: .p2)])
        XCTAssertEqual(badges(model), [:])
        model.account = nil
        XCTAssertEqual(badges(model), [:], "no account, no sides")
    }

    func testABadgeNeverStandsAloneOfItsWordsAndEachKindHasItsOwn() {
        for language in [AppLanguage.ko, .en] {
            let l = L(language)
            let words = OnlineLobbyRowBadge.allCases.map(l.onlineLobbyBadge)
            XCTAssertEqual(Set(words).count, OnlineLobbyRowBadge.allCases.count, "\(language)")
            XCTAssertTrue(words.allSatisfy { !$0.isEmpty })
        }
        XCTAssertEqual(L(.ko).onlineLobbyBadge(.received), "받은 신청")
        XCTAssertEqual(L(.ko).onlineLobbyBadge(.sent), "보낸 신청")
        XCTAssertEqual(L(.ko).onlineLobbyBadge(.myTurn), "내 차례")
    }

    // MARK: the line before sending a challenge

    func testTheConfirmationNamesTheOpponentInFullEvenWhenItIsLong() {
        let long = String(repeating: "아주긴닉네임", count: 12)
        XCTAssertTrue(L(.ko).onlineChallengeConfirm(opponent: long).contains(long), "no shortening in the words themselves")
        XCTAssertTrue(L(.en).onlineChallengeConfirm(opponent: long).contains(long))
        XCTAssertTrue(L(.ko).onlineChallengeConfirm(opponent: "다온").contains("다온"))
        XCTAssertNotEqual(L(.ko).onlineChallengeConfirm(opponent: "다온"), L(.en).onlineChallengeConfirm(opponent: "다온"))
    }
}
