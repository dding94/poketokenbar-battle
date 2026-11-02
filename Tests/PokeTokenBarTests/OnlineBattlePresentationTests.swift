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
