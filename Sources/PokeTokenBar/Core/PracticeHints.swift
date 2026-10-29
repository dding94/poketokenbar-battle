import Foundation

/// Public move data from the engine (`describeMoves`): what a player needs to choose a move.
struct PracticeMoveInfo: Decodable, Equatable, Sendable {
    let id: String
    let name: String
    let type: String
    /// "Physical", "Special" or "Status".
    let category: String
    let basePower: Int
    /// nil: the move never misses.
    let accuracy: Int?
    let priority: Int
    let pp: Int
    var isStatus: Bool { category == "Status" }
}

/// Type-only damage multipliers from the engine (`typeChart`). Abilities are hidden until revealed,
/// so immunities such as Levitate never count here.
struct PracticeTypeChart: Decodable, Equatable, Sendable {
    let types: [String]
    let damage: [String: [String: Double]]

    /// Product over the defender's types; nil when any type is unknown or `defenders` is empty.
    func multiplier(attack: String, defenders: [String]) -> Double? { nil }
}

/// What the selection screen says about a pairing, from public information only.
struct PracticeMatchup: Equatable, Sendable {
    enum Order: Equatable, Sendable { case playerFirst, opponentFirst, speedTie }
    /// Best multiplier among the player's damaging moves against the opponent's types (1 when it has
    /// none), and the moves that reach it (Showdown ids, in the player's move order).
    var bestOffense: Double
    var bestMoveIDs: [String]
    /// Worst case of the opponent's own types against the player's types, as if it used moves of
    /// its types: a hint about danger, not a reveal of its moves.
    var threat: Double
    /// From public Speed only; priority moves and stat changes can still flip it.
    var order: Order
    var playerSpeed: Int
    var opponentSpeed: Int
    /// Opponent level minus player level.
    var levelGap: Int
}

/// What one move card shows in battle.
struct PracticeMoveHint: Equatable, Sendable {
    let info: PracticeMoveInfo
    /// Against the opponent's current public types; nil for status moves.
    let multiplier: Double?
    /// Same type as the user (the engine applies ×1.5).
    let stab: Bool
}

/// How fast turns are staged. `instant` skips the staging like a hidden screen does.
enum PracticePlaybackSpeed: String, CaseIterable, Sendable {
    case normal, fast, instant
    /// Beat durations are multiplied by this; `instant` never stages.
    var timeScale: Double { 1 }
}
