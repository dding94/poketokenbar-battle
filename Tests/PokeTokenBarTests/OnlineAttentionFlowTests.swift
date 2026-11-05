import UserNotifications
import XCTest
@testable import PokeTokenBar

/// The decisions behind the reported holes: what the in-popover banner shows, where an opening lands, what macOS may
/// present while the app is active, and the home line for someone waiting. Pure inputs, no AppKit, no network.
@MainActor
final class OnlineAttentionFlowTests: XCTestCase {
    private static let now = Date(timeIntervalSince1970: 1_793_683_600)
    private static var nowMS: Double { now.timeIntervalSince1970 * 1000 }
    private static let foeName = "연습친구"

    private func room(_ id: String, _ state: OnlineBattleState, mine: OnlineBattleSide = .p2, confirmed: Bool = false,
                      deadlineIn seconds: Double? = nil, ownChoice: String? = nil, round: Int = 1, createdAt: Double = 1,
                      expiresIn: Double = 3_600, rematchOf: String? = nil, reason: String? = nil) -> OnlineBattleView {
        let local = OnlineBattlePlayer(trainerId: "synthetic-me", snapshot: nil, publicInfo: nil, hpPercent: nil)
        let remote = OnlineBattlePlayer(trainerId: "synthetic-foe", snapshot: nil, publicInfo: nil, hpPercent: nil)
        return .init(battleId: id, state: state, revision: 1, mode: .manual, p1: mine == .p1 ? local : remote, p2: mine == .p1 ? remote : local,
                     createdAt: createdAt, expiresAt: Self.nowMS + expiresIn * 1000, startedAt: nil, reportedAt: nil, confirmed: confirmed,
                     config: nil, roundSeq: round, deadline: seconds.map { Self.nowMS + $0 * 1000 }, ownChoice: ownChoice,
                     journal: [], result: nil, reason: reason, rematchOf: rematchOf)
    }
    private func model(_ battles: [OnlineBattleView], phase: OnlineBattlePresentation.Phase = .lobby, displayed: OnlineBattleView? = nil,
                       result: Bool = false) -> OnlineBattlePresentation {
        let model = OnlineBattlePresentation()
        model.account = .init(trainer: .init(trainerId: "synthetic-me", displayEmail: "나래", role: .member, status: .active),
                              group: .init(groupId: "synthetic-group", name: "동료들", hostTrainerId: "synthetic-foe"))
        model.members = [.init(trainerId: "synthetic-foe", displayEmail: Self.foeName, role: .host, status: .active, joinedAt: 0, online: true)]
        model.battles = battles; model.phase = phase; model.room = displayed
        model.connectionStatus = .connection(.connected)
        if result { model.result = .init(kind: .win, effects: .init(instanceID: "synthetic-pikachu", xp: 10, hpShare: 1)) }
        return model
    }
    private func input(_ model: OnlineBattlePresentation, screen: Bool = false, noChoice: Set<String> = []) -> OnlineAttentionInput {
        OnlineAttentionSource(presentation: model, noChoiceBattleIDs: { noChoice }).input(now: Self.now, onlineScreenShowing: screen)
    }
    private func banner(_ model: OnlineBattlePresentation, screen: Bool) -> OnlineAttention? {
        OnlineAttentionCalculator.banner(input(model, screen: screen))
    }
    private func route(_ model: OnlineBattlePresentation) -> OnlineOpenRoute? { OnlinePopoverPinning.openRoute(input(model)) }

    // MARK: 1. macOS shows nothing for an active app unless it is told to

    /// Closing a pinned popover with X or Esc leaves the app active, and an active app without this answer gets no banner.
    func testTheAppDelegateAnswersWhatToShowWhileActive() {
        XCTAssertTrue(AppDelegate.instancesRespond(to: #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:willPresent:withCompletionHandler:))))
    }

    func testAClosedPopoverOnAnActiveAppStillGetsTheBanner() {
        XCTAssertEqual(OnlineNotificationForeground.options(battleId: "bt-1", attentionInFront: false), [.banner, .sound])
    }

    func testAPopoverOpenedAfterTheAddDoesNotDoubleTheBanner() {
        XCTAssertEqual(OnlineNotificationForeground.options(battleId: "bt-1", attentionInFront: true), [])
    }

    func testUsageAndCompanionAlertsAreShownWhateverThePopoverDoes() {
        for inFront in [false, true] {
            XCTAssertEqual(OnlineNotificationForeground.options(battleId: nil, attentionInFront: inFront), [.banner, .sound])
        }
    }

    // MARK: 2. the banner, on any screen

    func testAnEventOffTheOnlineScreenShowsTheBanner() {
        // Home, the shop tab, Settings and the recap all look like this: the online screen is not showing.
        let model = model([room("bt-in", .pending)])
        XCTAssertEqual(banner(model, screen: false)?.kind, .incomingChallenge)
    }

    func testARematchWhileTheOldResultIsOpenIsAskedOnTheResultNotTwice() {
        let old = room("bt-old", .completed)
        let model = model([old, room("bt-new", .pending, createdAt: 2, rematchOf: "bt-old")], phase: .result, displayed: old, result: true)
        XCTAssertNil(banner(model, screen: true), "the result carries accept and later itself")
        XCTAssertEqual(banner(model, screen: false)?.battleId, "bt-new", "anywhere else in the popover the bar still says it")
        model.showsHistory = true
        XCTAssertEqual(banner(model, screen: true)?.battleId, "bt-new", "something covering the result brings the bar back")
    }

    func testAnEventInAnotherRoomShowsTheBanner() {
        let shown = room("bt-a", .pending)
        let model = model([shown, room("bt-b", .pending, createdAt: 2)], phase: .room, displayed: shown)
        XCTAssertEqual(banner(model, screen: true)?.battleId, "bt-b", "The room on screen is passed over, not the whole banner")
    }

    func testTheRoomAlreadyOnTheOnlineScreenGetsNoBanner() {
        let shown = room("bt-a", .pending)
        XCTAssertNil(banner(model([shown], phase: .room, displayed: shown), screen: true))
        let turn = room("bt-t", .running, confirmed: true, deadlineIn: 20)
        XCTAssertNil(banner(model([turn], phase: .arena, displayed: turn), screen: true))
    }

    func testAnOverlayCoversTheRoomSoTheBannerStays() {
        let shown = room("bt-a", .pending)
        let covers: [(OnlineBattlePresentation) -> Void] = [{ $0.showsHistory = true }, { $0.showsStandings = true }, { $0.rematchSourceID = "bt-old" }, { $0.recoveryCode = "one-time-code" }]
        for cover in covers {
            let model = model([shown], phase: .room, displayed: shown)
            cover(model)
            XCTAssertEqual(banner(model, screen: true)?.battleId, "bt-a")
        }
    }

    func testTheSameRoomOffTheOnlineScreenShowsTheBanner() {
        let shown = room("bt-a", .pending)
        XCTAssertEqual(banner(model([shown], phase: .room, displayed: shown), screen: false)?.battleId, "bt-a")
    }

    func testNothingToSayMeansNoBanner() {
        XCTAssertNil(banner(model([]), screen: false))
        XCTAssertNil(banner(model([room("bt-out", .pending, mine: .p1)]), screen: false), "Waiting is not an event")
    }

    func testAnEndedRequestShowsOnTheBannerUntilTheLobbyOrThePersonTakesIt() {
        let ended = model([room("bt-out", .declined, mine: .p1)])
        ended.unreadEndedBattleIDs = ["bt-out"]
        let attention = banner(ended, screen: false)
        XCTAssertEqual(attention?.kind, .requestEnded)
        XCTAssertEqual(attention?.ending?.state, .declined)
        XCTAssertNil(banner(ended, screen: true), "The lobby says it as its own notice")
        ended.showsHistory = true
        XCTAssertNotNil(banner(ended, screen: true), "History covers that notice")
    }

    func testTheBannerWordsAnEndedRequestLikeTheLobbyNotice() throws {
        let ended = model([room("bt-out", .expired, mine: .p1)])
        ended.unreadEndedBattleIDs = ["bt-out"]
        for l in [L(.ko), L(.en)] {
            let attention = try XCTUnwrap(OnlineAttentionCalculator.current(input(ended)))
            XCTAssertEqual(l.onlineAttentionCopy(attention, now: Self.now).banner, l.onlineEndedNotice(.expired, opponent: Self.foeName, reason: nil))
        }
    }

    // MARK: 3. where an opening lands

    func testAnUnansweredRequestRoutesToItsRoom() {
        XCTAssertEqual(route(model([room("bt-in", .pending)])), .init(battleId: "bt-in"))
        let shown = room("bt-in", .pending)
        XCTAssertEqual(route(model([shown], phase: .room, displayed: shown)), .init(battleId: "bt-in"), "phase room used to land on Home")
    }

    func testAFinalConfirmationRoutesToItsRoom() {
        let accepted = room("bt-c", .accepted, mine: .p1)
        XCTAssertEqual(route(model([accepted], phase: .room, displayed: accepted)), .init(battleId: "bt-c"))
    }

    func testARematchOutranksAnOldResultStillOnScreen() {
        let old = room("bt-old", .completed)
        let rematch = room("bt-new", .pending, createdAt: 2, rematchOf: "bt-old")
        XCTAssertEqual(route(model([old, rematch], phase: .result, displayed: old, result: true)), .init(battleId: "bt-new"))
    }

    func testAMatchThatStartedAfterGoingBackToTheGroupRoutesBack() {
        // phase is lobby and no room is displayed: the mark says "your turn" and the old rule stayed on Home.
        let turn = room("bt-t", .running, confirmed: true, deadlineIn: 20)
        XCTAssertEqual(route(model([turn], phase: .lobby)), .init(battleId: "bt-t"))
    }

    func testAResultNobodyClosedRoutesBackToIt() {
        let done = room("bt-d", .completed)
        XCTAssertEqual(route(model([done], phase: .result, displayed: done, result: true)), .init(battleId: "bt-d"))
    }

    func testAMatchInPlayKeepsTheOpeningOverALesserEvent() {
        // Move already chosen, a challenge arrives elsewhere: stay with the match, the banner carries the challenge.
        let match = room("bt-m", .running, confirmed: true, deadlineIn: 20, ownChoice: "move 1")
        let other = room("bt-in", .pending, createdAt: 2)
        let model = model([match, other], phase: .arena, displayed: match)
        XCTAssertEqual(route(model), .init(battleId: "bt-m"))
        XCTAssertEqual(banner(model, screen: true)?.battleId, "bt-in")
    }

    func testMyTurnElsewhereOutranksTheMatchOnScreen() {
        let shown = room("bt-m", .running, confirmed: true, deadlineIn: 20, ownChoice: "move 1")
        let turn = room("bt-t", .running, confirmed: true, deadlineIn: 20, createdAt: 2)
        XCTAssertEqual(route(model([shown, turn], phase: .arena, displayed: shown)), .init(battleId: "bt-t"))
    }

    func testAWaitingRoomWithNothingToAnswerStaysHome() {
        let waiting = room("bt-out", .pending, mine: .p1)
        XCTAssertNil(route(model([waiting], phase: .room, displayed: waiting)))
        XCTAssertNil(route(model([], phase: .setup)))
    }

    func testAnEndedRequestRoutesToItsNotice() {
        let ended = model([room("bt-out", .declined, mine: .p1)])
        ended.unreadEndedBattleIDs = ["bt-out"]
        XCTAssertEqual(route(ended), .init(battleId: "bt-out"))
    }

    func testTheHomeRowUsesTheSameRouteAsOpening() {
        let source = OnlineAttentionSource(presentation: model([room("bt-in", .pending)]))
        XCTAssertEqual(source.openRoute(now: Self.now), .init(battleId: "bt-in"))
        var followed: [String] = []
        source.presentation.onAction = { action in if case .followAttention(let id) = action { followed.append(id) } }
        let navigation = PopoverNavigation()
        navigation.openOnlineEvent(source.openRoute(now: Self.now)?.battleId, model: source.presentation, l: L(.ko))
        XCTAssertEqual(followed, ["bt-in"])
        XCTAssertTrue(navigation.showingOnlineBattle)
    }

    // MARK: 5. the recovery code

    func testAWaitingRecoveryCodeOwnsTheOpeningAndKeepsTheSelectedRoom() {
        let waiting = model([room("bt-in", .pending)])
        waiting.recoveryCode = "one-time-code"
        XCTAssertEqual(route(waiting), .init(battleId: nil), "Even an event waits: the code cannot be read again")
    }

    func testTheHomeRowSaysARecoveryCodeIsWaiting() {
        let waiting = model([])
        waiting.recoveryCode = "one-time-code"
        for l in [L(.ko), L(.en)] {
            let line = l.onlineHomeSubtitle(input(waiting), connection: .connected)
            XCTAssertNotEqual(line, l.onlineHomeSubtitle(input(model([])), connection: .connected))
            XCTAssertFalse(line.contains("one-time-code"))
        }
    }

    // MARK: 6. the person waiting

    func testTheHomeRowSaysARequestIsWaitingWithoutLightingTheMark() {
        let waiting = input(model([room("bt-out", .pending, mine: .p1)]))
        for l in [L(.ko), L(.en)] {
            let line = l.onlineHomeSubtitle(waiting, connection: .connected)
            XCTAssertTrue(line.contains(Self.foeName), line)
            XCTAssertNil(l.onlineMenuMark(waiting))
            XCTAssertNotEqual(line, l.onlineHomeSubtitle(input(model([])), connection: .connected))
        }
    }

    func testEveryKindOfWaitReadsAsWaiting() {
        let quiet = L(.ko).onlineHomeSubtitle(input(model([])), connection: .connected)
        for waiting in [room("bt-1", .accepted, mine: .p2), room("bt-2", .accepted, mine: .p2, confirmed: false)] {
            XCTAssertNotEqual(L(.ko).onlineHomeSubtitle(input(model([waiting])), connection: .connected), quiet)
        }
        let two = input(model([room("bt-1", .pending, mine: .p1), room("bt-2", .pending, mine: .p1, createdAt: 2)]))
        XCTAssertTrue(L(.ko).onlineHomeSubtitle(two, connection: .connected).contains("2"))
    }

    func testAWaitPastItsExpiryIsNotClaimed() {
        let past = input(model([room("bt-out", .pending, mine: .p1, expiresIn: -60)]))
        let quiet = L(.ko).onlineHomeSubtitle(input(model([])), connection: .connected)
        XCTAssertEqual(L(.ko).onlineHomeSubtitle(past, connection: .connected), quiet)
    }

    func testAnEventOutranksTheWaitOnTheHomeRow() {
        let both = input(model([room("bt-out", .pending, mine: .p1), room("bt-in", .pending, createdAt: 2)]))
        XCTAssertEqual(L(.ko).onlineHomeSubtitle(both, connection: .connected), "받은 신청 1건")
    }

    func testAnUnreadEndingLightsTheMarkAndTheHomeRowThenClears() {
        let ended = model([room("bt-out", .declined, mine: .p1)])
        XCTAssertNil(L(.ko).onlineMenuMark(input(ended)), "Old history alone stays dark")
        ended.unreadEndedBattleIDs = ["bt-out"]
        XCTAssertEqual(L(.ko).onlineMenuMark(input(ended))?.text, OnlineMenuMark.attentionDot)
        XCTAssertTrue(L(.ko).onlineHomeSubtitle(input(ended), connection: .connected).contains("거절"))
        ended.acknowledgeEnded("bt-out", l: L(.ko))
        XCTAssertNil(L(.ko).onlineMenuMark(input(ended)))
    }

    func testAnEndedRequestOutranksOnlyTheOutcomeKinds() {
        let ended = room("bt-out", .declined, mine: .p1)
        let incoming = model([ended, room("bt-in", .pending, createdAt: 2)])
        incoming.unreadEndedBattleIDs = ["bt-out"]
        XCTAssertEqual(OnlineAttentionCalculator.current(input(incoming))?.kind, .incomingChallenge)
        let done = room("bt-d", .completed)
        let result = model([ended, done], phase: .result, displayed: done, result: true)
        result.unreadEndedBattleIDs = ["bt-out"]
        XCTAssertEqual(OnlineAttentionCalculator.current(input(result))?.kind, .requestEnded)
        let reported = room("bt-r", .reported)
        let verifying = model([ended, reported], phase: .verifying, displayed: reported)
        verifying.unreadEndedBattleIDs = ["bt-out"]
        XCTAssertEqual(OnlineAttentionCalculator.active(input(verifying)).map(\.kind), [.requestEnded, .matchEnded])
    }

    /// A member who left has no display name, and that is exactly the case where the server cancels their rooms.
    func testAnEndingFromSomeoneWhoLeftIsToldWithoutTheirName() throws {
        let left = model([room("bt-out", .cancelled, mine: .p1, reason: "participant_left")])
        left.members = [.init(trainerId: "synthetic-foe", displayEmail: nil, role: .member, status: .left, joinedAt: 0, online: false)]
        left.unreadEndedBattleIDs = ["bt-out"]
        let notice = try XCTUnwrap(OnlineAttentionCalculator.evaluate(input(left), seen: .init()).notices.first)
        for l in [L(.ko), L(.en)] {
            let body = l.onlineAttentionNotificationCopy(notice, now: Self.now).body
            XCTAssertTrue(body.contains(l.onlineAnonymous), body)
            XCTAssertEqual(body, l.onlineAttentionCopy(notice.attention, now: Self.now).tooltip)
        }
    }

    func testAReadEndingShowsItsNoticeOnceAfterARelaunch() {
        // After a relaunch the session has no previous state, so the lobby would otherwise say nothing.
        let ended = model([room("bt-out", .declined, mine: .p1)])
        ended.syncEnded(unread: ["bt-out"], read: [], l: L(.ko))
        XCTAssertEqual(ended.unreadEndedBattleIDs, ["bt-out"])
        XCTAssertNil(ended.notice)
        ended.acknowledgeEnded("bt-out", l: L(.ko))
        XCTAssertEqual(ended.notice, L(.ko).onlineEndedNotice(.declined, opponent: Self.foeName, reason: nil))
        ended.send(.dismissNotice)
        ended.acknowledgeEnded("bt-out", l: L(.ko))
        XCTAssertNil(ended.notice, "Closed once, it stays closed")
    }

    func testAnEndingAnnouncedLiveDoesNotRepeatItsNotice() {
        let pending = room("bt-out", .pending, mine: .p1)
        let ended = room("bt-out", .declined, mine: .p1)
        let model = model([ended])
        model.announceEnded(ended, previous: pending.state, l: L(.ko))
        model.send(.dismissNotice)
        model.syncEnded(unread: [], read: ["bt-out"], l: L(.ko))
        XCTAssertNil(model.notice)
        XCTAssertTrue(model.acknowledgedEndedBattleIDs.contains("bt-out"))
    }

    func testClosingAnEndedBannerClearsItAndItsPendingNoticeWithoutTheSession() {
        let pending = room("bt-out", .pending, mine: .p1)
        let ended = room("bt-out", .declined, mine: .p1)
        let model = model([ended])
        var reachedSession = false
        model.onAction = { _ in reachedSession = true }
        model.announceEnded(ended, previous: pending.state, l: L(.ko))
        model.syncEnded(unread: ["bt-out"], read: [], l: L(.ko))
        model.send(.dismissEnded("bt-out"))
        XCTAssertEqual(model.unreadEndedBattleIDs, [])
        XCTAssertTrue(model.acknowledgedEndedBattleIDs.contains("bt-out"))
        XCTAssertNil(model.notice, "The same words would otherwise wait on the lobby")
        XCTAssertFalse(reachedSession)
    }

    func testClosingAnEndedBannerLeavesAnotherRoomsNoticeAlone() {
        let ended = room("bt-out", .declined, mine: .p1)
        let model = model([ended])
        model.notice = "다른 오류"
        model.send(.dismissEnded("bt-out"))
        XCTAssertEqual(model.notice, "다른 오류")
    }

    func testSyncCannotBringBackARoomTheViewAlreadyAcknowledged() {
        let model = model([room("bt-out", .declined, mine: .p1)])
        model.acknowledgeEnded("bt-out", l: L(.ko))
        model.syncEnded(unread: ["bt-out"], read: [], l: L(.ko))
        XCTAssertEqual(model.unreadEndedBattleIDs, [], "A stale notifier pass runs after the click")
    }

    func testAnEventRouteAcknowledgesOnlyAnUnreadEnding() {
        let model = model([room("bt-out", .declined, mine: .p1), room("bt-in", .pending, createdAt: 2)])
        model.unreadEndedBattleIDs = ["bt-out"]
        let navigation = PopoverNavigation()
        navigation.openOnlineEvent("bt-in", model: model, l: L(.ko))
        XCTAssertEqual(model.unreadEndedBattleIDs, ["bt-out"], "Opening another room reads nothing")
        navigation.openOnlineEvent("bt-out", model: model, l: L(.ko))
        XCTAssertEqual(model.unreadEndedBattleIDs, [])
    }

    func testPressingCancelRecordsTheRoomAsMine() {
        let model = model([])
        model.suppressEndedNotice(for: "bt-out")
        XCTAssertTrue(model.ownEndedBattleIDs.contains("bt-out"))
        let announced = room("bt-a", .declined, mine: .p1)
        model.announceEnded(announced, previous: .pending, l: L(.ko))
        XCTAssertFalse(model.ownEndedBattleIDs.contains("bt-a"), "An announced ending is not mine")
    }

    // MARK: 7a. nothing to pick

    func testAForcedTurnAsksForNothing() {
        let forced = room("bt-f", .running, confirmed: true, deadlineIn: 20)
        let forcedModel = model([forced], phase: .arena, displayed: forced)
        XCTAssertEqual(OnlineAttentionCalculator.current(input(forcedModel))?.kind, .myTurn, "Without the fact it reads as a turn")
        let quiet = input(forcedModel, noChoice: ["bt-f"])
        XCTAssertNil(OnlineAttentionCalculator.current(quiet))
        let l = L(.ko)
        XCTAssertEqual(l.onlineMenuMark(quiet)?.tone, .ongoing, "The match is still going on")
        XCTAssertFalse(l.onlineHomeSubtitle(quiet, connection: .connected).contains("기술"))
    }

    func testAnotherBattlesForcedTurnDoesNotHideMine() {
        let turn = room("bt-t", .running, confirmed: true, deadlineIn: 20)
        XCTAssertEqual(OnlineAttentionCalculator.current(input(model([turn]), noChoice: ["bt-other"]))?.battleId, "bt-t")
    }
}
