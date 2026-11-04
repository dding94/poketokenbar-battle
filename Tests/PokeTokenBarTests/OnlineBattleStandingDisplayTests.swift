import XCTest
@testable import PokeTokenBar

final class OnlineBattleStandingDisplayTests: XCTestCase {
    private func row(wins: Int, losses: Int, draws: Int, streak: Int = 0, rate: Double?) -> OnlineBattleStanding {
        .init(trainerId: "synthetic-one", displayName: "나래", wins: wins, losses: losses, draws: draws,
              streak: streak, bestStreak: streak, winRate: rate)
    }

    func testWinRateShowsOneDecimalAfterFiveConfirmedGamesIncludingDraws() {
        XCTAssertEqual(OnlineBattleStandingDisplay.winRate(row(wins: 2, losses: 2, draws: 0, rate: nil)), "-")
        XCTAssertEqual(OnlineBattleStandingDisplay.winRate(row(wins: 2, losses: 2, draws: 1, rate: 0.4)), "40.0%")
        XCTAssertEqual(OnlineBattleStandingDisplay.winRate(row(wins: 1, losses: 4, draws: 1, rate: 1.0 / 6.0)), "16.7%")
    }

    func testChampionBadgeNeedsServerChampionAndPositiveCurrentStreak() {
        let standing = row(wins: 5, losses: 0, draws: 0, streak: 2, rate: 1)
        XCTAssertTrue(OnlineBattleStandingDisplay.isChampion(standing, in: .init(groupId: "synthetic-group", championTrainerId: standing.id, rows: [standing])))
        XCTAssertFalse(OnlineBattleStandingDisplay.isChampion(row(wins: 5, losses: 0, draws: 0, rate: 1), in: .init(groupId: "synthetic-group", championTrainerId: standing.id, rows: [standing])))
        XCTAssertFalse(OnlineBattleStandingDisplay.isChampion(standing, in: .init(groupId: "synthetic-group", championTrainerId: nil, rows: [standing])))
    }
}
