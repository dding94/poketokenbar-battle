import XCTest
@testable import PokeTokenBar

/// T19: what the result screen says (wording and receipts), who the rematch is with, and when its controls are on.
/// Pure inputs and the real engine fixture; no network, Keychain or save.
@MainActor
final class OnlineBattleResultTests: XCTestCase {
    private let ko = L(.ko), en = L(.en)

    private func hasHangul(_ text: String) -> Bool { text.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) } }
    private func effects(xp: Int64 = 0, share: Double) -> OnlineBattleResultEffects {
        .init(instanceID: "synthetic-pikachu", xp: xp, hpShare: share)
    }
    private func lines(_ kind: OnlineBattleUIResult.Kind, _ effects: OnlineBattleResultEffects?, _ l: L, name: String? = "피카츄") -> [String] {
        l.onlineResultEffectLines(.init(kind: kind, effects: effects), name: name)
    }

    // MARK: wording goes through L in both languages

    func testEveryOutcomeTitleIsLocalizedAndDistinct() {
        let kinds: [OnlineBattleUIResult.Kind] = [.win, .loss, .draw, .void, .record]
        XCTAssertEqual(kinds.map { ko.onlineResultTitle($0) }, ["승리", "패배", "무승부", "경기 무효", "기록으로만 남겼어요"])
        XCTAssertEqual(kinds.map { en.onlineResultTitle($0) }, ["Victory", "Defeat", "Draw", "Match voided", "Kept as a record"])
        for kind in kinds { XCTAssertFalse(hasHangul(en.onlineResultTitle(kind)), "\(kind) must not read Korean in English") }
    }

    func testSubtitleNamesTheFoeAndTurnsOnlyWhenTheyAreKnown() {
        XCTAssertEqual(ko.onlineResultSubtitle(.win, turns: 7, foe: "하늘"), ko.practiceWonLine(turns: 7, foe: "하늘"))
        XCTAssertEqual(ko.onlineResultSubtitle(.loss, turns: 7, foe: "하늘"), ko.practiceLostLine(turns: 7, foe: "하늘"))
        XCTAssertEqual(ko.onlineResultSubtitle(.draw, turns: 7, foe: "하늘"), ko.practiceDrawLine(turns: 7))
        XCTAssertEqual(ko.onlineResultSubtitle(.win, turns: nil, foe: "하늘"), "하늘에게 이겼어요")
        XCTAssertEqual(ko.onlineResultSubtitle(.loss, turns: nil, foe: "하늘"), "하늘에게 졌어요")
        XCTAssertEqual(en.onlineResultSubtitle(.win, turns: nil, foe: "Sky"), "Beat Sky")
        XCTAssertEqual(en.onlineResultSubtitle(.loss, turns: nil, foe: "Sky"), "Lost to Sky")
        for turns in [Int?.none, 7] { XCTAssertFalse(en.onlineResultSubtitle(.draw, turns: turns, foe: "Sky").isEmpty) }
    }

    func testARecordFromAnotherSaveMakesNoClaimAboutHPOrXP() {
        for l in [ko, en] {
            let words = l.onlineResultSubtitle(.record, turns: 7, foe: "하늘") + l.onlineOtherSaveResultDetail + l.onlineResultTitle(.record)
            for claim in ["체력", "경험치", "HP", "XP"] { XCTAssertFalse(words.contains(claim), "\(claim) in: \(words)") }
        }
        XCTAssertEqual(lines(.record, nil, ko), [], "no receipt, no effect line")
        XCTAssertEqual(lines(.void, nil, ko), [])
        XCTAssertTrue(ko.onlineResultSubtitle(.void, turns: nil, foe: "하늘").contains("바뀌지 않았어요"))
    }

    // MARK: effects are exactly the receipt

    func testALossThatFaintedSaysFaintedAndNeverMentionsRemainingHPOrXP() {
        let said = lines(.loss, effects(share: 0), ko)
        XCTAssertEqual(said.count, 1)
        XCTAssertTrue(said.first?.contains("피카츄가 기절했어요") == true, "\(said)")
        XCTAssertTrue(said.first?.contains("기력의조각") == true, "what brings it back is said once: \(said)")
        XCTAssertFalse(said.joined().contains("경험치"))
        XCTAssertFalse(said.joined().contains("남은 체력"))
        XCTAssertEqual(lines(.loss, effects(share: 0), en, name: "Pikachu"), ["Pikachu fainted · a Revive brings it back"])
        XCTAssertTrue(lines(.loss, effects(share: 0), ko, name: nil).first?.hasPrefix("출전한 포켓몬이 기절했어요") == true)
    }

    func testAWinPaidSaysTheXPAndTheHPTheReceiptKept() {
        let said = lines(.win, effects(xp: 10_000_000, share: 0.8), ko)
        XCTAssertEqual(said, [ko.onlineXP(10_000_000), "남은 체력 80%를 반영했어요"])
        XCTAssertEqual(lines(.win, effects(xp: 10_000_000, share: 0.8), en), [en.onlineXP(10_000_000), "80% HP kept"])
        XCTAssertFalse(said.joined().contains("기절"))
    }

    func testAWinThatPaidNothingSaysSoAndOtherOutcomesStaySilentAboutXP() {
        let unpaid = lines(.win, effects(xp: 0, share: 1), ko)
        XCTAssertEqual(unpaid, ["이번 승리에는 경험치가 없어요", "남은 체력 100%를 반영했어요"])
        XCTAssertFalse(unpaid.joined().contains("+"))
        for kind in [OnlineBattleUIResult.Kind.draw, .loss] {
            XCTAssertFalse(lines(kind, effects(share: 0.5), ko).joined().contains("경험치"), "\(kind) has no XP to talk about")
        }
        XCTAssertEqual(lines(.draw, effects(share: 0.5), ko), ["남은 체력 50%를 반영했어요"])
    }

    func testADrawThatLeftNothingStandingFaintedToo() {
        XCTAssertTrue(lines(.draw, effects(share: 0), ko).first?.contains("기절했어요") == true)
    }

    func testHPPercentNeverRoundsAStandingPokemonDownToZero() {
        XCTAssertEqual(effects(share: 0.004).hpPercent, 1)
        XCTAssertEqual(effects(share: 1).hpPercent, 100)
        XCTAssertEqual(effects(share: 0).hpPercent, 0)
        XCTAssertTrue(effects(share: 0).fainted)
        XCTAssertFalse(effects(share: 0.004).fainted)
    }

    // MARK: opponent line

    func testOpponentLineShowsNameStreakAndRecordOnlyWhenTheyMeanSomething() {
        XCTAssertEqual(ko.onlineResultOpponentLine(name: "하늘", streak: 3, record: .init(wins: 2, losses: 1, draws: 0)), "상대 · 하늘 · 연승 3 · 상대 전적 2승 1패")
        XCTAssertEqual(ko.onlineResultOpponentLine(name: "하늘", streak: 1, record: .init(wins: 1, losses: 0, draws: 0)), "상대 · 하늘 · 상대 전적 1승 0패")
        XCTAssertEqual(ko.onlineResultOpponentLine(name: "하늘", streak: 0, record: .init(wins: 1, losses: 1, draws: 2)), "상대 · 하늘 · 상대 전적 1승 1패 2무")
        XCTAssertEqual(en.onlineResultOpponentLine(name: "Sky", streak: 3, record: .init(wins: 2, losses: 1, draws: 0)), "vs Sky · 3-win streak · Record 2W 1L")
    }

    // MARK: rematch wording

    func testRematchWordingInBothLanguages() {
        XCTAssertEqual(ko.onlineRematchAgain, "한 번 더 겨루기")
        XCTAssertEqual(ko.onlineRematchWaitingCancel("하늘"), "하늘님의 응답을 기다려요 · 취소")
        XCTAssertEqual(en.onlineRematchWaitingCancel("Sky"), "Waiting for Sky · Cancel")
        XCTAssertEqual(ko.onlineResultToLobby, "로비로 돌아가기")
        XCTAssertEqual(ko.onlineRematchLater, "나중에")
        XCTAssertTrue(ko.onlineRematchReceived("하늘").contains("하늘님이"))
        for block in [OnlineRematchBlock.noHealthyPokemon, .opponentLeft, .requestWaiting, .entryHeld] {
            XCTAssertFalse(ko.onlineRematchBlockLine(block).isEmpty)
            XCTAssertFalse(hasHangul(en.onlineRematchBlockLine(block)), "\(block)")
            XCTAssertFalse(ko.onlineRematchBlockLine(block).contains("\n"), "one line")
        }
        XCTAssertNotEqual(ko.onlineRematchBlockLine(.noHealthyPokemon), ko.onlineRematchBlockLine(.opponentLeft))
        XCTAssertTrue(ko.onlineRematchBlockLine(.noHealthyPokemon).contains("기절"))
    }

    // MARK: the room and its rematch

    private func view(_ id: String, _ state: OnlineBattleState, me: OnlineBattleSide = .p1, createdAt: Double = 1, rematchOf: String? = nil,
                      winner: OnlineBattleWinner? = nil, foe: String = "synthetic-foe", terminalSeq: Int = 3) -> OnlineBattleView {
        let mine = OnlineBattlePlayer(trainerId: "synthetic-me", snapshot: nil, publicInfo: nil, hpPercent: nil)
        let theirs = OnlineBattlePlayer(trainerId: foe, snapshot: nil, publicInfo: nil, hpPercent: nil)
        let report = winner.map { OnlineBattleReport(readyToken: "t", engineHash: "h", terminalSeq: terminalSeq, winner: $0, logHash: "l", journalHash: "j", finalHp: .init(p1: 1, p2: 0)) }
        return .init(battleId: id, state: state, revision: 1, mode: .manual, p1: me == .p1 ? mine : theirs, p2: me == .p1 ? theirs : mine,
                     createdAt: createdAt, expiresAt: 9_999_999_999_999, startedAt: nil, reportedAt: nil, confirmed: false,
                     config: nil, roundSeq: terminalSeq, deadline: nil, ownChoice: nil, journal: [], result: report, reason: nil, rematchOf: rematchOf)
    }
    private func model(_ battles: [OnlineBattleView], shown: OnlineBattleView? = nil) -> OnlineBattlePresentation {
        let model = OnlineBattleScreenRenderingTests.model()
        model.battles = battles; model.room = shown; model.phase = shown == nil ? .lobby : .result
        model.localSide = shown?.side(for: "synthetic-me") ?? .p1
        return model
    }

    func testHeadToHeadCountsCompletedBattlesWithThatMemberOnly() {
        let list = [
            view("a", .completed, me: .p1, createdAt: 1, winner: .p1),
            view("b", .completed, me: .p2, createdAt: 2, winner: .p2),
            view("c", .completed, me: .p1, createdAt: 3, winner: .p2),
            view("d", .completed, me: .p1, createdAt: 4, winner: .draw),
            view("e", .void, createdAt: 5), view("f", .running, createdAt: 6),
            view("g", .completed, me: .p1, createdAt: 7, winner: .p1, foe: "someone-else"),
        ]
        let record = model(list).headToHead(against: "synthetic-foe")
        XCTAssertEqual([record.wins, record.losses, record.draws], [2, 1, 1])
    }

    func testWinStreakCountsConsecutiveCompletedWinsUpToTheShownBattle() {
        let list = [
            view("a", .completed, createdAt: 1, winner: .p2),
            view("b", .completed, createdAt: 2, winner: .p1),
            view("v", .void, createdAt: 3),
            view("c", .completed, me: .p2, createdAt: 4, winner: .p2, foe: "someone-else"),
            view("d", .completed, createdAt: 5, winner: .p1),
            view("later", .completed, createdAt: 6, winner: .p2),
        ]
        let presentation = model(list)
        XCTAssertEqual(presentation.winStreak(through: list[4]), 3, "a void match changes nothing; the later loss is not counted")
        XCTAssertEqual(presentation.winStreak(through: list[1]), 1)
        XCTAssertEqual(presentation.winStreak(through: list[0]), 0)
        let broken = [view("a", .completed, createdAt: 1, winner: .p1), view("b", .completed, createdAt: 2, winner: .draw), view("c", .completed, createdAt: 3, winner: .p1)]
        XCTAssertEqual(model(broken).winStreak(through: broken[2]), 1, "a draw ends a streak")
    }

    func testRematchOfferIsTheOpenRoomThatFollowsTheShownOne() {
        let source = view("src", .completed, winner: .p2)
        XCTAssertNil(model([source], shown: source).rematchOffer(for: source))
        let sent = view("re", .pending, me: .p1, createdAt: 2, rematchOf: "src")
        XCTAssertEqual(model([source, sent], shown: source).rematchOffer(for: source), .sent(sent))
        let received = view("re", .pending, me: .p2, createdAt: 2, rematchOf: "src")
        XCTAssertEqual(model([source, received], shown: source).rematchOffer(for: source), .received(received))
        let accepted = view("re", .accepted, me: .p1, createdAt: 2, rematchOf: "src")
        XCTAssertEqual(model([source, accepted], shown: source).rematchOffer(for: source), .underway(accepted))
        for ended in [OnlineBattleState.cancelled, .declined, .expired, .completed] {
            XCTAssertNil(model([source, view("re", ended, createdAt: 2, rematchOf: "src")], shown: source).rematchOffer(for: source), "\(ended)")
        }
        XCTAssertNil(model([source, view("re", .pending, createdAt: 2, rematchOf: "another")], shown: source).rematchOffer(for: source),
                     "another match's rematch is not this one's")
        let newest = view("re2", .pending, me: .p1, createdAt: 3, rematchOf: "src")
        XCTAssertEqual(model([source, sent, newest], shown: source).rematchOffer(for: source), .sent(newest))
    }

    func testARoomActionMayNameTheShownRoomOrItsOpenRematchAndNothingElse() {
        let source = view("src", .completed, winner: .p2)
        let rematch = view("re", .pending, me: .p2, createdAt: 2, rematchOf: "src")
        let stranger = view("other", .pending, me: .p2, createdAt: 3)
        let presentation = model([source, rematch, stranger], shown: source)
        XCTAssertEqual(presentation.actionRoom("src")?.battleId, "src")
        XCTAssertEqual(presentation.actionRoom("re")?.battleId, "re")
        XCTAssertNil(presentation.actionRoom("other"), "Review A: a press never reaches a room that is not the one looked at")
        XCTAssertNil(presentation.actionRoom("nope"))
        let running = view("run", .running, createdAt: 1)
        XCTAssertNil(model([running, rematch], shown: running).actionRoom("re"), "only a finished room carries a rematch with it")
    }

    func testAcceptDeclineAndCancelReachTheSessionForTheRematchBesideTheResult() {
        let source = view("src", .completed, winner: .p2)
        let received = view("re", .pending, me: .p2, createdAt: 2, rematchOf: "src")
        let incoming = model([source, received], shown: source)
        var sent: [String] = []
        incoming.onAction = { action in
            switch action {
            case .accept(let id): sent.append("accept \(id)")
            case .decline(let id): sent.append("decline \(id)")
            case .cancel(let id): sent.append("cancel \(id)")
            default: break
            }
        }
        incoming.send(.accept("re")); incoming.send(.decline("re")); incoming.send(.accept("other"))
        XCTAssertEqual(sent, ["accept re", "decline re"])
        let mine = view("re", .pending, me: .p1, createdAt: 2, rematchOf: "src")
        let outgoing = model([source, mine], shown: source)
        sent = []
        outgoing.onAction = { action in if case .cancel(let id) = action { sent.append("cancel \(id)") } }
        outgoing.send(.cancel("re")); outgoing.send(.cancel("other"))
        XCTAssertEqual(sent, ["cancel re"])
        outgoing.send(.accept("re"))
        XCTAssertEqual(sent, ["cancel re"], "the challenger cannot accept their own request")
    }

    func testLaterHidesTheRequestOnlyHereAndNeverReachesTheSession() {
        let source = view("src", .completed, winner: .p2)
        let received = view("re", .pending, me: .p2, createdAt: 2, rematchOf: "src")
        let presentation = model([source, received], shown: source)
        var reached = false
        presentation.onAction = { _ in reached = true }
        presentation.send(.deferRematch("re"))
        XCTAssertEqual(presentation.deferredRematchIDs, ["re"])
        XCTAssertFalse(reached, "putting it off sends nothing")
        XCTAssertEqual(presentation.rematchOffer(for: source), .received(received), "the request itself is still open")
    }

    // MARK: when the rematch button is off, and why

    func testTheRematchButtonSaysWhyItIsOff() {
        let source = view("src", .completed, winner: .p2)
        let ready = model([source], shown: source)
        XCTAssertTrue(ready.canRematch(source))
        XCTAssertNil(ready.rematchBlock(for: source))

        let fainted = model([source], shown: source)
        fainted.entryHP = ["synthetic-pikachu": 0]
        XCTAssertFalse(fainted.canRematch(source))
        XCTAssertEqual(fainted.rematchBlock(for: source), .noHealthyPokemon)

        let left = model([source], shown: source)
        left.members = [.init(trainerId: "synthetic-foe", displayEmail: "연습친구", role: .member, status: .left, joinedAt: 0, online: false)]
        XCTAssertFalse(left.canRematch(source))
        XCTAssertEqual(left.rematchBlock(for: source), .opponentLeft)

        let waiting = model([source, view("re", .pending, me: .p2, createdAt: 2, rematchOf: "src")], shown: source)
        waiting.deferredRematchIDs = ["re"]
        XCTAssertEqual(waiting.rematchBlock(for: source), .requestWaiting)

        let busy = model([source], shown: source); busy.isBusy = true
        XCTAssertNil(busy.rematchBlock(for: source), "a busy moment is not a reason to print")
    }

    func testAnOfflineOpponentIsAHintNotABlock() {
        let source = view("src", .completed, winner: .p2)
        let presentation = model([source], shown: source)
        XCTAssertFalse(presentation.rematchOpponentOffline(for: source))
        presentation.members = [.init(trainerId: "synthetic-foe", displayEmail: "연습친구", role: .host, status: .active, joinedAt: 0, online: false)]
        XCTAssertTrue(presentation.rematchOpponentOffline(for: source))
        XCTAssertTrue(presentation.canRematch(source), "their request still reaches them")
        XCTAssertNil(presentation.rematchBlock(for: source))
    }

    // MARK: staged totals

    func testTotalsAppearOnlyWhenEveryRoundReachedTheScreen() throws {
        let arena = try OnlineBattleArenaFixture.arena(seat: .p1)
        defer { arena.close() }
        let total = arena.battle.journal.count
        XCTAssertGreaterThan(total, 1, "the fixture needs at least two rounds")
        let finished = arena.battle
        arena.model.room = finished
        try arena.play(rounds: total - 1)
        arena.staging.skipToEnd()
        XCTAssertNil(arena.model.resultSummary(), "the last round never played, so its totals would be short")
        try arena.play(rounds: 1)
        arena.staging.skipToEnd()
        let summary = try XCTUnwrap(arena.model.resultSummary())
        XCTAssertGreaterThanOrEqual(summary.turns, finished.result?.terminalSeq ?? Int.max)
        XCTAssertNil(OnlineBattlePresentation().resultSummary(), "no staging, no totals")
    }

    func testTotalsAreHiddenAfterAResyncLeftRoundsUnstaged() throws {
        let arena = try OnlineBattleArenaFixture.arena(seat: .p1)
        defer { arena.close() }
        arena.model.room = arena.battle
        try arena.play(rounds: arena.battle.journal.count)
        arena.staging.skipToEnd()
        XCTAssertNotNil(arena.model.resultSummary())
        let resynced = try OnlineBattleArenaFixture.arena(seat: .p1)
        defer { resynced.close() }
        resynced.model.room = resynced.battle
        resynced.staging.markResync()
        try resynced.play(rounds: resynced.battle.journal.count)
        resynced.staging.skipToEnd()
        XCTAssertNil(resynced.model.resultSummary(), "a rebuilt log staged nothing, so the history is empty")
    }

    // MARK: the banner does not repeat what the result already asks

    private func attentionInput(_ model: OnlineBattlePresentation, screen: Bool = true) -> OnlineAttentionInput {
        OnlineAttentionSource(presentation: model).input(now: Date(timeIntervalSince1970: 1), onlineScreenShowing: screen)
    }

    func testARematchTheResultAsksAboutGetsNoSecondBannerUntilSomethingCoversTheResult() {
        let source = view("src", .completed, winner: .p2)
        let received = view("re", .pending, me: .p2, createdAt: 2, rematchOf: "src")
        let presentation = model([source, received], shown: source)
        presentation.result = .init(kind: .loss, effects: effects(share: 0))
        XCTAssertNil(OnlineAttentionCalculator.banner(attentionInput(presentation)), "the result asks in place")
        XCTAssertEqual(OnlineAttentionCalculator.banner(attentionInput(presentation, screen: false))?.kind, .rematchRequested)
        presentation.showsHistory = true
        XCTAssertEqual(OnlineAttentionCalculator.banner(attentionInput(presentation))?.kind, .rematchRequested)
        presentation.showsHistory = false
        let stranger = view("other", .pending, me: .p2, createdAt: 3)
        presentation.battles = [source, received, stranger]
        XCTAssertEqual(OnlineAttentionCalculator.banner(attentionInput(presentation))?.battleId, "other",
                       "an unrelated request is still told")
    }
}
