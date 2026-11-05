import XCTest
@testable import PokeTokenBar

/// T07: why a challenge ended, who gets which way out, when it expires, and a notice that can be
/// closed. Synthetic data only.
@MainActor
final class OnlineBattleEndedNoticeTests: XCTestCase {
    private typealias Fixture = OnlineBattleScreenRenderingTests

    static func room(_ state: OnlineBattleState, confirmed: Bool = false, expiresAt: Double = 1_793_769_900_000, createdAt: Double? = nil) -> OnlineBattleView {
        let base = Fixture.room(state: state, confirmed: confirmed)
        return .init(battleId: base.battleId, state: base.state, revision: base.revision, mode: base.mode, p1: base.p1, p2: base.p2,
                     createdAt: createdAt ?? base.createdAt, expiresAt: expiresAt, startedAt: base.startedAt, reportedAt: base.reportedAt,
                     confirmed: base.confirmed, config: base.config, roundSeq: base.roundSeq, deadline: base.deadline,
                     ownChoice: base.ownChoice, journal: base.journal, result: base.result, reason: base.reason, rematchOf: base.rematchOf)
    }
    private func model(side: OnlineBattleSide, state: OnlineBattleState, confirmed: Bool = false) -> OnlineBattlePresentation {
        let model = Fixture.model(); model.phase = .room; model.localSide = side; model.canStart = true
        if side == .p2 {
            model.members.append(.init(trainerId: "synthetic-me", displayEmail: "나래", role: .member, status: .active, joinedAt: 0, online: true))
        }
        model.room = Self.room(state, confirmed: confirmed)
        return model
    }

    // MARK: Ways out

    func testOnlyTheChallengerSeesCancelRequestWhilePending() {
        XCTAssertEqual(model(side: .p1, state: .pending).roomExits, [.cancelRequest])
        XCTAssertEqual(model(side: .p2, state: .pending).roomExits, [.decline],
                       "The receiver did not make the request; their way out is decline, not cancel")
    }
    func testReceiverKeepsAWayOutAfterAcceptingBecauseTheServerOnlyAllowsDeclineWhilePending() {
        for (state, confirmed) in [(OnlineBattleState.accepted, false), (.accepted, true), (.ready, true)] {
            XCTAssertEqual(model(side: .p2, state: state, confirmed: confirmed).roomExits, [.cancelBattle], "\(state)")
            XCTAssertEqual(model(side: .p1, state: state, confirmed: confirmed).roomExits, [.cancelRequest], "\(state)")
        }
    }
    func testNoWayOutOnceTheMatchStartedOrEnded() {
        for state in [OnlineBattleState.running, .reported, .completed, .declined, .cancelled, .expired, .void] {
            XCTAssertEqual(model(side: .p1, state: state).roomExits, [], "\(state)")
            XCTAssertEqual(model(side: .p2, state: state).roomExits, [], "\(state)")
        }
        XCTAssertEqual(OnlineBattlePresentation().roomExits, [])
    }
    func testWayOutLabelsAreDistinctAndTheReceiverNeverReadsCancelRequest() {
        let l = L(.ko)
        XCTAssertEqual(l.onlineCancel, "신청 취소")
        XCTAssertEqual(l.onlineCancelBattle, "대결 취소")
        XCTAssertNotEqual(l.onlineCancelBattle, l.onlineCancel)
        XCTAssertFalse(L(.en).onlineCancelBattle.isEmpty)
        XCTAssertNotEqual(L(.en).onlineCancelBattle, L(.en).onlineCancel)
    }

    // MARK: Expiry

    func testRequestRemainingFollowsTheServerExpiryOnlyBeforeTheMatch() {
        let pending = model(side: .p1, state: .pending)
        XCTAssertEqual(pending.requestRemaining(now: Date(timeIntervalSince1970: 1_793_683_500)) ?? -1, 86_400, accuracy: 0.5)
        XCTAssertEqual(pending.requestRemaining(now: Date(timeIntervalSince1970: 1_793_769_960)) ?? -1, -60, accuracy: 0.5,
                       "Past the expiry while the server has not yet marked it EXPIRED")
        for state in [OnlineBattleState.accepted, .ready] {
            XCTAssertNotNil(model(side: .p2, state: state, confirmed: true).requestRemaining(now: .now), "\(state)")
        }
        for state in [OnlineBattleState.running, .completed, .cancelled, .expired] {
            XCTAssertNil(model(side: .p1, state: state).requestRemaining(now: .now), "\(state)")
        }
        XCTAssertNil(OnlineBattlePresentation().requestRemaining(now: .now))
    }
    func testExpiryWordingGivesClockTimeAndRemainingTimeInKoreanAndEnglish() throws {
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let at = Date(timeIntervalSince1970: 1_793_769_900)
        let ko = L(.ko), en = L(.en)
        for (seconds, koPart, enPart) in [(86_400.0, "24시간", "24 h"), (5_400, "1시간", "1 h"), (1_500, "25분", "25 min")] {
            let text = ko.onlineRequestExpiry(remaining: seconds, expiresAt: at, timeZone: utc)
            XCTAssertTrue(text.contains(koPart), text)
            XCTAssertTrue(text.contains("11월 4일 05:25"), text)
            XCTAssertTrue(text.contains("만료"), text)
            let english = en.onlineRequestExpiry(remaining: seconds, expiresAt: at, timeZone: utc)
            XCTAssertTrue(english.contains(enPart), english)
            XCTAssertTrue(english.contains("Nov 4, 05:25"), english)
            XCTAssertNil(english.range(of: "[가-힣]", options: .regularExpression), english)
        }
        XCTAssertTrue(ko.onlineRequestExpiry(remaining: 30, expiresAt: at, timeZone: utc).contains("곧"))
        XCTAssertTrue(ko.onlineRequestExpiry(remaining: -5, expiresAt: at, timeZone: utc).contains("지났"))
        XCTAssertFalse(en.onlineRequestExpiry(remaining: -5, expiresAt: at, timeZone: utc).isEmpty)
    }
    func testWaitingCopyDoesNotPromiseThatTheOpponentSawTheRequest() {
        for l in [L(.ko), L(.en)] {
            let text = l.onlineAwaitingResponse(opponent: "하늘")
            XCTAssertTrue(text.contains("하늘"), text)
            for promise in ["받았어요", "확인했어요", "알려져요", "전달", "도착", "received", "delivered", "has seen", "notified"] {
                XCTAssertFalse(text.contains(promise), "\(promise) in \(text)")
            }
        }
        XCTAssertTrue(L(.ko).onlineAwaitingResponse(opponent: "하늘").contains("응답을 기다리는 중"))
        XCTAssertNil(L(.en).onlineAwaitingResponse(opponent: "Sky").range(of: "[가-힣]", options: .regularExpression))
    }

    // MARK: Ended notice text

    func testEachEndingHasItsOwnNamedSentenceInBothLanguages() {
        let ko = L(.ko), en = L(.en)
        var seen = Set<String>()
        for (state, koPart, enPart) in [(OnlineBattleState.declined, "거절", "declined"), (.cancelled, "취소", "cancelled"), (.expired, "시간이 지났", "timed out")] {
            let korean = ko.onlineEndedNotice(state, opponent: "하늘", reason: nil)
            XCTAssertTrue(korean?.contains("하늘") == true && korean?.contains(koPart) == true, "\(state) \(korean ?? "<nil>")")
            let english = en.onlineEndedNotice(state, opponent: "Sky", reason: nil)
            XCTAssertTrue(english?.contains("Sky") == true && english?.contains(enPart) == true, "\(state) \(english ?? "<nil>")")
            XCTAssertNil(english?.range(of: "[가-힣]", options: .regularExpression))
            seen.insert(korean ?? "")
        }
        XCTAssertEqual(seen.count, 3)
        XCTAssertTrue(ko.onlineEndedNotice(.cancelled, opponent: "하늘", reason: "participant_left")?.contains("떠나") == true,
                      "A cancel caused by leaving the group must not read as the opponent cancelling")
        XCTAssertNil(ko.onlineEndedNotice(.running, opponent: "하늘", reason: nil))
        XCTAssertNil(ko.onlineEndedNotice(.completed, opponent: "하늘", reason: nil))
        XCTAssertTrue(ko.onlineEndedNotice(.declined, opponent: nil, reason: nil)?.contains(ko.onlineAnonymous) == true)
    }

    // MARK: Waiting screens and the notice banner

    func testVerifyingScreenSaysItUpdatesByItself() {
        XCTAssertTrue(L(.ko).onlineVerifyingAuto.contains("자동으로 갱신"))
        XCTAssertTrue(L(.ko).onlineVerifyingAuto.contains("수 초"))
        XCTAssertTrue(L(.en).onlineVerifyingAuto.contains("automatically"))
        XCTAssertFalse(L(.ko).onlineDismissNotice.isEmpty)
    }
    func testDismissNoticeClearsItWithoutReachingTheSession() {
        let model = OnlineBattlePresentation()
        var forwarded = 0
        model.onAction = { _ in forwarded += 1 }
        model.notice = "x"; model.stickyNotice = "x"
        XCTAssertTrue(model.noticeSurvivesRefresh)
        model.send(.dismissNotice)
        XCTAssertNil(model.notice)
        XCTAssertFalse(model.noticeSurvivesRefresh)
        XCTAssertEqual(forwarded, 0)
    }
    func testAnnounceEndedNamesTheOpponentOnceAndOnlyForAnEndingSeenLive() {
        let l = L(.ko)
        let model = Fixture.model(); model.phase = .lobby
        let declined = Self.room(.declined)
        model.announceEnded(declined, previous: .running, l: l)
        XCTAssertNil(model.notice, "A running match that ends is not a challenge ending")
        model.announceEnded(declined, previous: nil, l: l)
        XCTAssertNil(model.notice, "An ending first seen while loading history is not news")
        model.announceEnded(declined, previous: .pending, l: l)
        XCTAssertTrue(model.notice?.contains("연습친구") == true && model.notice?.contains("거절") == true, model.notice ?? "<nil>")
        XCTAssertTrue(model.noticeSurvivesRefresh)
        model.send(.dismissNotice)
        model.announceEnded(declined, previous: .pending, l: l)
        XCTAssertNil(model.notice, "Announced once per battle")
        let other = Fixture.model(); other.suppressEndedNotice(for: declined.battleId)
        other.announceEnded(declined, previous: .pending, l: l)
        XCTAssertNil(other.notice, "My own cancel or decline must not be announced back to me")
    }
}
