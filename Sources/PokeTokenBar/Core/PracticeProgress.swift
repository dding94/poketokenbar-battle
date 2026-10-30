import Foundation

/// How a practice opponent picks its moves: the engine policy it runs (`config.pN.policy`, policy auto-v2).
/// Practice only. Online battles and the player's own automatic turns keep `standard`, which is auto-v1's scoring.
enum PracticeTemperament: String, CaseIterable, Sendable {
    /// auto-v1: the highest expected damage (power × STAB × type × accuracy).
    case standard
    /// Power × STAB first: type counts only as an immunity, and accuracy weighs a quarter (a 70% move keeps 92.5%).
    case aggressive
    /// At half HP or more, a status or stat-raising move that still works (twice a battle); below half, a heal;
    /// otherwise standard.
    case tactical
    /// A random move weighted by its standard score, never one scoring 0.
    case erratic

    /// From the individual's nature, so an opponent keeps one temperament: attack-raising natures are aggressive,
    /// defense-raising tactical, speed-raising standard, and the five neutral natures erratic. "Attack" and "defense"
    /// include their special counterparts. The switch is exhaustive, so a new nature cannot go unmapped.
    init(nature: PokemonNature) {
        switch nature {
        case .lonely, .brave, .adamant, .naughty, .modest, .mild, .quiet, .rash: self = .aggressive
        case .bold, .relaxed, .impish, .lax, .calm, .gentle, .sassy, .careful: self = .tactical
        case .timid, .hasty, .jolly, .naive: self = .standard
        case .hardy, .docile, .serious, .bashful, .quirky: self = .erratic
        }
    }
    /// The engine's policy id (`config.pN.policy`).
    var policyID: String { rawValue }
}

extension PracticeCandidate {
    /// nil without a snapshot (nothing to battle with anyway).
    var temperament: PracticeTemperament? {
        snapshot.flatMap { PokemonNature(rawValue: $0.set.nature) }.map(PracticeTemperament.init(nature:))
    }
}

/// How a practice battle ended for the player. A forfeit counts as a loss.
enum PracticeOutcome: String, Codable, Sendable {
    case win, loss, draw

    /// From the engine's winner; the player is always `p1`. No winner (the 200-turn cap, a tie) is a draw.
    init(winner: String?) {
        switch winner {
        case "p1": self = .win
        case "p2": self = .loss
        default: self = .draw
        }
    }
}

/// Practice results, kept apart from the save in their own file (`PracticeRecordStore`). Nothing else reads them.
struct PracticeRecords: Codable, Equatable, Sendable {
    /// The format this version writes. A file from a newer version is kept aside unread (`PracticeRecordStore.load`).
    static let currentVersion = 1
    var version = PracticeRecords.currentVersion
    var wins = 0
    var losses = 0
    var draws = 0
    /// Wins in a row; a loss or a draw ends it.
    var streak = 0
    var bestStreak = 0
    /// The local day (`PracticeDaily.dayKey`) the stars below belong to; another day starts with none.
    var dailyDay: String?
    var dailyStars: Set<PracticeDailyGoal> = []
    /// The local day the XP-paying wins below were counted on (PR 03C). Optional so older files still decode.
    var xpDay: String?
    var xpWins: Int?
}

/// PR 03C stakes (2026-10-30): battles against wild opponents and today's opponent cost HP, a loss faints, and a
/// win grows the current Pokémon. Sparring between your own Pokémon changes nothing.
enum PracticeStakes {
    /// Growth XP per win, 1/20 of a Rare Candy.
    static let winXP = 5_000_000
    /// Wins per local day that pay XP.
    static let dailyXPWins = 10
}

/// Why the selection can't start a battle (`PracticeSession.startBlock`).
enum PracticeStartBlock: Equatable, Sendable {
    /// The player fainted: no battle against a wild or today's opponent until it is healed. Sparring stays open.
    case fainted
}

/// What the result screen shows about a battle with stakes (`PracticeSession.lastStakes`).
struct PracticeStakesUpdate: Equatable, Sendable {
    /// The player's HP share after the battle (0 = fainted).
    let healthShare: Double
    /// XP the current Pokémon got: 0 after a loss, past the daily cap, or without a current Pokémon.
    let xp: Int
    /// Wins left today that still pay XP.
    let xpWinsLeft: Int
}

extension PracticeRecords {
    /// Counts one battle that ended and returns what the result screen shows; `PracticeSession` calls it once per
    /// battle. `dailyDay` is the day of today's opponent when the battle was against it, nil otherwise. Stars belong to
    /// one day: a battle against another day's opponent clears them before adding its own.
    mutating func record(_ outcome: PracticeOutcome, dailyDay: String?, turns: Int,
                         playerHPShare: Double) -> PracticeRecordUpdate {
        let previousStreak = streak
        switch outcome {
        case .win: wins += 1; streak += 1; bestStreak = max(bestStreak, streak)
        case .loss: losses += 1; streak = 0
        case .draw: draws += 1; streak = 0
        }
        var earned: Set<PracticeDailyGoal> = []
        if let dailyDay {
            if self.dailyDay != dailyDay { self.dailyDay = dailyDay; dailyStars = [] }
            earned = Set(PracticeDailyGoal.allCases.filter {
                $0.isMet(outcome: outcome, turns: turns, playerHPShare: playerHPShare)
            }).subtracting(dailyStars)
            dailyStars.formUnion(earned)
        }
        return PracticeRecordUpdate(outcome: outcome, streak: streak, bestStreak: bestStreak,
                                    endedStreak: outcome == .win || previousStreak == 0 ? nil : previousStreak,
                                    daily: dailyDay != nil, newStars: earned, stars: dailyDay == nil ? [] : dailyStars)
    }
}

/// What the result screen shows about the battle that just ended (`PracticeSession.lastRecord`).
struct PracticeRecordUpdate: Equatable, Sendable {
    let outcome: PracticeOutcome
    let streak: Int
    let bestStreak: Int
    /// The streak this battle ended, when a loss or a draw ended one of at least 1.
    let endedStreak: Int?
    /// Fought today's opponent.
    let daily: Bool
    /// Stars first earned in this battle, and today's stars after it (both empty unless `daily`).
    let newStars: Set<PracticeDailyGoal>
    let stars: Set<PracticeDailyGoal>
}

/// Today's opponent's three goals. Each is earned on its own, once per day.
enum PracticeDailyGoal: Int, Codable, CaseIterable, Comparable, Sendable {
    case win = 1
    /// Win within `quickTurns` turns.
    case quickWin = 2
    /// Win with at least `healthyShare` of the player's HP left.
    case healthyWin = 3

    /// Calibrated on 1,000 level-matched battles per temperament, mixed by how many natures each has: 49.6% of the
    /// player's wins end within 2 turns and 33.6% keep at least 85% of the HP (03B-5 targets about a half and a third).
    static let quickTurns = 2
    static let healthyShare = 0.85

    /// Every goal needs a win; both limits are inclusive.
    func isMet(outcome: PracticeOutcome, turns: Int, playerHPShare: Double) -> Bool {
        guard outcome == .win else { return false }
        switch self {
        case .win: return true
        case .quickWin: return turns <= Self.quickTurns
        case .healthyWin: return playerHPShare >= Self.healthyShare
        }
    }
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

extension BattleView.Pokemon {
    /// HP left as a share of the maximum. Exact only for the viewer's own side: the engine runs with
    /// `reportExactHP = false`, so the other side reports a percentage (`maxhp` 100). The player is `p1`.
    var hpShare: Double { Double(hp) / Double(max(1, maxhp)) }
}

/// Today's opponent: the wild generator with a seed from the local date, so a day keeps one opponent.
enum PracticeDaily {
    /// Prefix of today's opponent's candidate id; the rest of the id is its day.
    static let idPrefix = "daily-"
    /// "2026-10-30": the date in `calendar`'s time zone, written in ISO 8601 (always Gregorian) whatever calendar
    /// system `calendar` uses, so two machines on the same local day name it the same way.
    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: calendar.timeZone).year().month().day())
    }
    /// FNV-1a 64 of the key's UTF-8 bytes: the same on every launch and machine, unlike `hashValue`, which Swift
    /// seeds per process.
    static func seed(dayKey: String) -> UInt64 {
        dayKey.utf8.reduce(0xcbf2_9ce4_8422_2325 as UInt64) { ($0 ^ UInt64($1)) &* 0x0000_0100_0000_01b3 }
    }
    /// The day today's opponent was made for, from its candidate id; nil for every other candidate.
    static func dayKey(ofCandidateID id: String?) -> String? {
        guard let id, id.hasPrefix(idPrefix) else { return nil }
        return String(id.dropFirst(idPrefix.count))
    }
}
