import XCTest
@testable import PokeTokenBar

/// T06: the room always says which step it is on, whose move it is, whether my press was received,
/// and why a button is disabled. Synthetic data only.
@MainActor
final class OnlineBattleRoomGuideTests: XCTestCase {
    private typealias Fixture = OnlineBattleScreenRenderingTests

    private func challenger(_ state: OnlineBattleState, confirmed: Bool = false) -> OnlineBattlePresentation {
        let model = Fixture.model(); model.phase = .room; model.localSide = .p1; model.canStart = true
        model.room = Fixture.room(state: state, confirmed: confirmed)
        return model
    }
    private func receiver(_ state: OnlineBattleState, confirmed: Bool = false) -> OnlineBattlePresentation {
        let model = Fixture.model(); model.phase = .room; model.localSide = .p2; model.canStart = true
        model.members.append(.init(trainerId: "synthetic-me", displayEmail: "나래", role: .member, status: .active, joinedAt: 0, online: true))
        model.room = Fixture.room(state: state, confirmed: confirmed)
        return model
    }

    // MARK: Step and turn

    func testChallengerSeesEveryStepWithTheOpponentAsTheOneToMove() {
        XCTAssertEqual(challenger(.pending).roomProgress, .init(step: .accept, turn: .theirs, localReady: false))
        XCTAssertEqual(challenger(.accepted).roomProgress, .init(step: .confirm, turn: .mine, localReady: false))
        XCTAssertEqual(challenger(.accepted, confirmed: true).roomProgress, .init(step: .ready, turn: .mine, localReady: false))
    }
    func testReceiverSeesEveryStepWithTheirOwnTurnAtAcceptAndReady() {
        XCTAssertEqual(receiver(.pending).roomProgress, .init(step: .accept, turn: .mine, localReady: false))
        XCTAssertEqual(receiver(.accepted).roomProgress, .init(step: .confirm, turn: .theirs, localReady: false))
        XCTAssertEqual(receiver(.accepted, confirmed: true).roomProgress, .init(step: .ready, turn: .mine, localReady: false))
    }
    func testNoProgressOutsideTheThreeRoomStates() {
        for state in [OnlineBattleState.running, .reported, .completed, .declined, .cancelled, .expired, .void] {
            XCTAssertNil(challenger(state).roomProgress, "\(state)")
        }
        XCTAssertNil(OnlineBattlePresentation().roomProgress)
    }

    // MARK: My press was received

    func testLocalReadyFlipsTheTurnAndDisablesPrepare() {
        for model in [challenger(.accepted, confirmed: true), receiver(.accepted, confirmed: true)] {
            XCTAssertTrue(model.canPrepare)
            model.localReady = true
            XCTAssertEqual(model.roomProgress, .init(step: .ready, turn: .theirs, localReady: true))
            XCTAssertFalse(model.canPrepare, "A second press must not be sent after the server accepted the first")
            var prepared = 0
            model.onAction = { if case .prepareBattle = $0 { prepared += 1 } }
            model.send(.prepareBattle)
            XCTAssertEqual(prepared, 0)
        }
    }
    func testBothReadyReadsAsStartingAndAnUnpreparedAppAfterRelaunchStaysActionable() {
        let both = challenger(.ready, confirmed: true); both.localReady = true
        XCTAssertEqual(both.roomProgress, .init(step: .ready, turn: .none, localReady: true))
        let relaunched = challenger(.ready, confirmed: true)
        XCTAssertEqual(relaunched.roomProgress, .init(step: .ready, turn: .mine, localReady: false))
        XCTAssertTrue(relaunched.canPrepare, "READY with no local acknowledgement must still be able to resume the start")
    }

    // MARK: Why a button is disabled

    func testChallengeBlockNamesEachReasonDistinctly() {
        let model = Fixture.model(); model.phase = .lobby
        XCTAssertNil(model.challengeBlock)
        XCTAssertTrue(model.canChallenge)
        model.selectedOpponentID = nil
        XCTAssertEqual(model.challengeBlock, .noOpponent)
        model.selectedOpponentID = "synthetic-foe"
        model.selectedEntryID = nil
        XCTAssertEqual(model.challengeBlock, .noEntry)
        model.roster = []
        XCTAssertEqual(model.challengeBlock, .noEntry)
        let fresh = Fixture.model(); fresh.phase = .lobby
        fresh.entryHP["synthetic-pikachu"] = 0
        XCTAssertEqual(fresh.challengeBlock, .fainted)
        fresh.entryHP["synthetic-pikachu"] = 88; fresh.blockedEntryIDs = ["synthetic-pikachu"]
        XCTAssertEqual(fresh.challengeBlock, .held)
        fresh.blockedEntryIDs = []; fresh.isBusy = true
        XCTAssertEqual(fresh.challengeBlock, .busy)
        let blocks: Set<OnlineActionBlock> = [.noOpponent, .noEntry, .fainted, .held, .busy]
        XCTAssertEqual(blocks.count, 5)
    }
    func testChallengeBlockAgreesWithCanChallengeAcrossStates() {
        let model = Fixture.model(); model.phase = .lobby
        for opponent in [nil, "synthetic-foe", "synthetic-me"] as [String?] {
            for hp in [0, 88] {
                model.selectedOpponentID = opponent; model.entryHP["synthetic-pikachu"] = hp
                XCTAssertEqual(model.challengeBlock == nil, model.canChallenge, "opponent \(String(describing: opponent)) hp \(hp)")
            }
        }
    }
    func testAcceptBlockExplainsAFaintedOrMissingEntryAndBusy() {
        let model = receiver(.pending)
        XCTAssertNil(model.acceptBlock); XCTAssertTrue(model.canAccept)
        model.entryHP["synthetic-pikachu"] = 0
        XCTAssertEqual(model.acceptBlock, .fainted)
        model.entryHP["synthetic-pikachu"] = 88; model.selectedEntryID = nil
        XCTAssertEqual(model.acceptBlock, .noEntry)
        model.selectedEntryID = "synthetic-pikachu"; model.isBusy = true
        XCTAssertEqual(model.acceptBlock, .busy)
    }
    func testPrepareBlockShowsConnectingUntilTheSocketHelloArrives() {
        let model = challenger(.accepted, confirmed: true)
        XCTAssertNil(model.prepareBlock)
        model.canStart = false
        XCTAssertEqual(model.prepareBlock, .connecting)
        XCTAssertFalse(model.canPrepare)
        model.isBusy = true
        XCTAssertEqual(model.prepareBlock, .busy)
        model.isBusy = false; model.canStart = true; model.localReady = true
        XCTAssertNil(model.prepareBlock, "After my press the button states my own readiness instead of a block")
    }

    // MARK: Names, offline warning, request age

    func testOpponentNameFollowsMySideAndOfflineWarningFollowsTheSelectedMember() {
        XCTAssertEqual(challenger(.pending).roomOpponentName, "연습친구")
        XCTAssertEqual(receiver(.pending).roomOpponentName, "나래")
        let lobby = Fixture.model(); lobby.phase = .lobby
        XCTAssertFalse(lobby.selectedOpponentOffline)
        lobby.members = [.init(trainerId: "synthetic-foe", displayEmail: "연습친구", role: .host, status: .active, joinedAt: 0, online: false)]
        XCTAssertTrue(lobby.selectedOpponentOffline)
        lobby.selectedOpponentID = nil
        XCTAssertFalse(lobby.selectedOpponentOffline, "No warning without a selected opponent")
    }
    func testRequestAgeCountsFromCreationAndNeverGoesNegative() {
        let model = challenger(.pending)
        let created = Date(timeIntervalSince1970: 1_793_683_500)
        XCTAssertEqual(model.requestAge(now: created.addingTimeInterval(190)) ?? -1, 190, accuracy: 0.001)
        XCTAssertEqual(model.requestAge(now: created.addingTimeInterval(-5)) ?? -1, 0, accuracy: 0.001)
        XCTAssertNil(OnlineBattlePresentation().requestAge(now: created))
    }

    // MARK: Wording

    func testKoreanWordingMatchesTheAgreedLinesAndNamesTheOpponent() {
        let l = L(.ko)
        XCTAssertEqual(l.onlineStepName(.request), "신청")
        XCTAssertEqual(l.onlineStepName(.accept), "수락")
        XCTAssertEqual(l.onlineStepName(.confirm), "최종 확인")
        XCTAssertEqual(l.onlineStepName(.ready), "전투 준비")
        XCTAssertEqual(l.onlineRoomGuide(.init(step: .accept, turn: .theirs, localReady: false), opponent: "연습친구"), "연습친구님의 수락을 기다려요")
        XCTAssertEqual(l.onlineRoomGuide(.init(step: .confirm, turn: .mine, localReady: false), opponent: "연습친구"), "내 차례: 최종 확인을 눌러 주세요")
        XCTAssertEqual(l.onlineActionBlock(.noOpponent), "상대를 선택하세요")
        XCTAssertEqual(l.onlineActionBlock(.noEntry), "출전 포켓몬을 고르세요")
        XCTAssertEqual(l.onlineActionBlock(.fainted), "기절한 포켓몬은 회복이 필요해요")
        XCTAssertEqual(l.onlineActionBlock(.connecting), "서버에 연결하는 중…")
        XCTAssertEqual(l.onlineOwnReady, "내 준비 완료 · 상대 대기 중")
        XCTAssertTrue(l.onlineRequestSent(opponent: "연습친구").contains("연습친구"))
        XCTAssertTrue(l.onlineRequestSent(opponent: "연습친구").contains("신청을 보냈어요"))
        XCTAssertTrue(l.onlineOpponentOffline("연습친구").contains("연습친구"))
        XCTAssertTrue(l.onlineOpponentOffline("연습친구").contains("앱을 열 때 알려져요"))
    }
    func testEveryGuideLineHasBothLanguagesNamesTheOpponentAndNeverPromisesDelivery() {
        let progresses: [OnlineRoomProgress] = [
            .init(step: .accept, turn: .theirs, localReady: false), .init(step: .accept, turn: .mine, localReady: false),
            .init(step: .confirm, turn: .theirs, localReady: false), .init(step: .confirm, turn: .mine, localReady: false),
            .init(step: .ready, turn: .mine, localReady: false), .init(step: .ready, turn: .theirs, localReady: true),
            .init(step: .ready, turn: .none, localReady: true)]
        var seen = Set<String>()
        for l in [L(.ko), L(.en)] {
            for progress in progresses {
                let text = l.onlineRoomGuide(progress, opponent: "Nara")
                XCTAssertFalse(text.isEmpty, "\(progress)")
                XCTAssertTrue(seen.insert(l.lang == .ko ? "ko" + text : "en" + text).inserted, "Guide lines must be distinct: \(text)")
                if progress.turn == .theirs || progress.step == .accept {
                    XCTAssertTrue(text.contains("Nara"), "\(text)")
                }
                for promise in ["보고 있", "확인했", "받았어요", "seen", "received", "is looking", "will see"] {
                    XCTAssertFalse(text.contains(promise), "\(text) promises delivery")
                }
            }
            for block in [OnlineActionBlock.busy, .noOpponent, .noEntry, .fainted, .held, .entryUnavailable, .connecting] {
                XCTAssertFalse(l.onlineActionBlock(block).isEmpty, "\(block)")
            }
            XCTAssertFalse(l.onlineOwnReady.isEmpty)
            XCTAssertFalse(l.onlineOpponentOffline("Nara").isEmpty)
            XCTAssertTrue(l.onlineRequestSent(opponent: "Nara").contains("Nara"))
            for step in OnlineRoomStep.allCases { XCTAssertFalse(l.onlineStepName(step).isEmpty) }
        }
        XCTAssertEqual(Set(OnlineActionBlock.allKnown.map { L(.ko).onlineActionBlock($0) }).count, OnlineActionBlock.allKnown.count)
    }
    func testMissingNicknameFallsBackToTheSharedAnonymousWord() {
        let l = L(.ko)
        XCTAssertTrue(l.onlineRoomGuide(.init(step: .accept, turn: .theirs, localReady: false), opponent: nil).contains(l.onlineAnonymous))
        XCTAssertTrue(l.onlineRequestSent(opponent: nil).contains(l.onlineAnonymous))
    }
    func testRequestAgeWordingStepsFromJustNowToMinutesAndHours() {
        let l = L(.ko)
        let texts = [0, 30, 90, 180, 3_600, 7_500].map { l.onlineRequestAge(seconds: $0) }
        XCTAssertTrue(texts.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(texts[0], texts[1], "Under a minute reads the same")
        XCTAssertTrue(texts[2].contains("1분"), texts[2])
        XCTAssertTrue(texts[3].contains("3분"), texts[3])
        XCTAssertTrue(texts[4].contains("1시간"), texts[4])
        XCTAssertTrue(texts[5].contains("2시간"), texts[5])
        XCTAssertNotEqual(texts[1], texts[2])
    }
}

private extension OnlineActionBlock {
    static let allKnown: [OnlineActionBlock] = [.busy, .noOpponent, .noEntry, .fainted, .held, .entryUnavailable, .connecting]
}
