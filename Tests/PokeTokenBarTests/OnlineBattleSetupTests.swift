import XCTest
@testable import PokeTokenBar

@MainActor
final class OnlineBattleSetupTests: XCTestCase {
    func testOnlineBattleSharedInvitationAcceptsKoreanEnglishAndPlainLinesWithoutChangingNickname() {
        for text in ["서버 주소: https://BATTLE.example:443/\n초대코드: ABCD-EFGH-JKMN",
                     "Server address: https://battle.example\nInvite code: abcd-efgh-jkmn",
                     "abcd efgh jkmn\nhttps://battle.example",
                     "서버：https://battle.example\n초대 코드：o1il-2345-6789"] {
            var input = OnlineBattleSetupInput(server: "https://old.example", invite: "old", nickname: "나래", recovery: "recovery", reconnect: "reconnect")
            XCTAssertTrue(input.pasteInvitation(text))
            XCTAssertEqual(input.server, "https://battle.example")
            XCTAssertEqual(input.invite, text.contains("o1il") ? "011123456789" : "ABCDEFGHJKMN")
            XCTAssertEqual(input.nickname, "나래")
            XCTAssertEqual(input.recovery, "recovery"); XCTAssertEqual(input.reconnect, "reconnect")
            XCTAssertNil(input.joinAction(appliedServer: "https://old.example", isBusy: false))
        }
    }
    func testOnlineBattleInvalidOrAmbiguousInvitationLeavesEveryDraftUnchanged() {
        let original = OnlineBattleSetupInput(server: "https://old.example", invite: "old", nickname: "나래", recovery: "recovery", reconnect: "reconnect")
        for text in [nil, "", "https://battle.example", "https://battle.example\nABCD-EFGH-JKMU",
                     "https://battle.example/path\nABCD-EFGH-JKMN", "http://battle.example\nABCD-EFGH-JKMN",
                     "https://name@battle.example\nABCD-EFGH-JKMN", "https://battle.example?key=x\nABCD-EFGH-JKMN",
                     "https://battle.example#fragment\nABCD-EFGH-JKMN", "https://battle.example\nABCDEFGHJKM",
                     "https://one.example\nhttps://two.example", "ABCD-EFGH-JKMN\n1234-5678-9012",
                     "서버 주소: ABCD-EFGH-JKMN\n초대코드: https://battle.example",
                     "https://battle.example\nABCD-EFGH-JKMN\n1234-5678-9012", String(repeating: "a", count: 4097)] {
            var input = original
            XCTAssertFalse(input.pasteInvitation(text))
            XCTAssertEqual(input, original)
        }
    }
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
