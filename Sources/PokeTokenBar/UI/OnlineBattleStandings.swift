import SwiftUI

enum OnlineBattleStandingDisplay {
    static func winRate(_ row: OnlineBattleStanding) -> String { "-" }
    static func isChampion(_ row: OnlineBattleStanding, in board: OnlineBattleStandings) -> Bool { false }
}
