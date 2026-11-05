import XCTest
@testable import PokeTokenBar

@MainActor
final class OnlineBattleAttentionTests: XCTestCase {
    private static let me = "synthetic-me"
    private static let foe = "synthetic-foe"
    private static let now = Date(timeIntervalSince1970: 1_793_683_600)
    private static var nowMS: Double { now.timeIntervalSince1970 * 1000 }

    private func battle(_ state: OnlineBattleState, mine: OnlineBattleSide = .p2, revision: Int = 1, confirmed: Bool = false, roundSeq: Int = 0,
                        expiresAt: Double? = nil, rematchOf: String? = nil) -> OnlineBattleView {
        battle("bt-1", state, mine: mine, revision: revision, confirmed: confirmed, roundSeq: roundSeq, expiresAt: expiresAt, rematchOf: rematchOf)
    }
    private func battle(_ id: String, _ state: OnlineBattleState, mine: OnlineBattleSide = .p2, mode: OnlineBattleMode = .manual,
                        revision: Int = 1, confirmed: Bool = false, roundSeq: Int = 0, deadline: Double? = nil, ownChoice: String? = nil,
                        expiresAt: Double? = nil, createdAt: Double = 1, rematchOf: String? = nil) -> OnlineBattleView {
        let local = OnlineBattlePlayer(trainerId: Self.me, snapshot: nil, publicInfo: nil, hpPercent: nil)
        let remote = OnlineBattlePlayer(trainerId: Self.foe, snapshot: nil, publicInfo: nil, hpPercent: nil)
        return .init(battleId: id, state: state, revision: revision, mode: mode, p1: mine == .p1 ? local : remote, p2: mine == .p1 ? remote : local,
                     createdAt: createdAt, expiresAt: expiresAt ?? Self.nowMS + 3_600_000, startedAt: nil, reportedAt: nil, confirmed: confirmed,
                     config: nil, roundSeq: roundSeq, deadline: deadline, ownChoice: ownChoice, journal: [], result: nil, reason: nil, rematchOf: rematchOf)
    }
    private func turn(_ id: String = "bt-turn", round: Int = 3, seconds: Double = 20, ownChoice: String? = nil, mode: OnlineBattleMode = .manual) -> OnlineBattleView {
        battle(id, .running, mode: mode, revision: 4, confirmed: true, roundSeq: round, deadline: Self.nowMS + seconds * 1000, ownChoice: ownChoice)
    }
    private func presentation(_ battles: [OnlineBattleView] = []) -> OnlineBattlePresentation {
        let model = OnlineBattlePresentation()
        model.account = .init(trainer: .init(trainerId: Self.me, displayEmail: "나래", role: .member, status: .active),
                              group: .init(groupId: "synthetic-group", name: "동료들", hostTrainerId: Self.foe))
        model.members = [.init(trainerId: Self.foe, displayEmail: "연습친구", role: .host, status: .active, joinedAt: 0, online: true)]
        model.battles = battles
        model.phase = .lobby
        return model
    }
    private func input(_ model: OnlineBattlePresentation, prepared: Set<String> = [], held: Set<String> = [], at now: Date? = nil) -> OnlineAttentionInput {
        .init(presentation: model, preparedBattleIDs: prepared, stagingHeldBattleIDs: held, now: now ?? Self.now)
    }
    private func current(_ model: OnlineBattlePresentation, prepared: Set<String> = [], held: Set<String> = []) -> OnlineAttentionKind? {
        OnlineAttentionCalculator.current(input(model, prepared: prepared, held: held))?.kind
    }
    /// Mirrors what publish() produces for a selected room.
    private func display(_ model: OnlineBattlePresentation, _ room: OnlineBattleView, phase: OnlineBattlePresentation.Phase, result: Bool = false) {
        model.battles = [room]; model.room = room; model.phase = phase
        model.result = result ? .init(title: "승리", detail: "경험치를 얻었어요.", xpAwarded: 10, hpApplied: true, isVoid: false) : nil
    }

    // MARK: Which state is which event

    func testSingleIncomingChallengeIsTheCurrentEvent() {
        let attention = OnlineAttentionCalculator.current(input(presentation([battle(.pending, mine: .p2)])))
        XCTAssertEqual(attention?.kind, .incomingChallenge)
        XCTAssertEqual(attention?.battleId, "bt-1")
        XCTAssertEqual(attention?.opponentName, "연습친구")
    }

    func testNothingToDoIsNil() {
        XCTAssertNil(current(presentation()), "An empty lobby")
        XCTAssertNil(current(presentation([battle(.pending, mine: .p1)])), "My own outgoing request waits on the opponent")
        XCTAssertNil(current(presentation([battle(.accepted, mine: .p2)])), "After accepting, the challenger confirms next")
        for state in [OnlineBattleState.declined, .cancelled, .expired, .completed, .void] {
            XCTAssertNil(current(presentation([battle(state, mine: .p2)])), "\(state) in the list alone asks nothing")
        }
    }

    func testNoAccountMeansNoEvents() {
        let model = presentation([battle(.pending, mine: .p2)])
        model.account = nil
        XCTAssertNil(current(model))
    }

    func testBattleTheLocalTrainerIsNotInIsIgnored() {
        let stranger = OnlineBattlePlayer(trainerId: "synthetic-other", snapshot: nil, publicInfo: nil, hpPercent: nil)
        let source = battle(.pending)
        let foreign = OnlineBattleView(battleId: source.battleId, state: .pending, revision: 1, mode: .manual, p1: source.p1, p2: stranger,
                                       createdAt: 1, expiresAt: source.expiresAt, startedAt: nil, reportedAt: nil, confirmed: false, config: nil,
                                       roundSeq: 0, deadline: nil, ownChoice: nil, journal: [], result: nil, reason: nil, rematchOf: nil)
        XCTAssertNil(current(presentation([foreign])))
    }

    func testChallengeAcceptedAsksOnlyTheChallengerUntilConfirmed() {
        XCTAssertEqual(current(presentation([battle(.accepted, mine: .p1, revision: 2)])), .challengeAccepted)
        XCTAssertNotEqual(current(presentation([battle(.accepted, mine: .p1, revision: 2, confirmed: true)])), .challengeAccepted)
    }

    func testFinalConfirmedAsksBothSidesUntilThisConnectionPrepared() {
        for side in [OnlineBattleSide.p1, .p2] {
            let room = battle(.accepted, mine: side, revision: 2, confirmed: true)
            XCTAssertEqual(current(presentation([room])), .finalConfirmed, "\(side) must still press ready")
            XCTAssertNil(current(presentation([room]), prepared: ["bt-1"]), "\(side) already pressed ready and waits on the opponent")
        }
    }

    func testReadyRoomAsksAgainOnlyWhenThisConnectionHasNotPrepared() {
        // READY after a relaunch needs another press; the prepared entry lives only in memory.
        let room = battle(.ready, mine: .p2, revision: 2, confirmed: true)
        XCTAssertEqual(current(presentation([room])), .finalConfirmed)
        XCTAssertNil(current(presentation([room]), prepared: ["bt-1"]), "Both pressed ready: the app starts on its own")
    }

    func testRematchRequestIsDistinctFromAPlainChallenge() {
        XCTAssertEqual(current(presentation([battle(.pending, mine: .p2, rematchOf: "bt-old")])), .rematchRequested)
        XCTAssertNil(current(presentation([battle(.pending, mine: .p1, rematchOf: "bt-old")])), "My own rematch request waits on the opponent")
    }

    func testMyTurnNeedsAnOpenManualRoundWithoutMyChoice() {
        XCTAssertEqual(current(presentation([turn()])), .myTurn)
        XCTAssertEqual(OnlineAttentionCalculator.current(input(presentation([turn(seconds: 20)])))?.deadline, Self.now.addingTimeInterval(20))
        XCTAssertNil(current(presentation([turn(ownChoice: "move 1")])), "Already chose")
        XCTAssertNil(current(presentation([turn(mode: .auto)])), "Auto battles never ask")
        XCTAssertNil(current(presentation([battle(.running, roundSeq: 3)])), "No open round between the pair release and the next round")
        XCTAssertNil(current(presentation([turn(seconds: -1)])), "A passed deadline cannot be met, so it must not ask")
        XCTAssertNil(current(presentation([turn(seconds: 0)])), "The deadline instant has passed")
    }

    func testOptimisticChoiceOnlySilencesTheDisplayedRoom() {
        let shown = turn("bt-shown"), other = turn("bt-other")
        let model = presentation([shown, other])
        model.room = shown; model.choiceSubmitted = true
        XCTAssertEqual(OnlineAttentionCalculator.current(input(model))?.battleId, "bt-other")
        model.battles = [shown]
        XCTAssertNil(current(model), "Pressed a move and the server has not answered yet")
    }

    func testExpiredPrestartRoomsStopAsking() {
        let passed = Self.nowMS - 1
        XCTAssertNil(current(presentation([battle(.pending, mine: .p2, expiresAt: passed)])))
        XCTAssertNil(current(presentation([battle(.pending, mine: .p2, expiresAt: Self.nowMS)])), "The expiry instant has passed")
        XCTAssertNil(current(presentation([battle(.pending, mine: .p2, expiresAt: passed, rematchOf: "bt-old")])))
        XCTAssertNil(current(presentation([battle(.accepted, mine: .p1, expiresAt: passed)])))
        XCTAssertNil(current(presentation([battle(.accepted, mine: .p2, confirmed: true, expiresAt: passed)])))
    }

    // MARK: Priority

    func testPriorityIsMyTurnThenAcceptedThenIncomingThenTheRest() {
        let room = battle("bt-result", .completed, confirmed: true)
        let model = presentation([])
        display(model, room, phase: .result, result: true)
        model.battles = [
            room,
            battle("bt-rematch", .pending, mine: .p2, rematchOf: "bt-old"),
            battle("bt-final", .accepted, mine: .p2, revision: 2, confirmed: true),
            battle("bt-incoming", .pending, mine: .p2),
            battle("bt-accepted", .accepted, mine: .p1, revision: 2),
            turn()
        ]
        XCTAssertEqual(OnlineAttentionCalculator.active(input(model)).map(\.kind),
                       [.myTurn, .challengeAccepted, .incomingChallenge, .finalConfirmed, .rematchRequested, .resultReady])
        XCTAssertEqual(current(model), .myTurn)
    }

    func testSameKindPicksTheOldestDeterministically() {
        // Challenges share one time-to-live, so the oldest expires first.
        let older = battle("bt-b", .pending, mine: .p2, createdAt: 1), newer = battle("bt-a", .pending, mine: .p2, createdAt: 2)
        let tieA = battle("bt-a", .pending, mine: .p2, createdAt: 1)
        XCTAssertEqual(OnlineAttentionCalculator.current(input(presentation([newer, older])))?.battleId, "bt-b")
        XCTAssertEqual(OnlineAttentionCalculator.current(input(presentation([older, tieA])))?.battleId, "bt-a")
        XCTAssertEqual(OnlineAttentionCalculator.current(input(presentation([tieA, older])))?.battleId, "bt-a")
    }

    // MARK: Seen record

    func testSameOccurrenceTwiceIsNotANewEvent() {
        let model = presentation([battle(.pending, mine: .p2)])
        let first = OnlineAttentionCalculator.evaluate(input(model), seen: .init())
        XCTAssertEqual(first.raised.map(\.kind), [.incomingChallenge])
        XCTAssertEqual(first.notices.map(\.kind), [.incomingChallenge])
        XCTAssertEqual(first.current?.kind, .incomingChallenge)
        let second = OnlineAttentionCalculator.evaluate(input(model), seen: first.seen)
        XCTAssertEqual(second.raised, [])
        XCTAssertEqual(second.notices, [])
        XCTAssertEqual(second.resolved, [])
        XCTAssertEqual(second.current?.kind, .incomingChallenge, "Seen does not hide what still needs attention")
    }

    func testRevisionBumpInTheSameStageIsNotANewEventButIsRecorded() {
        // The challenger may swap their entry while PENDING; the request is still the same one.
        let first = OnlineAttentionCalculator.evaluate(input(presentation([battle(.pending, mine: .p2, revision: 1)])), seen: .init())
        let second = OnlineAttentionCalculator.evaluate(input(presentation([battle(.pending, mine: .p2, revision: 2)])), seen: first.seen)
        XCTAssertEqual(second.raised, [])
        XCTAssertEqual(second.seen.entries.map(\.revision), [2])
    }

    func testEachNewRoundIsANewMyTurn() {
        let first = OnlineAttentionCalculator.evaluate(input(presentation([turn(round: 3)])), seen: .init())
        let same = OnlineAttentionCalculator.evaluate(input(presentation([turn(round: 3)])), seen: first.seen)
        let next = OnlineAttentionCalculator.evaluate(input(presentation([turn(round: 4)])), seen: same.seen)
        XCTAssertEqual(same.raised, [])
        XCTAssertEqual(next.raised.map(\.roundSeq), [4])
        XCTAssertEqual(next.resolved, [first.current?.key].compactMap { $0 })
    }

    func testAnotherBattleIsANewEventForTheSameKind() {
        let first = OnlineAttentionCalculator.evaluate(input(presentation([battle("bt-1", .pending, mine: .p2)])), seen: .init())
        let second = OnlineAttentionCalculator.evaluate(input(presentation([battle("bt-1", .pending, mine: .p2), battle("bt-2", .pending, mine: .p2)])), seen: first.seen)
        XCTAssertEqual(second.raised.map(\.battleId), ["bt-2"])
    }

    func testReleasedStateIsResolvedAndCanFireAgain() throws {
        let room = turn()
        let model = presentation([room])
        let first = OnlineAttentionCalculator.evaluate(input(model), seen: .init())
        let key = try XCTUnwrap(first.current?.key)
        model.room = room; model.choiceSubmitted = true
        let released = OnlineAttentionCalculator.evaluate(input(model), seen: first.seen)
        XCTAssertNil(released.current)
        XCTAssertEqual(released.resolved, [key])
        XCTAssertFalse(released.seen.contains(key))
        // The submit failed, publish cleared the optimistic flag, and the person must choose again.
        model.choiceSubmitted = false
        let again = OnlineAttentionCalculator.evaluate(input(model), seen: released.seen)
        XCTAssertEqual(again.raised.map(\.key), [key])
    }

    func testStageTransitionResolvesThePreviousStage() {
        let first = OnlineAttentionCalculator.evaluate(input(presentation([battle(.pending, mine: .p2)])), seen: .init())
        let next = OnlineAttentionCalculator.evaluate(input(presentation([battle(.accepted, mine: .p2, revision: 2)])), seen: first.seen)
        XCTAssertEqual(next.resolved.map(\.stage), ["incomingChallenge"])
        XCTAssertNil(next.current)
    }

    func testRelaunchWithSavedRecordDoesNotAnnounceAgain() throws {
        let first = OnlineAttentionCalculator.evaluate(input(presentation([turn(round: 3), battle(.pending, mine: .p2)])), seen: .init())
        XCTAssertEqual(first.notices.count, 2)
        let saved = try JSONEncoder().encode(first.seen)
        let restored = try JSONDecoder().decode(OnlineAttentionSeenRecord.self, from: saved)
        XCTAssertEqual(restored, first.seen)
        let relaunched = OnlineAttentionCalculator.evaluate(input(presentation([turn(round: 3), battle(.pending, mine: .p2)])), seen: restored)
        XCTAssertEqual(relaunched.raised, [])
        XCTAssertEqual(relaunched.notices, [])
        XCTAssertEqual(relaunched.active.count, 2)
    }

    func testLaunchBeforeHelloDoesNotForgetTheRecord() {
        // A relaunch publishes with no views, then hello refills them. Absence proves nothing.
        let first = OnlineAttentionCalculator.evaluate(input(presentation([battle(.pending, mine: .p2)])), seen: .init())
        let empty = OnlineAttentionCalculator.evaluate(input(presentation([])), seen: first.seen)
        XCTAssertEqual(empty.seen, first.seen)
        XCTAssertEqual(empty.resolved, [])
        let signedOut = presentation([battle(.declined, mine: .p2)]); signedOut.account = nil
        let noAccount = OnlineAttentionCalculator.evaluate(input(signedOut), seen: first.seen)
        XCTAssertEqual(noAccount.seen, first.seen)
        XCTAssertEqual(noAccount.resolved, [])
        let back = OnlineAttentionCalculator.evaluate(input(presentation([battle(.pending, mine: .p2)])), seen: noAccount.seen)
        XCTAssertEqual(back.raised, [])
    }

    func testWakeReconciliationJumpsToTheNewStageThroughTheSamePath() {
        // Asleep through accept and confirm: the next refresh is one state comparison, not replayed pushes.
        let before = OnlineAttentionCalculator.evaluate(input(presentation([battle(.pending, mine: .p2)])), seen: .init())
        let after = OnlineAttentionCalculator.evaluate(input(presentation([battle(.accepted, mine: .p2, revision: 2, confirmed: true)])), seen: before.seen)
        XCTAssertEqual(after.notices.map(\.kind), [.finalConfirmed])
        XCTAssertEqual(after.resolved.map(\.stage), ["incomingChallenge"])
    }

    func testSeenRecordIsBoundedAndKeepsWhatIsStillActive() {
        var seen = OnlineAttentionSeenRecord()
        let live = battle("bt-live", .pending, mine: .p2, createdAt: 1)
        seen = OnlineAttentionCalculator.evaluate(input(presentation([live])), seen: seen).seen
        // Absent battles stay until eviction; the live key is the oldest entry yet must survive.
        for index in 0..<(OnlineAttentionSeenRecord.capacity + 5) {
            let extra = battle("bt-\(index)", .pending, mine: .p2, createdAt: 2)
            let step = OnlineAttentionCalculator.evaluate(input(presentation([live, extra])), seen: seen)
            XCTAssertEqual(step.raised.map(\.battleId), ["bt-\(index)"])
            seen = step.seen
        }
        XCTAssertEqual(seen.entries.count, OnlineAttentionSeenRecord.capacity)
        XCTAssertTrue(seen.contains(.init(battleId: "bt-live", kind: .incomingChallenge, roundSeq: 0)))
        XCTAssertEqual(OnlineAttentionCalculator.evaluate(input(presentation([live])), seen: seen).raised, [])
    }

    func testNotificationIdentifierIsFixedPerOccurrence() {
        let pending = OnlineAttentionCalculator.current(input(presentation([battle(.pending, mine: .p2, revision: 1, roundSeq: 0)])))
        let bumped = OnlineAttentionCalculator.current(input(presentation([battle(.pending, mine: .p2, revision: 9, roundSeq: 0)])))
        XCTAssertEqual(pending?.key.notificationIdentifier, "online-attention.bt-1.incomingChallenge")
        XCTAssertEqual(pending?.key.notificationIdentifier, bumped?.key.notificationIdentifier)
        XCTAssertEqual(OnlineAttentionCalculator.current(input(presentation([turn(round: 7)])))?.key.notificationIdentifier, "online-attention.bt-turn.myTurn.7")
    }

    // MARK: Notification eligibility

    func testOnlyFourKindsCanBecomeANotification() {
        XCTAssertEqual(Set(OnlineAttentionKind.allCases.compactMap { $0.notifiable?.rawValue }),
                       ["incomingChallenge", "challengeAccepted", "finalConfirmed", "myTurn"])
        XCTAssertEqual(OnlineAttentionKind.allCases.count, 7)
        for kind in OnlineAttentionKind.allCases {
            let attention = OnlineAttention(kind: kind, battleId: "bt", revision: 1, roundSeq: 0, opponentName: nil, deadline: nil)
            XCTAssertEqual(OnlineAttentionNotice(attention)?.attention, kind.notifiable == nil ? nil : attention, "\(kind)")
        }
    }

    func testInAppKindsAreRaisedWithoutANotice() {
        let rematch = OnlineAttentionCalculator.evaluate(input(presentation([battle(.pending, mine: .p2, rematchOf: "bt-old")])), seen: .init())
        XCTAssertEqual(rematch.raised.map(\.kind), [.rematchRequested])
        XCTAssertEqual(rematch.notices, [])
        let model = presentation([])
        display(model, battle(.completed, confirmed: true), phase: .result, result: true)
        let result = OnlineAttentionCalculator.evaluate(input(model), seen: .init())
        XCTAssertEqual(result.raised.map(\.kind), [.resultReady])
        XCTAssertEqual(result.notices, [])
    }

    // MARK: Result gate

    func testResultFollowsTheDisplayGateNotTheRawRoomState() {
        let completed = battle(.completed, confirmed: true)
        let model = presentation([])
        // T13 keeps phase .arena for .reported and .completed while the last beats play.
        display(model, completed, phase: .arena, result: true)
        XCTAssertNil(current(model), "Settled, but the screen has not reached the result")
        display(model, battle(.reported, confirmed: true), phase: .arena)
        XCTAssertNil(current(model))
        display(model, completed, phase: .result, result: true)
        XCTAssertNil(current(model, held: ["bt-1"]), "Staging still holds this battle")
        XCTAssertEqual(current(model, held: ["bt-other"]), .resultReady, "Holding another battle says nothing about this one")
        XCTAssertEqual(current(model), .resultReady)
    }

    func testHeldResultFiresOnceTheGateOpens() {
        let model = presentation([])
        display(model, battle(.completed, confirmed: true), phase: .result, result: true)
        let held = OnlineAttentionCalculator.evaluate(input(model, held: ["bt-1"]), seen: .init())
        XCTAssertEqual(held.raised, [])
        let open = OnlineAttentionCalculator.evaluate(input(model), seen: held.seen)
        XCTAssertEqual(open.raised.map(\.kind), [.resultReady])
    }

    func testArchiveEntriesNeverRaiseAResult() {
        // publish() lists archive summaries in battles, but only live rooms may drive a result.
        let model = presentation([battle("bt-old", .completed, confirmed: true), battle("bt-void", .void)])
        XCTAssertNil(current(model))
        model.room = battle("bt-live", .running, confirmed: true, roundSeq: 1); model.phase = .arena
        model.result = .init(title: "승리", detail: "", xpAwarded: 0, hpApplied: true, isVoid: false)
        XCTAssertNil(current(model), "A running room with a stale result object is not a result")
    }

    func testMatchEndedCoversVerifyingAndUnsettledCompletion() {
        let model = presentation([])
        display(model, battle(.reported, confirmed: true), phase: .verifying)
        XCTAssertEqual(current(model), .matchEnded)
        display(model, battle(.completed, confirmed: true), phase: .result, result: false)
        XCTAssertEqual(current(model), .matchEnded, "Completed but not settled yet")
        display(model, battle(.void), phase: .result, result: true)
        XCTAssertEqual(current(model), .resultReady, "A voided match has a result too")
        display(model, battle(.reported, confirmed: true), phase: .verifying)
        XCTAssertNil(current(model, held: ["bt-1"]))
    }

    func testDismissedResultDoesNotRaiseAgainWhenRedisplayed() {
        let room = battle(.completed, confirmed: true)
        let model = presentation([])
        display(model, room, phase: .result, result: true)
        let first = OnlineAttentionCalculator.evaluate(input(model), seen: .init())
        model.room = nil; model.result = nil; model.phase = .lobby
        let dismissed = OnlineAttentionCalculator.evaluate(input(model), seen: first.seen)
        XCTAssertNil(dismissed.current, "Dismissing clears the mark")
        XCTAssertEqual(dismissed.resolved, [], "Nothing was notified, so nothing to withdraw")
        display(model, room, phase: .result, result: true)
        let shownAgain = OnlineAttentionCalculator.evaluate(input(model), seen: dismissed.seen)
        XCTAssertEqual(shownAgain.current?.kind, .resultReady)
        XCTAssertEqual(shownAgain.raised, [], "Publish may fall back to the newest finished room")
    }

    // MARK: Copy

    private func attention(_ kind: OnlineAttentionKind, name: String? = "연습친구", seconds: Double? = nil) -> OnlineAttention {
        .init(kind: kind, battleId: "bt", revision: 1, roundSeq: 1, opponentName: name, deadline: seconds.map { Self.now.addingTimeInterval($0) })
    }

    func testEveryKindNamesTheOpponentInBothLanguages() {
        for lang in [AppLanguage.ko, .en] {
            let l = L(lang)
            for kind in OnlineAttentionKind.allCases {
                let copy = l.onlineAttentionCopy(attention(kind, seconds: 12), now: Self.now)
                for text in [copy.tooltip, copy.subtitle, copy.banner] {
                    XCTAssertTrue(text.contains("연습친구"), "\(lang) \(kind): \(text)")
                }
                if let notice = OnlineAttentionNotice(attention(kind, seconds: 12)) {
                    let note = l.onlineAttentionNotificationCopy(notice, now: Self.now)
                    XCTAssertFalse(note.title.isEmpty)
                    XCTAssertTrue(note.body.contains("연습친구"), "\(lang) \(kind): \(note.body)")
                }
            }
        }
    }

    func testCopyDiffersPerKindAndPerLanguage() {
        for kind in OnlineAttentionKind.allCases {
            let ko = L(.ko).onlineAttentionCopy(attention(kind, seconds: 12), now: Self.now)
            let en = L(.en).onlineAttentionCopy(attention(kind, seconds: 12), now: Self.now)
            XCTAssertNotEqual(ko.banner, en.banner, "\(kind)")
        }
        let banners = Set(OnlineAttentionKind.allCases.map { L(.ko).onlineAttentionCopy(attention($0, seconds: 12), now: Self.now).banner })
        XCTAssertEqual(banners.count, OnlineAttentionKind.allCases.count)
    }

    func testRequiredKoreanSentences() {
        let l = L(.ko)
        let incoming = l.onlineAttentionNotificationCopy(OnlineAttentionNotice(attention(.incomingChallenge))!, now: Self.now)
        XCTAssertEqual(incoming.body, "연습친구님이 대결을 신청했어요")
        let turn = l.onlineAttentionNotificationCopy(OnlineAttentionNotice(attention(.myTurn, seconds: 30))!, now: Self.now)
        XCTAssertTrue(turn.body.contains("30초 안에 기술을 고르세요"), turn.body)
    }

    func testMyTurnStatesTheTimeLeftRoundedUp() {
        let turn = attention(.myTurn, seconds: 11.2)
        XCTAssertTrue(L(.ko).onlineAttentionCopy(turn, now: Self.now).banner.contains("12초"))
        XCTAssertTrue(L(.en).onlineAttentionNotificationCopy(OnlineAttentionNotice(turn)!, now: Self.now).body.contains("12s"))
        XCTAssertTrue(L(.ko).onlineAttentionCopy(turn, now: Self.now).tooltip.contains("12초"))
    }

    func testUnknownNicknameFallsBackToTheAnonymousLabel() {
        let copy = L(.ko).onlineAttentionCopy(attention(.incomingChallenge, name: nil), now: Self.now)
        XCTAssertTrue(copy.banner.contains(L(.ko).onlineAnonymous), copy.banner)
        // Left members are returned with a nil nickname by the server.
        let model = presentation([battle(.pending, mine: .p2)])
        model.members = [.init(trainerId: Self.foe, displayEmail: nil, role: .member, status: .left, joinedAt: 0, online: false)]
        XCTAssertNil(OnlineAttentionCalculator.current(input(model))?.opponentName)
    }

    func testOtherAppLanguagesUseTheEnglishFallback() {
        let turn = attention(.incomingChallenge)
        XCTAssertEqual(L(.ja).onlineAttentionCopy(turn, now: Self.now), L(.en).onlineAttentionCopy(turn, now: Self.now))
    }

    func testResultCopyNeverRevealsTheOutcome() {
        // The menu-bar mark and home subtitle outlive the staging gate, so outcome words stay out.
        let forbidden = ["승리", "패배", "무승부", "무효", "win", "won", "lose", "lost", "draw", "void"]
        for lang in [AppLanguage.ko, .en] {
            for kind in [OnlineAttentionKind.matchEnded, .resultReady] {
                let copy = L(lang).onlineAttentionCopy(attention(kind), now: Self.now)
                for text in [copy.tooltip, copy.subtitle, copy.banner] {
                    for word in forbidden {
                        XCTAssertFalse(text.lowercased().contains(word), "\(lang) \(kind): \(text)")
                    }
                }
            }
        }
    }
}
