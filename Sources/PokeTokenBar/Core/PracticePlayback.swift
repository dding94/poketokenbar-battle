import Foundation
import Observation

/// A side of a practice battle from the player's (p1) viewpoint.
enum PracticeSide: String, Hashable, Sendable { case player = "p1", opponent = "p2" }

/// One fact from the engine's p1-viewer protocol log, typed so the screen can stage it.
/// HP is what p1 sees: exact for the player, percent (max 100) for the opponent.
enum PracticeEvent: Equatable, Sendable {
    case turn(Int)
    /// `|switch|`: the side entered with this HP (seeds the display).
    case switchIn(PracticeSide, hp: Int, maxHP: Int)
    /// `moveID` is the Showdown id of the displayed name ("Volt Tackle" → "volttackle").
    case move(PracticeSide, moveID: String)
    /// `|cant|`: reason id such as "par", "slp", "frz", "recharge", "flinch".
    case cant(PracticeSide, reason: String)
    /// `cause` is the lowercased `[from]` source ("recoil", "psn", "sandstorm"); nil for a direct hit.
    case damage(PracticeSide, hp: Int, maxHP: Int, cause: String?)
    case heal(PracticeSide, hp: Int, maxHP: Int, cause: String?)
    /// Effectiveness and critical hits name the defender; `miss` names the attacker.
    case superEffective(PracticeSide)
    case resisted(PracticeSide)
    case immune(PracticeSide)
    case critical(PracticeSide)
    case miss(PracticeSide)
    case failed(PracticeSide)
    case status(PracticeSide, code: String)
    case cureStatus(PracticeSide, code: String)
    /// Negative `stages` for drops. Stat ids: atk, def, spa, spd, spe, accuracy, evasion.
    case boost(PracticeSide, stat: String, stages: Int)
    case faint(PracticeSide)
    /// Showdown weather id; nil when the weather ends.
    case weather(String?)
    case abilityRevealed(PracticeSide, abilityID: String)
    /// The player's manual turn ran out of time and was picked automatically.
    case timedOut
    /// nil winner: draw.
    case end(winner: PracticeSide?)
}

/// Turns `drainLog` lines (viewer p1) into events. It keeps each side's max HP from `|switch|` so a
/// later "0 fnt" still has a scale. Lines it does not model are dropped; the text log keeps them.
struct PracticeEventParser {
    mutating func parse(_ lines: [String]) -> [PracticeEvent] { [] }
}

/// A short callout on screen while a beat plays. Data only; the screen words it.
enum PracticeCallout: Equatable, Sendable {
    case superEffective(PracticeSide), resisted(PracticeSide), immune(PracticeSide)
    case critical(PracticeSide), miss(PracticeSide), failed(PracticeSide)
    case status(PracticeSide, code: String), cureStatus(PracticeSide, code: String)
    case boost(PracticeSide, stat: String, stages: Int)
    case cant(PracticeSide, reason: String)
    case fainted(PracticeSide)
    case weather(String?)
    case abilityRevealed(PracticeSide, abilityID: String)
    case recoil(PracticeSide)
    case timedOut
}

/// What a combatant looks like on screen at the current point of the playback.
struct PracticeDisplaySide: Equatable, Sendable {
    var hp: Int
    var maxHP: Int
    var status: String?
    var fainted: Bool
    /// Percent of max HP, rounded, for bars and callouts.
    var percent: Int { maxHP > 0 ? Int((Double(hp) * 100 / Double(maxHP)).rounded()) : 0 }
}

/// One staged moment: an action, or an end-of-turn effect, with its consequences.
struct PracticeBeat: Equatable, Identifiable, Sendable {
    let id: Int
    let turn: Int
    /// The side that acted; nil for end-of-turn effects (poison, weather) and system beats.
    let actor: PracticeSide?
    let moveID: String?
    let callouts: [PracticeCallout]
    /// Net HP change during the beat in percent points of max HP (negative: damage).
    let hpDelta: [PracticeSide: Int]
    /// Display state once the beat has played.
    let after: [PracticeSide: PracticeDisplaySide]
}

/// Totals for the result screen, derived from the played beats.
struct PracticeSummary: Equatable, Sendable {
    var turns = 0
    /// Opponent HP percent removed, and player HP percent removed.
    var damageDealtPercent = 0
    var damageTakenPercent = 0
    /// The move whose hit made the loser faint; nil for a draw or a faint not caused by a move.
    var finishingMoveID: String?
    var criticalHits = 0
    var superEffectiveHits = 0
}

/// Stages engine events as beats on a clock, so a turn reads as a scene instead of a dump of lines.
/// `PracticeSession` feeds it after every engine step and holds the battle (`.playback`) while beats
/// remain; when the practice screen is not visible it skips straight to the end, so nothing animates
/// in the background.
@MainActor @Observable
final class PracticePlayback {
    /// About 0.9 s per action beat and 0.6 s per end-of-turn beat.
    static let actionBeat: TimeInterval = 0.9
    static let residualBeat: TimeInterval = 0.6

    /// Per side, what the screen shows now.
    private(set) var display: [PracticeSide: PracticeDisplaySide] = [:]
    /// The beat on screen; nil when nothing is playing.
    private(set) var beat: PracticeBeat?
    /// Finished beats, newest first, at most five, for the ticker.
    private(set) var recent: [PracticeBeat] = []
    /// Every beat of this battle in order, for the summary and the full log.
    private(set) var history: [PracticeBeat] = []
    /// A beat is on screen or queued.
    var isPlaying: Bool { false }
    var summary: PracticeSummary { PracticeSummary() }

    private let clock: () -> TimeInterval

    init(clock: @escaping () -> TimeInterval) { self.clock = clock }

    /// Queues the events of one engine step as beats. `switchIn` events seed `display` at once.
    func enqueue(_ events: [PracticeEvent]) {}
    /// Moves on to the next beat once the current one's time is up. The session's driver calls it.
    func advance() {}
    /// Plays every queued beat instantly (screen hidden, or the user skips).
    func skipToEnd() {}
}
