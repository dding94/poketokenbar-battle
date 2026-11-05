import XCTest
@testable import PokeTokenBar

@MainActor
final class OnlineBattleSetupTests: XCTestCase {
    private let embedded = "https://battle.example"
    private let code = "ABCD-EFGH-JKMN"
    private let drafts = OnlineBattleSetupInput(server: "https://old.example", invite: "old", nickname: "나래", recovery: "recovery", reconnect: "reconnect")

    // MARK: Paste on an embedded build (one line)

    func testEmbeddedBuildAcceptsAOneLineCodeWithWhitespaceAndNewlinesMixedIn() {
        for text in ["ABCD-EFGH-JKMN", "  abcd efgh jkmn \n\n", "\nABCD-EFGH-JKMN\n", "ABCD\nEFGH\nJKMN", "\t ABCD  -  EFGH-JKMN\r\n",
                     "초대코드: ABCD-EFGH-JKMN", "Invite code: abcd-efgh-jkmn", "초대 코드：ABCD-EFGH-JKMN"] {
            var input = drafts
            XCTAssertNil(input.pasteInvitation(text, embeddedServer: embedded), text)
            XCTAssertEqual(input.invite, "ABCDEFGHJKMN", text)
            XCTAssertEqual(input.server, "https://old.example", "an embedded build never takes a server from the clipboard")
            XCTAssertEqual(input.nickname, "나래"); XCTAssertEqual(input.recovery, "recovery"); XCTAssertEqual(input.reconnect, "reconnect")
        }
    }
    func testEmbeddedBuildAcceptsALegacyTwoLineInvitationOnlyForItsOwnServer() {
        var input = drafts
        XCTAssertNil(input.pasteInvitation("서버 주소: https://BATTLE.example:443/\n초대코드: " + code, embeddedServer: embedded))
        XCTAssertEqual(input.invite, "ABCDEFGHJKMN")
        var other = drafts
        XCTAssertEqual(other.pasteInvitation("서버 주소: https://other.example\n초대코드: " + code, embeddedServer: embedded), .serverMismatch)
        XCTAssertEqual(other, drafts)
    }

    // MARK: Paste on a manual build (two lines)

    func testManualBuildAcceptsKoreanEnglishAndPlainTwoLinesWithoutChangingNickname() {
        for text in ["서버 주소: https://BATTLE.example:443/\n초대코드: ABCD-EFGH-JKMN",
                     "Server address: https://battle.example\nInvite code: abcd-efgh-jkmn",
                     "abcd efgh jkmn\nhttps://battle.example",
                     "서버：https://battle.example\n초대 코드：o1il-2345-6789"] {
            var input = drafts
            XCTAssertNil(input.pasteInvitation(text, embeddedServer: nil), text)
            XCTAssertEqual(input.server, "https://battle.example")
            XCTAssertEqual(input.invite, text.contains("o1il") ? "011123456789" : "ABCDEFGHJKMN")
            XCTAssertEqual(input.nickname, "나래")
            XCTAssertEqual(input.recovery, "recovery"); XCTAssertEqual(input.reconnect, "reconnect")
        }
    }
    func testManualBuildTakesAOneLineCodeOnlyWhenAServerIsAlreadyTyped() {
        var withServer = drafts
        XCTAssertNil(withServer.pasteInvitation(code, embeddedServer: nil))
        XCTAssertEqual(withServer.invite, "ABCDEFGHJKMN"); XCTAssertEqual(withServer.server, "https://old.example")
        var noServer = OnlineBattleSetupInput(invite: "old", nickname: "나래")
        let original = noServer
        XCTAssertEqual(noServer.pasteInvitation(code, embeddedServer: nil), .serverMissing)
        XCTAssertEqual(noServer, original)
    }

    // MARK: Specific failures leave every draft intact

    func testEachPasteFailureNamesItsOwnCauseAndLeavesEveryDraftUnchanged() {
        let cases: [(String?, String?, OnlineBattleSetupInput.PasteFailure)] = [
            (nil, embedded, .empty), ("", embedded, .empty), (" \n\t ", nil, .empty),
            (String(repeating: "a", count: 4097), embedded, .tooLong),
            ("hello there", embedded, .noInviteCode), ("ABCD-EFGH-JKMU", embedded, .noInviteCode), ("ABCDEFGHJKM", nil, .noInviteCode),
            ("https://battle.example", embedded, .noInviteCode),
            ("http://battle.example\nABCD-EFGH-JKMN", nil, .invalidServer),
            ("https://battle.example/path\nABCD-EFGH-JKMN", nil, .invalidServer),
            ("https://name@battle.example\nABCD-EFGH-JKMN", nil, .invalidServer),
            ("https://battle.example?key=x\nABCD-EFGH-JKMN", nil, .invalidServer),
            ("https://battle.example#fragment\nABCD-EFGH-JKMN", nil, .invalidServer),
            ("ABCD-EFGH-JKMN\n1234-5678-9012", embedded, .ambiguous),
            ("https://one.example\nhttps://two.example", nil, .ambiguous),
            ("https://battle.example\nABCD-EFGH-JKMN\n1234-5678-9012", nil, .ambiguous),
            ("서버 주소: ABCD-EFGH-JKMN\n초대코드: https://battle.example", nil, .invalidServer),
            ("안녕하세요!\n초대코드 보내요.", embedded, .noInviteCode),
        ]
        for (text, embeddedServer, expected) in cases {
            var input = drafts
            XCTAssertEqual(input.pasteInvitation(text, embeddedServer: embeddedServer), expected, text ?? "nil")
            XCTAssertEqual(input, drafts, text ?? "nil")
        }
    }
    func testEveryPasteFailureHasItsOwnNonEmptyMessageInBothLanguages() {
        let failures: [OnlineBattleSetupInput.PasteFailure] = [.empty, .tooLong, .noInviteCode, .invalidServer, .serverMismatch, .serverMissing, .ambiguous]
        for lang in [AppLanguage.ko, .en] {
            let messages = failures.map { L(lang).onlinePasteFailure($0) }
            XCTAssertEqual(Set(messages).count, failures.count, "failure texts must be distinct")
            XCTAssertTrue(messages.allSatisfy { !$0.isEmpty })
        }
    }
    func testPastedServerIsCanonicalizedAndInvalidOriginsStayUnavailable() {
        XCTAssertEqual(OnlineBattleSetupInput(server: "  https://BATTLE.example:443/\n").serverToApply, "https://battle.example")
        for value in ["", "http://battle.example", "https://battle.example/path", "https://name@battle.example"] {
            XCTAssertNil(OnlineBattleSetupInput(server: value).serverToApply)
        }
    }

    // MARK: Requirements

    func testEmbeddedJoinNeedsOnlyNicknameThenInviteAndNeverAServer() {
        var input = OnlineBattleSetupInput()
        XCTAssertEqual(input.requirement(isBusy: false, serverIsEmbedded: true), .nicknameMissing)
        input.nickname = "딩"
        XCTAssertEqual(input.requirement(isBusy: false, serverIsEmbedded: true), .inviteMissing)
        input.invite = "CODE"
        XCTAssertEqual(input.requirement(isBusy: false, serverIsEmbedded: true), .ready)
        XCTAssertEqual(input.requirement(isBusy: true, serverIsEmbedded: true), .busy)
        XCTAssertNotNil(input.joinAction(appliedServer: embedded, isBusy: false, serverIsEmbedded: true))
    }
    func testManualJoinNeedsAServerButNeverAnApplyStep() {
        var input = OnlineBattleSetupInput(invite: "CODE", nickname: "딩")
        XCTAssertEqual(input.requirement(isBusy: false, serverIsEmbedded: false), .serverMissing)
        input.server = "https://battle.example"
        // The draft differs from the applied address: that no longer blocks, join applies it first.
        XCTAssertEqual(input.requirement(isBusy: false, serverIsEmbedded: false), .ready)
        XCTAssertEqual(input.requirement(isBusy: true, serverIsEmbedded: false), .busy)
    }
    func testNicknameRulesMatchTheServer() {
        for bad in ["a b", "a\tb", "a\u{200B}b", String(repeating: "가", count: 255)] {
            let input = OnlineBattleSetupInput(invite: "CODE", nickname: bad)
            XCTAssertEqual(input.requirement(isBusy: false, serverIsEmbedded: true), .nicknameInvalid, bad)
            XCTAssertNil(input.joinAction(appliedServer: embedded, isBusy: false, serverIsEmbedded: true))
        }
        for good in ["딩", " 딩딩 ", String(repeating: "가", count: 254), "ding@example.com"] {
            let input = OnlineBattleSetupInput(invite: "CODE", nickname: good)
            XCTAssertEqual(input.requirement(isBusy: false, serverIsEmbedded: true), .ready, good)
        }
    }

    // MARK: Actions

    func testManualJoinAppliesAChangedAddressFirstAndPlainJoinOtherwise() {
        let input = OnlineBattleSetupInput(server: "  https://NEW.example:443/ ", invite: "  CODE\n", nickname: "  딩딩  ")
        guard case let .applyingServer(address, inner)? = input.joinAction(appliedServer: "https://old.example", isBusy: false, serverIsEmbedded: false),
              case let .join(code, nickname) = inner else { return XCTFail("a changed address must be applied by the join itself") }
        XCTAssertEqual(address, "https://new.example"); XCTAssertEqual(code, "CODE"); XCTAssertEqual(nickname, "딩딩")
        guard case let .join(plainCode, plainNickname)? = input.joinAction(appliedServer: "https://new.example/", isBusy: false, serverIsEmbedded: false) else {
            return XCTFail("an already applied address needs no extra step")
        }
        XCTAssertEqual(plainCode, "CODE"); XCTAssertEqual(plainNickname, "딩딩")
    }
    func testEmbeddedBuildNeverWrapsAnActionInAServerChange() {
        let input = OnlineBattleSetupInput(server: "https://stale-draft.example", invite: "CODE", nickname: "딩", recovery: "R", reconnect: "C")
        for action in [input.joinAction(appliedServer: embedded, isBusy: false, serverIsEmbedded: true),
                       input.recoverAction(appliedServer: embedded, isBusy: false, serverIsEmbedded: true),
                       input.reconnectAction(appliedServer: embedded, isBusy: false, serverIsEmbedded: true)] {
            guard let action else { return XCTFail("embedded recovery and join must stay available") }
            if case .applyingServer = action { XCTFail("embedded builds have nothing to apply") }
        }
    }
    func testRecoveryAndReconnectKeepWorkingAndApplyAManualAddressFirst() {
        var input = OnlineBattleSetupInput(server: "https://new.example", recovery: " RECOVERY ", reconnect: " RECONNECT ")
        guard case let .applyingServer(_, .recover(code: recovery))? = input.recoverAction(appliedServer: "https://old.example", isBusy: false, serverIsEmbedded: false),
              case let .applyingServer(_, .reconnect(code: reconnect))? = input.reconnectAction(appliedServer: "https://old.example", isBusy: false, serverIsEmbedded: false) else {
            return XCTFail("manual recovery must apply the typed address first")
        }
        XCTAssertEqual(recovery, "RECOVERY"); XCTAssertEqual(reconnect, "RECONNECT")
        guard case .recover? = input.recoverAction(appliedServer: "https://new.example", isBusy: false, serverIsEmbedded: false) else { return XCTFail() }
        XCTAssertNil(input.recoverAction(appliedServer: "https://new.example", isBusy: true, serverIsEmbedded: false))
        input.recovery = "  "; input.reconnect = ""
        XCTAssertNil(input.recoverAction(appliedServer: embedded, isBusy: false, serverIsEmbedded: true))
        XCTAssertNil(input.reconnectAction(appliedServer: embedded, isBusy: false, serverIsEmbedded: true))
        input.recovery = "R"; input.server = ""
        XCTAssertNil(input.recoverAction(appliedServer: "", isBusy: false, serverIsEmbedded: false), "no address anywhere: nothing to recover against")
    }
    func testNicknameAndInviteAreTrimmedBeforeTypedJoin() {
        let input = OnlineBattleSetupInput(invite: "  CODE\n", nickname: "  딩딩  ")
        guard case let .join(code, nickname)? = input.joinAction(appliedServer: embedded, isBusy: false, serverIsEmbedded: true) else {
            return XCTFail("Complete setup must enable and dispatch join")
        }
        XCTAssertEqual(code, "CODE"); XCTAssertEqual(nickname, "딩딩")
    }
    func testWhitespaceAndBusyStateDoNotDispatchJoin() {
        var input = OnlineBattleSetupInput(invite: " \n", nickname: "딩")
        XCTAssertNil(input.joinAction(appliedServer: embedded, isBusy: false, serverIsEmbedded: true))
        input.invite = "CODE"; input.nickname = " \n"
        XCTAssertNil(input.joinAction(appliedServer: embedded, isBusy: false, serverIsEmbedded: true))
        input.nickname = "딩"
        XCTAssertNil(input.joinAction(appliedServer: embedded, isBusy: true, serverIsEmbedded: true))
    }

    // MARK: Copy

    func testSetupCopyHasNoStepNumbersOrApplyStep() {
        for lang in [AppLanguage.ko, .en] {
            let l = L(lang)
            let requirements: [OnlineBattleSetupInput.Requirement] = [.busy, .serverMissing, .inviteMissing, .nicknameMissing, .nicknameInvalid, .ready]
            var texts = requirements.map { l.onlineSetupRequirement($0) }
            texts += [l.onlineNicknameHint, l.onlineServerHint, l.onlinePasteInvitation, l.onlinePasteInvitationEmbedded, l.onlineAdvanced]
            for text in texts {
                XCTAssertFalse(text.contains("①") || text.contains("②"), text)
                XCTAssertFalse(text.contains("적용") || text.lowercased().contains("apply"), text)
            }
            XCTAssertTrue(l.onlineNicknameHint.contains("254"), "the nickname length limit must be shown")
        }
    }
}
