import XCTest
@testable import PokeTokenBar

@MainActor
final class OnlineBattleSetupTests: XCTestCase {
    func testPastedServerIsCanonicalizedAndInvalidOriginsStayUnavailable() {
        XCTAssertEqual(OnlineBattleSetupInput(server: "  https://BATTLE.example:443/\n").serverToApply, "https://battle.example")
        for value in ["", "http://battle.example", "https://battle.example/path", "https://name@battle.example"] {
            XCTAssertNil(OnlineBattleSetupInput(server: value).serverToApply)
        }
    }
    func testJoinExplainsEachMissingInputInOrder() {
        var input = OnlineBattleSetupInput()
        XCTAssertEqual(input.requirement(appliedServer: "", isBusy: false), .serverMissing)
        input.server = "https://battle.example"
        XCTAssertEqual(input.requirement(appliedServer: "", isBusy: false), .serverChanged)
        XCTAssertEqual(input.requirement(appliedServer: input.server, isBusy: false), .inviteMissing)
        input.invite = "CODE"
        XCTAssertEqual(input.requirement(appliedServer: input.server, isBusy: false), .nicknameMissing)
        input.nickname = "딩"
        XCTAssertEqual(input.requirement(appliedServer: input.server, isBusy: false), .ready)
        XCTAssertEqual(input.requirement(appliedServer: input.server, isBusy: true), .busy)
    }
    func testChangedDraftNeverJoinsOrRecoversAgainstTheOldServer() {
        let input = OnlineBattleSetupInput(server: "https://new.example", invite: "CODE", nickname: "딩")
        XCTAssertFalse(input.hasAppliedServer("https://old.example"))
        XCTAssertNil(input.joinAction(appliedServer: "https://old.example", isBusy: false))
        XCTAssertTrue(input.hasAppliedServer("https://new.example/"))
    }
    func testNicknameAndInviteAreTrimmedBeforeTypedJoin() {
        let input = OnlineBattleSetupInput(server: "https://battle.example", invite: "  CODE\n", nickname: "  딩딩  ")
        guard case let .join(code, nickname)? = input.joinAction(appliedServer: input.server, isBusy: false) else {
            return XCTFail("Complete setup must enable and dispatch join")
        }
        XCTAssertEqual(code, "CODE"); XCTAssertEqual(nickname, "딩딩")
    }
    func testWhitespaceAndBusyStateDoNotDispatchJoin() {
        var input = OnlineBattleSetupInput(server: "https://battle.example", invite: " \n", nickname: "딩")
        XCTAssertNil(input.joinAction(appliedServer: input.server, isBusy: false))
        input.invite = "CODE"; input.nickname = " \n"
        XCTAssertNil(input.joinAction(appliedServer: input.server, isBusy: false))
        input.nickname = "딩"
        XCTAssertNil(input.joinAction(appliedServer: input.server, isBusy: true))
    }
}
