import XCTest
@testable import PokeTokenBar

/// T18: the foe card's nickname and the head-to-head line. Only values the server already gave are used: the
/// member list's nickname, the battles list's finished results and, when the standings were loaded, the streak.
@MainActor
final class OnlineBattleOpponentLineTests: XCTestCase {
    private let me = "synthetic-me", foe = "synthetic-foe", other = "synthetic-other"

    private func battle(_ id: String, p1: String, p2: String, state: OnlineBattleState = .completed,
                        winner: OnlineBattleWinner? = nil) -> OnlineBattleView {
        let base = OnlineBattleScreenRenderingTests.room(state: state, id: id)
        let report = winner.map {
            OnlineBattleReport(readyToken: "t", engineHash: "e", terminalSeq: 1, winner: $0, logHash: "l", journalHash: "j",
                               finalHp: .init(p1: $0 == .p1 ? 10 : 0, p2: $0 == .p2 ? 10 : 0))
        }
        return .init(battleId: id, state: state, revision: 1, mode: .manual,
                     p1: .init(trainerId: p1, snapshot: base.p1.snapshot, publicInfo: nil, hpPercent: nil),
                     p2: .init(trainerId: p2, snapshot: nil, publicInfo: base.p2.publicInfo, hpPercent: nil),
                     createdAt: base.createdAt, expiresAt: 100, startedAt: 0, reportedAt: nil, confirmed: true,
                     config: nil, roundSeq: 1, deadline: nil, ownChoice: nil, journal: [], result: report, reason: nil, rematchOf: nil)
    }

    /// An arena room against `foe`, me as the first seat.
    private func model(battles: [OnlineBattleView] = []) -> OnlineBattlePresentation {
        let model = OnlineBattleScreenRenderingTests.model()
        OnlineBattleScreenRenderingTests.arena(model)
        model.localSide = .p1
        model.battles = battles
        return model
    }

    // MARK: record

    /// Three finished games against the same foe, two won and one lost, from either seat. A running one, one against
    /// somebody else and the ones that ended without a result do not count.
    func testFinishedGamesAgainstTheSameFoeAreCountedFromMySeat() {
        let model = model(battles: [
            battle("a", p1: me, p2: foe, winner: .p1),
            battle("b", p1: foe, p2: me, winner: .p2),
            battle("c", p1: me, p2: foe, winner: .p2),
            // Even carrying a result, a game that is not completed counts for nothing.
            battle("running", p1: me, p2: foe, state: .running, winner: .p1),
            battle("void", p1: me, p2: foe, state: .void, winner: .p1),
            battle("declined", p1: me, p2: foe, state: .declined, winner: .p1),
            battle("elsewhere", p1: me, p2: other, winner: .p1),
            battle("theirs", p1: foe, p2: other, winner: .p1),
        ])
        XCTAssertEqual(model.opponentRecord, OnlineBattleRecord(wins: 2, losses: 1, draws: 0))
    }

    func testADrawIsNeitherAWinNorALoss() {
        let model = model(battles: [battle("a", p1: me, p2: foe, winner: .draw), battle("b", p1: me, p2: foe, winner: .p1)])
        XCTAssertEqual(model.opponentRecord, OnlineBattleRecord(wins: 1, losses: 0, draws: 1))
    }

    func testNoFinishedGamesMeansNoRecord() {
        let model = model(battles: [battle("running", p1: me, p2: foe, state: .running), battle("done", p1: me, p2: other, winner: .p1)])
        XCTAssertTrue(model.opponentRecord.isEmpty)
        XCTAssertNil(L(.ko).onlineOpponentLine(record: model.opponentRecord, streak: nil))
    }

    func testAFinishedGameWithoutAResultIsLeftOut() {
        let model = model(battles: [battle("odd", p1: me, p2: foe, winner: nil)])
        XCTAssertTrue(model.opponentRecord.isEmpty)
    }

    func testTheOpponentIsTheOtherSeatOfTheRoomWhicheverSeatIAm() {
        let model = model()
        XCTAssertEqual(model.opponentTrainerID, foe)
        model.localSide = .p2
        XCTAssertEqual(model.opponentTrainerID, "synthetic-me", "the second seat's foe is the first seat")
        model.room = nil
        XCTAssertNil(model.opponentTrainerID)
        XCTAssertTrue(model.opponentRecord.isEmpty)
    }

    // MARK: nickname and streak

    func testTheNicknameIsTheMembersAndMissingWhenTheServerGaveNone() {
        let model = model()
        XCTAssertEqual(model.opponentNickname, "연습친구")
        model.members = [.init(trainerId: foe, displayEmail: nil, role: .member, status: .left, joinedAt: 0, online: false)]
        XCTAssertNil(model.opponentNickname)
        model.members = []
        XCTAssertNil(model.opponentNickname)
    }

    func testTheStreakComesFromTheLoadedStandingsOnlyAndOnlyWhenItIsAStreak() {
        let model = model()
        XCTAssertNil(model.opponentStreak, "standings were never loaded")
        func standings(_ streak: Int) -> OnlineBattleStandings {
            .init(groupId: "g", championTrainerId: nil, rows: [
                .init(trainerId: foe, displayName: "연습친구", wins: 5, losses: 0, draws: 0, streak: streak, bestStreak: 5, winRate: 1)])
        }
        model.standings = standings(3); XCTAssertEqual(model.opponentStreak, 3)
        model.standings = standings(1); XCTAssertNil(model.opponentStreak, "one win is not a streak")
        model.standings = standings(0); XCTAssertNil(model.opponentStreak)
        model.standings = .init(groupId: "g", championTrainerId: nil, rows: []); XCTAssertNil(model.opponentStreak)
    }

    // MARK: words

    func testTheLineJoinsWhateverThereIsAndLeavesOutWhatThereIsNot() {
        let ko = L(.ko), en = L(.en)
        let record = OnlineBattleRecord(wins: 2, losses: 1, draws: 0)
        XCTAssertEqual(ko.onlineOpponentLine(record: record, streak: 3), "연승 3 · 상대 전적 2승 1패")
        XCTAssertEqual(ko.onlineOpponentLine(record: record, streak: nil), "상대 전적 2승 1패")
        XCTAssertEqual(ko.onlineOpponentLine(record: .init(wins: 0, losses: 0, draws: 0), streak: 3), "연승 3")
        XCTAssertNil(ko.onlineOpponentLine(record: .init(wins: 0, losses: 0, draws: 0), streak: nil))
        XCTAssertEqual(ko.onlineOpponentLine(record: .init(wins: 1, losses: 0, draws: 2), streak: nil), "상대 전적 1승 2무 0패")
        XCTAssertEqual(en.onlineOpponentLine(record: record, streak: 3), "3-win streak · vs them 2W 1L")
        XCTAssertEqual(en.onlineOpponentLine(record: .init(wins: 1, losses: 0, draws: 2), streak: nil), "vs them 1W 2D 0L")
        XCTAssertNil(en.onlineOpponentLine(record: .init(wins: 0, losses: 0, draws: 0), streak: nil))
    }

    func testTheFoeLabelTakesTheNicknameOrStaysPlain() {
        XCTAssertEqual(L(.ko).onlineFoeLabel(nickname: "연습친구"), "상대 · 연습친구")
        XCTAssertEqual(L(.en).onlineFoeLabel(nickname: "Misty"), "Foe · Misty")
        XCTAssertEqual(L(.ko).onlineFoeLabel(nickname: nil), L(.ko).practiceFoe)
        XCTAssertEqual(L(.en).onlineFoeLabel(nickname: ""), L(.en).practiceFoe)
    }

    /// The arena's foe card carries the label and the line; my own card carries neither.
    func testTheArenaGivesTheFoeCardTheLabelAndTheLineAndMineNeither() throws {
        let model = model(battles: [battle("a", p1: me, p2: foe, winner: .p1), battle("b", p1: me, p2: foe, winner: .p2),
                                    battle("c", p1: me, p2: foe, winner: .p1)])
        let arena = OnlineBattleArena(model: model, l: L(.ko), artwork: false, speciesNameProvider: OnlineBattleSyntheticNameProvider(),
                                      speciesNameStore: PokemonNameDisplayStore())
        let view = try XCTUnwrap(model.arena)
        let foeCard = arena.sideCard(.opponent, view: view), ownCard = arena.sideCard(.player, view: view)
        XCTAssertEqual(foeCard.label, "상대 · 연습친구")
        XCTAssertEqual(foeCard.caption, "상대 전적 2승 1패")
        XCTAssertNil(ownCard.label); XCTAssertNil(ownCard.caption)
        model.battles = []
        XCTAssertEqual(arena.sideCard(.opponent, view: view).caption, " ", "no record: the line is blank, not missing, so the card keeps its height")
        model.members = []
        XCTAssertNil(arena.sideCard(.opponent, view: view).label, "no nickname: the card keeps its plain label")
    }
}
