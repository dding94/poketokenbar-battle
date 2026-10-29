import Foundation

/// How a practice opponent picks its moves: the engine policy it runs (`config.pN.policy`, policy auto-v2).
/// Practice only. Online battles and the player's own automatic turns keep `standard`, which is auto-v1's scoring.
enum PracticeTemperament: String, CaseIterable, Sendable {
    /// auto-v1: the highest expected damage (power × STAB × type × accuracy).
    case standard
    /// Power first, accuracy barely counted.
    case aggressive
    /// Status and stat-raising moves while healthy, healing when low, then damage.
    case tactical
    /// A random move weighted by its score.
    case erratic

    /// From the individual's nature, so an opponent keeps one temperament: attack-raising natures are aggressive,
    /// defense-raising tactical, speed-raising standard, and the five neutral natures erratic.
    init(nature: PokemonNature) { self = .standard }   // contract stub
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
enum PracticeOutcome: String, Codable, Sendable { case win, loss, draw }

/// Practice results, kept apart from the save in their own file (`PracticeRecordStore`). Nothing else reads them.
struct PracticeRecords: Codable, Equatable, Sendable {
    var version = 1
    var wins = 0
    var losses = 0
    var draws = 0
    /// Wins in a row; a loss or a draw ends it.
    var streak = 0
    var bestStreak = 0
    /// The local day (`PracticeDaily.dayKey`) the stars below belong to; another day starts with none.
    var dailyDay: String?
    var dailyStars: Set<PracticeDailyGoal> = []
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

    static let quickTurns = 3      // placeholder until calibrated
    static let healthyShare = 0.5  // placeholder until calibrated

    func isMet(outcome: PracticeOutcome, turns: Int, playerHPShare: Double) -> Bool { false }   // contract stub
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// Today's opponent: the wild generator with a seed from the local date, so a day keeps one opponent.
enum PracticeDaily {
    /// Prefix of today's opponent's candidate id.
    static let idPrefix = "daily-"
    /// "2026-10-30" in `calendar`'s time zone.
    static func dayKey(_ date: Date, calendar: Calendar) -> String { "" }   // contract stub
    /// A stable seed for `dayKey`, the same on every launch and machine.
    static func seed(dayKey: String) -> UInt64 { 0 }   // contract stub
}

// MARK: RED stubs (03B-5): compile-only, replaced by the implementation.

extension PracticeOutcome {
    init(winner: String?) { self = .draw }   // RED stub
}

extension PracticeRecords {
    static let currentVersion = 1
    mutating func record(_ outcome: PracticeOutcome, dailyDay: String?, turns: Int, playerHPShare: Double) -> PracticeRecordUpdate {
        PracticeRecordUpdate(outcome: outcome, streak: 0, bestStreak: 0, endedStreak: nil, daily: false, newStars: [], stars: [])   // RED stub
    }
}

extension PracticeDaily {
    static func dayKey(ofCandidateID id: String?) -> String? { nil }   // RED stub
}

extension BattleView.Pokemon {
    var hpShare: Double { 0 }   // RED stub
}
