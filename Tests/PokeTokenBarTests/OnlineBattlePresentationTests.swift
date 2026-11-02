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
    func testImmediateSecondManualChoiceCannotSendAnotherRequest() {
        let model = OnlineBattleScreenRenderingTests.model(); OnlineBattleScreenRenderingTests.arena(model)
        var choices = 0
        model.onAction = { if case .chooseMove = $0 { choices += 1 } }
        model.send(.chooseMove(1)); model.send(.chooseMove(2))
        XCTAssertEqual(choices, 1, "The view must latch the first choice before its asynchronous session action starts")
        XCTAssertTrue(model.choiceSubmitted)
    }
}
