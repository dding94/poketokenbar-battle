import XCTest
@testable import PokeTokenBar

@MainActor
final class OnlineBattlePresentationTests: XCTestCase {
    func testJoinSendsTypedActionWithoutExposingAccessKeys() {
        let model = OnlineBattlePresentation()
        var sent = false
        model.onAction = { action in
            if case .join(let code, let email) = action {
                XCTAssertEqual(code, "SYNTHETIC-INVITE")
                XCTAssertEqual(email, "synthetic@example.invalid")
                sent = true
            }
        }
        model.send(.join(inviteCode: "SYNTHETIC-INVITE", email: "synthetic@example.invalid"))
        XCTAssertTrue(sent, "The onboarding form must reach the session through its typed boundary")
    }

    func testApplyingServerReachesTheSessionOnlyForAValidAddressAndASetupRequestOnAManualBuild() {
        let model = OnlineBattlePresentation()
        var sent = 0
        model.onAction = { _ in sent += 1 }
        let join = OnlineBattleUIAction.join(inviteCode: "CODE", email: "나래")
        model.send(.applyingServer("https://battle.example", join))
        model.send(.applyingServer("https://battle.example", .recover(code: "R")))
        model.send(.applyingServer("https://battle.example", .reconnect(code: "C")))
        XCTAssertEqual(sent, 3)
        model.send(.applyingServer("http://battle.example", join))
        model.send(.applyingServer("https://battle.example/path", join))
        model.send(.applyingServer("https://battle.example", .refresh))
        model.send(.applyingServer("https://battle.example", .join(inviteCode: " ", email: "나래")))
        model.send(.applyingServer("https://battle.example", .applyingServer("https://other.example", join)))
        XCTAssertEqual(sent, 3, "bad addresses, non-setup actions and empty inner fields must not reach the session")
        model.isBusy = true
        model.send(.applyingServer("https://battle.example", join))
        XCTAssertEqual(sent, 3)
        model.isBusy = false; model.serverIsEmbedded = true
        model.send(.applyingServer("https://battle.example", join))
        XCTAssertEqual(sent, 3, "an embedded build has no address to apply")
        model.send(join)
        XCTAssertEqual(sent, 4)
    }

    func testUnavailableRosterCannotChallengeAndUnknownMoveCannotReachSession() {
        let model = OnlineBattlePresentation()
        var sent = 0
        model.onAction = { _ in sent += 1 }
        model.send(.challenge)
        model.send(.chooseMove(1))
        XCTAssertFalse(model.canChallenge)
        XCTAssertEqual(sent, 0)
    }
}

extension OnlineBattlePresentationTests {
    func testChallengeRejectsFaintedReservedAndSelfSelectionThenAllowsEligibleEntry() {
        let model = OnlineBattleScreenRenderingTests.model(); model.phase = .lobby
        var challenged = 0
        model.onAction = { if case .challenge = $0 { challenged += 1 } }
        XCTAssertTrue(model.canChallenge)
        model.entryHP["synthetic-pikachu"] = 0
        model.send(.challenge)
        XCTAssertFalse(model.canChallenge)
        model.entryHP["synthetic-pikachu"] = 88
        model.blockedEntryIDs = ["synthetic-pikachu"]
        model.send(.challenge)
        XCTAssertFalse(model.canChallenge)
        model.blockedEntryIDs = []
        model.selectedOpponentID = "synthetic-me"
        model.send(.challenge)
        XCTAssertFalse(model.canChallenge)
        model.selectedOpponentID = "synthetic-foe"
        model.send(.challenge)
        XCTAssertEqual(challenged, 1)
    }
    func testOnlyLegalManualMoveReachesSessionAndSubmittedChoiceCannotRepeat() {
        let model = OnlineBattleScreenRenderingTests.model(); OnlineBattleScreenRenderingTests.arena(model)
        var slots: [Int] = []
        model.onAction = { if case .chooseMove(let slot) = $0 { slots.append(slot) } }
        model.send(.chooseMove(0)); model.send(.chooseMove(4)); model.send(.chooseMove(1))
        model.choiceSubmitted = true; model.send(.chooseMove(2))
        model.choiceSubmitted = false; model.room = OnlineBattleScreenRenderingTests.room(mode: .auto)
        model.send(.chooseMove(2))
        model.room = OnlineBattleScreenRenderingTests.room()
        model.request = .init(kind: "move", moves: [
            .init(slot: 1, id: "thunderbolt", name: "Thunderbolt", type: "Electric", pp: 0, maxpp: 15, disabled: false),
            .init(slot: 2, id: "quickattack", name: "Quick Attack", type: "Normal", pp: 30, maxpp: 30, disabled: true)])
        model.send(.chooseMove(1)); model.send(.chooseMove(2))
        XCTAssertEqual(slots, [1])
    }
    func testPollingCanConsentButCannotPrepareWithoutCurrentHello() {
        let model = OnlineBattleScreenRenderingTests.model(); model.phase = .room; model.localSide = .p2
        model.room = OnlineBattleScreenRenderingTests.room(state: .pending, confirmed: false)
        XCTAssertTrue(model.canAccept)
        model.localSide = .p1; model.room = OnlineBattleScreenRenderingTests.room(state: .accepted, confirmed: false)
        XCTAssertTrue(model.canConfirm)
        model.room = OnlineBattleScreenRenderingTests.room(state: .accepted)
        XCTAssertFalse(model.canPrepare)
        model.canStart = true
        XCTAssertTrue(model.canPrepare)
    }
    func testRecoveryAcknowledgementErasesOneTimeCodeAndDispatchesOnce() {
        let model = OnlineBattlePresentation(); model.recoveryCode = "SYNTHETIC-RECOVERY"
        var acknowledged = 0
        model.onAction = { if case .acknowledgeRecoveryCode = $0 { acknowledged += 1 } }
        model.send(.acknowledgeRecoveryCode); model.send(.acknowledgeRecoveryCode)
        XCTAssertNil(model.recoveryCode); XCTAssertEqual(acknowledged, 1)
    }
    func testBusyCredentialSaveRequiresExplicitRetryAndInvalidOriginCannotDispatch() {
        let model = OnlineBattlePresentation(); var sent = 0
        model.onAction = { _ in sent += 1 }
        model.send(.configureServer("https://server.example.invalid/path"))
        model.send(.retryCredentialSave)
        model.canRetryCredentialSave = true; model.isBusy = true; model.send(.retryCredentialSave)
        XCTAssertEqual(sent, 0)
        model.isBusy = false; model.send(.retryCredentialSave)
        XCTAssertEqual(sent, 1)
    }
}

extension OnlineBattlePresentationTests {
    func testArchiveSortsTerminalMatchesWithoutChallengeExpiryAndKeepsActiveInLobby() {
        let model = OnlineBattleScreenRenderingTests.model()
        model.battles = [
            OnlineBattleScreenRenderingTests.room(state: .completed, id: "older", createdAt: 1),
            OnlineBattleScreenRenderingTests.room(state: .running, id: "live", createdAt: 3),
            OnlineBattleScreenRenderingTests.room(state: .void, id: "newer", createdAt: 2),
            OnlineBattleScreenRenderingTests.room(state: .expired, id: "oldest", createdAt: 0),
        ]
        XCTAssertEqual(model.activeBattles.map(\.battleId), ["live"])
        XCTAssertEqual(model.historyBattles.map(\.battleId), ["newer", "older", "oldest"])
        XCTAssertEqual(L(.ko).onlineHistoryOutcome(model.historyBattles.last!, localTrainerID: "synthetic-me"), "신청 만료")
    }

    func testArchiveNavigationRejectsLiveAndUnknownIDsAndBlocksManualChoices() {
        let model = OnlineBattleScreenRenderingTests.model()
        model.phase = .lobby
        model.battles.append(OnlineBattleScreenRenderingTests.room(state: .completed, id: "past"))
        var actions: [String] = []
        model.onAction = {
            switch $0 {
            case .showHistory: actions.append("show")
            case .openReplay(let id): actions.append(id)
            case .closeReplay: actions.append("close")
            case .chooseMove: actions.append("move")
            default: break
            }
        }
        model.send(.showHistory)
        model.send(.openReplay("synthetic-battle"))
        model.send(.openReplay("unknown"))
        model.send(.openReplay("past"))
        XCTAssertEqual(model.selectedHistoryBattle?.battleId, "past")
        OnlineBattleScreenRenderingTests.arena(model)
        model.send(.chooseMove(1))
        XCTAssertFalse(model.canChooseMove(1))
        model.send(.closeReplay)
        XCTAssertNil(model.selectedHistoryBattle)
        XCTAssertNil(model.replay)
        XCTAssertEqual(actions, ["show", "past", "close"])
    }

    func testHistorySummaryNeverTreatsVoidAsWinOrChallengeExpiryAsArchiveExpiry() {
        let l = L(.ko)
        XCTAssertEqual(l.onlineHistoryOutcome(OnlineBattleScreenRenderingTests.room(state: .void), localTrainerID: "synthetic-me"),
                       "경기 무효 · 기록과 보상 변경 없음")
        XCTAssertEqual(l.onlineHistoryOutcome(OnlineBattleScreenRenderingTests.room(state: .cancelled), localTrainerID: "synthetic-me"),
                       "신청 취소")
        XCTAssertEqual(l.onlineHistoryOutcome(OnlineBattleScreenRenderingTests.room(state: .declined), localTrainerID: "synthetic-me"),
                       "신청 거절")
        XCTAssertEqual(l.onlineHistoryOutcome(OnlineBattleScreenRenderingTests.room(state: .expired), localTrainerID: "synthetic-me"),
                       "신청 만료")
    }
}


extension OnlineBattlePresentationTests {
    func testImmediateSecondManualChoiceCannotSendAnotherRequest() {
        let model = OnlineBattleScreenRenderingTests.model(); OnlineBattleScreenRenderingTests.arena(model)
        var choices = 0
        model.onAction = { if case .chooseMove = $0 { choices += 1 } }
        model.send(.chooseMove(1)); model.send(.chooseMove(2))
        XCTAssertEqual(choices, 1, "The view must latch the first choice before its asynchronous session action starts")
        XCTAssertTrue(model.choiceSubmitted)
    }
}


extension OnlineBattlePresentationTests {
    func testConsentActionsFollowParticipantAndRevisionStateWithoutReusingSelection() {
        let model = OnlineBattleScreenRenderingTests.model(); model.phase = .room
        var events: [String] = []
        model.onAction = { action in
            switch action {
            case .accept: events.append("accept")
            case .confirm: events.append("confirm")
            case .prepareBattle: events.append("prepare")
            case .decline: events.append("decline")
            case .cancel: events.append("cancel")
            default: XCTFail("Unexpected action")
            }
        }
        model.room = OnlineBattleScreenRenderingTests.room(state: .pending, confirmed: false)
        model.localSide = .p1; model.send(.accept(model.room?.battleId ?? "")); model.send(.decline(model.room?.battleId ?? ""))
        model.localSide = .p2; model.entryHP["synthetic-pikachu"] = 0; model.send(.accept(model.room?.battleId ?? ""))
        model.entryHP["synthetic-pikachu"] = 88; model.send(.accept(model.room?.battleId ?? "")); model.send(.decline(model.room?.battleId ?? ""))
        model.room = OnlineBattleScreenRenderingTests.room(state: .accepted, confirmed: false)
        model.send(.confirm(model.room?.battleId ?? ""))
        model.localSide = .p1; model.send(.confirm(model.room?.battleId ?? ""))
        model.room = OnlineBattleScreenRenderingTests.room(state: .accepted)
        model.send(.confirm(model.room?.battleId ?? "")); model.send(.prepareBattle(model.room?.battleId ?? ""))
        model.canStart = true; model.send(.prepareBattle(model.room?.battleId ?? "")); model.send(.cancel(model.room?.battleId ?? ""))
        model.room = OnlineBattleScreenRenderingTests.room(state: .running); model.send(.cancel(model.room?.battleId ?? ""))
        XCTAssertEqual(events, ["accept", "decline", "confirm", "prepare", "cancel"])
    }
    func testSelectionsRejectUnknownAndReservedIDsAndVisibilityAlwaysReachesSession() {
        let model = OnlineBattleScreenRenderingTests.model()
        var visible = false
        model.onAction = { if case .setPopoverVisible(let value) = $0 { visible = value } }
        model.selectedEntryID = nil
        model.send(.selectEntry("unknown"))
        XCTAssertNil(model.selectedEntryID)
        model.blockedEntryIDs = ["synthetic-pikachu"]
        model.send(.selectEntry("synthetic-pikachu")); XCTAssertNil(model.selectedEntryID)
        model.blockedEntryIDs = []; model.send(.selectEntry("synthetic-pikachu"))
        XCTAssertEqual(model.selectedEntryID, "synthetic-pikachu")
        model.selectedOpponentID = nil; model.send(.selectOpponent("synthetic-me"))
        XCTAssertNil(model.selectedOpponentID)
        model.send(.selectOpponent("synthetic-foe")); XCTAssertEqual(model.selectedOpponentID, "synthetic-foe")
        model.send(.setMode(.auto)); XCTAssertEqual(model.mode, .auto)
        model.isBusy = true; model.send(.setPopoverVisible(true)); XCTAssertTrue(visible)
    }
}

// MARK: T15 waiting on the opponent

extension OnlineBattlePresentationTests {
    private static let polling = "화면을 열 때 경기 정보를 확인해요"

    /// A manual round in which my own choice is in and the foe's presence is `online`.
    private func waiting(online: Bool = true, status: String = L.onlineConnectedStatus, submitted: Bool = true) -> OnlineBattlePresentation {
        let model = OnlineBattleScreenRenderingTests.model(); OnlineBattleScreenRenderingTests.arena(model)
        model.members = [.init(trainerId: "synthetic-foe", displayEmail: "연습친구", role: .host, status: .active, joinedAt: 0, online: online)]
        model.connectionStatus = status
        model.choiceSubmitted = submitted
        return model
    }

    func testWaitingOnAnOnlineOpponentIsChoosingAndOnAnOfflineOneIsDisconnected() {
        XCTAssertEqual(waiting(online: true).opponentWait, .choosing)
        XCTAssertEqual(waiting(online: false).opponentWait, .offline)
    }

    /// While the socket is down presence is not refreshed, so an offline flag may be old: it is only a maybe.
    func testAnOfflineFlagFromAStalePresenceIsNeverStatedAsFact() {
        XCTAssertEqual(waiting(online: false, status: Self.polling).opponentWait, .offlineMaybe)
        XCTAssertEqual(waiting(online: false, status: "연결 중").opponentWait, .offlineMaybe)
        XCTAssertEqual(waiting(online: false, status: "").opponentWait, .offlineMaybe)
        // An old "online" proves nothing either way, so it keeps the neutral line.
        XCTAssertEqual(waiting(online: true, status: Self.polling).opponentWait, .choosing)
    }

    func testTheOpponentIsTheOtherSeatNotAlwaysThePlayerTwo() {
        let model = waiting(online: true)
        model.localSide = .p2   // the foe is now p1, "synthetic-me" in this fixture room
        model.members = [.init(trainerId: "synthetic-me", displayEmail: "상대", role: .member, status: .active, joinedAt: 0, online: false),
                         .init(trainerId: "synthetic-foe", displayEmail: "나", role: .host, status: .active, joinedAt: 0, online: true)]
        XCTAssertEqual(model.opponentWait, .offline)
    }

    func testNothingToWaitForUnlessMyChoiceIsInOnAManualRound() {
        XCTAssertNil(waiting(submitted: false).opponentWait, "still choosing myself")
        let auto = waiting(); auto.room = OnlineBattleScreenRenderingTests.room(mode: .auto)
        XCTAssertNil(auto.opponentWait)
        let pending = waiting(); pending.room = OnlineBattleScreenRenderingTests.room(state: .pending)
        XCTAssertNil(pending.opponentWait)
        let lobby = waiting(); lobby.phase = .lobby
        XCTAssertNil(lobby.opponentWait)
        let unknown = waiting(); unknown.members = []
        XCTAssertEqual(unknown.opponentWait, .choosing, "no presence record is not a disconnect")
    }

    func testTheChosenSlotComesFromMyClickThenFromTheServersOwnChoice() {
        let model = OnlineBattleScreenRenderingTests.model(); OnlineBattleScreenRenderingTests.arena(model)
        XCTAssertNil(model.chosenSlot)
        model.send(.chooseMove(2))
        XCTAssertEqual(model.chosenSlot, 2)
        // The server's record wins once it arrives; a restored room shows it without any click here.
        model.room = Self.room(roundSeq: 1, ownChoice: "move 1")
        XCTAssertEqual(model.chosenSlot, 1)
        model.choiceSubmitted = false
        XCTAssertNil(model.chosenSlot, "nothing is chosen in a round whose choice is not in")
    }

    /// A click from an earlier round must not mark a card in the next one.
    func testAClickFromAnEarlierRoundDoesNotMarkTheNextRound() {
        let model = OnlineBattleScreenRenderingTests.model(); OnlineBattleScreenRenderingTests.arena(model)
        model.send(.chooseMove(2))
        model.room = Self.room(roundSeq: 2, ownChoice: nil)
        model.choiceSubmitted = true   // e.g. the session restored a choice it could not name
        XCTAssertNil(model.chosenSlot)
    }

    // MARK: T16 the opponent has chosen

    /// The fixture room as the server's view would carry the flag.
    private static func room(opponentSubmitted: Bool?, mode: OnlineBattleMode = .manual, state: OnlineBattleState = .running) throws -> OnlineBattleView {
        let base = OnlineBattleScreenRenderingTests.room(state: state, mode: mode)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: BattleJSON.encoder().encode(base)) as? [String: Any])
        json["opponentSubmitted"] = opponentSubmitted.map { $0 as Any }
        return try JSONDecoder().decode(OnlineBattleView.self, from: JSONSerialization.data(withJSONObject: json))
    }

    /// The flag alone is enough: it also shows while I have not chosen yet, which is what makes the other side's
    /// choice felt. It wins over an offline presence, since a choice that is in is in.
    func testTheOpponentHavingChosenShowsWhetherOrNotMyChoiceIsIn() throws {
        for mine in [false, true] {
            let model = waiting(online: true, submitted: mine)
            model.room = try Self.room(opponentSubmitted: true)
            XCTAssertEqual(model.opponentWait, .submitted, "my choice in: \(mine)")
        }
        let offline = waiting(online: false); offline.room = try Self.room(opponentSubmitted: true)
        XCTAssertEqual(offline.opponentWait, .submitted)
    }

    func testWithoutTheFlagTheWaitStaysChoosingAsBefore() throws {
        for flag in [nil, false] as [Bool?] {
            let model = waiting(online: true); model.room = try Self.room(opponentSubmitted: flag)
            XCTAssertEqual(model.opponentWait, .choosing, "flag \(String(describing: flag))")
            let idle = waiting(submitted: false); idle.room = try Self.room(opponentSubmitted: flag)
            XCTAssertNil(idle.opponentWait, "flag \(String(describing: flag)), nothing sent")
        }
    }

    func testTheFlagIsIgnoredOutsideALiveManualRound() throws {
        let auto = waiting(); auto.room = try Self.room(opponentSubmitted: true, mode: .auto)
        XCTAssertNil(auto.opponentWait)
        let pending = waiting(); pending.room = try Self.room(opponentSubmitted: true, state: .pending)
        XCTAssertNil(pending.opponentWait)
        let lobby = waiting(); lobby.room = try Self.room(opponentSubmitted: true); lobby.phase = .lobby
        XCTAssertNil(lobby.opponentWait)
    }

    private static func room(roundSeq: Int, ownChoice: String?) -> OnlineBattleView {
        let base = OnlineBattleScreenRenderingTests.room()
        return .init(battleId: base.battleId, state: .running, revision: 1, mode: .manual, p1: base.p1, p2: base.p2,
                     createdAt: base.createdAt, expiresAt: base.expiresAt, startedAt: 0, reportedAt: nil, confirmed: true,
                     config: nil, roundSeq: roundSeq, deadline: nil, ownChoice: ownChoice, journal: [], result: nil, reason: nil, rematchOf: nil)
    }
}
