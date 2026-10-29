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
/// `-sethp` (Pain Split) becomes a damage or heal by comparing with the side's last HP; `-setboost`
/// (Belly Drum) is a boost whose `stages` is the stage it was set to. `|-weather|...|[upkeep]` repeats a
/// weather already announced, so only changes become events.
struct PracticeEventParser {
    private var maxHP: [PracticeSide: Int] = [:]
    private var lastHP: [PracticeSide: Int] = [:]

    mutating func parse(_ lines: [String]) -> [PracticeEvent] {
        var events: [PracticeEvent] = []
        for line in lines { if let event = event(from: line) { events.append(event) } }
        return events
    }

    private mutating func event(from line: String) -> PracticeEvent? {
        let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count > 1 else { return nil }
        func field(_ index: Int) -> String { index < parts.count ? parts[index] : "" }
        let side = Self.side(of: field(2))
        switch parts[1] {
        case "turn": return Int(field(2)).map(PracticeEvent.turn)
        case "switch", "drag":
            guard let side, let hp = Self.hp(field(4)) else { return nil }
            let max = hp.max ?? hp.current
            maxHP[side] = max; lastHP[side] = hp.current
            return .switchIn(side, hp: hp.current, maxHP: max)
        case "move": return side.map { .move($0, moveID: Self.id(field(3))) }
        case "cant": return side.map { .cant($0, reason: Self.cause(field(3))) }
        case "-damage", "-heal", "-sethp":
            guard let side, let hp = Self.hp(field(3)) else { return nil }
            let max = hp.max ?? maxHP[side] ?? 100
            let before = lastHP[side] ?? hp.current
            maxHP[side] = max; lastHP[side] = hp.current
            let cause = parts.dropFirst(4).first { $0.hasPrefix("[from] ") }
                .map { Self.cause(String($0.dropFirst("[from] ".count))) }
            let lowers = parts[1] == "-damage" || (parts[1] == "-sethp" && hp.current < before)
            return lowers ? .damage(side, hp: hp.current, maxHP: max, cause: cause)
                          : .heal(side, hp: hp.current, maxHP: max, cause: cause)
        case "-supereffective": return side.map(PracticeEvent.superEffective)
        case "-resisted": return side.map(PracticeEvent.resisted)
        case "-immune": return side.map(PracticeEvent.immune)
        case "-crit": return side.map(PracticeEvent.critical)
        case "-miss": return side.map(PracticeEvent.miss)
        case "-fail": return side.map(PracticeEvent.failed)
        case "-status": return side.map { .status($0, code: field(3).lowercased()) }
        case "-curestatus": return side.map { .cureStatus($0, code: field(3).lowercased()) }
        case "-boost", "-unboost", "-setboost":
            guard let side, let amount = Int(field(4)) else { return nil }
            return .boost(side, stat: field(3).lowercased(), stages: parts[1] == "-unboost" ? -amount : amount)
        case "faint": return side.map(PracticeEvent.faint)
        case "-weather":
            guard !parts.contains("[upkeep]") else { return nil }
            let weather = Self.id(field(2))
            return .weather(weather == "none" ? nil : weather)
        case "win": return .end(winner: PracticeSide(rawValue: field(2)))
        case "tie": return .end(winner: nil)
        default: return nil
        }
    }

    private static func side(of ident: String) -> PracticeSide? {
        if ident.hasPrefix("p1") { return .player }
        if ident.hasPrefix("p2") { return .opponent }
        return nil
    }
    /// "73/100", "73/100 psn" or "0 fnt"; `max` is nil when the field has no denominator.
    private static func hp(_ field: String) -> (current: Int, max: Int?)? {
        guard let token = field.split(separator: " ").first else { return nil }
        let numbers = token.split(separator: "/").map { Int($0) }
        guard let first = numbers.first, let current = first else { return nil }
        return (current, numbers.count > 1 ? numbers[1] : nil)
    }
    private static func id(_ text: String) -> String {
        String(text.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) })
    }
    /// Lowercased, without the "item: " / "ability: " / "move: " source prefix.
    private static func cause(_ text: String) -> String {
        var cause = text.lowercased()
        for prefix in ["item: ", "ability: ", "move: "] where cause.hasPrefix(prefix) { cause.removeFirst(prefix.count) }
        return cause
    }
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
    /// The screen's VS splash has played for this battle; the screen sets it, so a reopened popover skips it.
    var introShown = false
    /// Multiplies beat durations (0.5 when fast). `PracticeSession.playbackSpeed` sets it; a change also
    /// shortens or lengthens the beat on screen.
    var timeScale: Double = 1 {
        didSet {
            guard timeScale != oldValue, beat != nil else { return }
            beatEnd = beatStart + beatLength * max(0, timeScale)
        }
    }
    /// A beat is on screen or queued.
    var isPlaying: Bool { beat != nil || !queue.isEmpty }
    var summary: PracticeSummary {
        var summary = PracticeSummary()
        var fainted: [(side: PracticeSide, beat: PracticeBeat)] = []
        for beat in history {
            summary.turns = max(summary.turns, beat.turn)
            if let delta = beat.hpDelta[.opponent], delta < 0 { summary.damageDealtPercent -= delta }
            if let delta = beat.hpDelta[.player], delta < 0 { summary.damageTakenPercent -= delta }
            for callout in beat.callouts {
                switch callout {
                case .critical: summary.criticalHits += 1
                case .superEffective: summary.superEffectiveHits += 1
                case .fainted(let side): fainted.append((side, beat))
                default: break
                }
            }
        }
        // One loser only (both fainting is a draw); a faint from poison or recoil has no finishing move.
        if fainted.count == 1, let loser = fainted.first, loser.beat.actor == loser.side.foe {
            summary.finishingMoveID = loser.beat.moveID
        }
        return summary
    }

    @ObservationIgnored private var queue: [PracticeBeat] = []
    @ObservationIgnored private var beatEnd: TimeInterval = 0
    /// When the beat on screen started and how long it lasts at scale 1; a scale change recomputes `beatEnd` from them.
    @ObservationIgnored private var beatStart: TimeInterval = 0
    @ObservationIgnored private var beatLength: TimeInterval = 0
    /// What the screen will show after every queued beat; the base for the next beat's `after`.
    @ObservationIgnored private var queued: [PracticeSide: PracticeDisplaySide] = [:]
    @ObservationIgnored private var turn = 0
    @ObservationIgnored private var nextID = 0
    /// A manual timeout waits for the player's next beat; the next `turn` drops it.
    @ObservationIgnored private var pendingTimeout = false
    /// Consequences that arrive with no beat open (an ability at battle start, intimidate); they ride on
    /// the next action beat instead of holding the battle with a beat of their own.
    @ObservationIgnored private var preamble: [PracticeEvent] = []
    private let clock: () -> TimeInterval

    init(clock: @escaping () -> TimeInterval) { self.clock = clock }

    /// Queues the events of one engine step as beats. `switchIn` events seed `display` at once. When no
    /// beat is on screen, the first queued beat starts right away at `clock()`.
    ///
    /// Grouping: a `move` or `cant` opens an action beat that collects what follows until the next move,
    /// cant or turn. Consequences that arrive with no beat open (abilities at battle start) join the next
    /// action beat. Damage or heal from an end-of-turn source (psn, brn, sandstorm, leftovers, ...)
    /// closes it and opens an actor-less residual beat; recoil, drain, item and contact damage stay in the
    /// action beat. A wake-up (`cureStatus`) right before a move belongs to that move's beat, and
    /// `weather(nil)` is end-of-turn, so it joins a residual beat. `end` makes no beat. `timedOut` becomes
    /// a callout on the player's next action beat of that turn: the step it precedes is the turn the
    /// player lost, and it is the player's own action that was picked for them.
    func enqueue(_ events: [PracticeEvent]) {
        var drafts: [Draft] = []
        var open: Draft?
        func close() {
            if let draft = open, draft.actor != nil || !draft.events.isEmpty { drafts.append(draft) }
            open = nil
        }
        func begin(_ actor: PracticeSide?, moveID: String? = nil) {
            var carried: [PracticeEvent] = []
            if let actor, let last = open?.events.last, case .cureStatus(let side, _) = last, side == actor {
                carried = [last]; open?.events.removeLast()
            }
            close()
            if actor != nil { carried = preamble + carried; preamble = [] }
            var draft = Draft(actor: actor, moveID: moveID, turn: turn, events: carried)
            if actor == .player, pendingTimeout { draft.timedOut = true; pendingTimeout = false }
            open = draft
        }
        func add(_ event: PracticeEvent) {
            if open == nil { preamble.append(event) } else { open?.events.append(event) }
        }
        func addResidual(_ event: PracticeEvent) {
            if open?.actor != nil { close() }
            if open == nil { begin(nil) }
            open?.events.append(event)
        }
        for event in events {
            switch event {
            case .turn(let value): close(); turn = value; pendingTimeout = false
            case .switchIn(let side, let hp, let maxHP):
                let seeded = PracticeDisplaySide(hp: hp, maxHP: maxHP, status: nil, fainted: false)
                display[side] = seeded; queued[side] = seeded
            case .move(let side, let moveID): begin(side, moveID: moveID)
            case .cant(let side, _): begin(side); add(event)
            case .timedOut: pendingTimeout = true
            case .end: break
            case .damage(let side, _, _, let cause), .heal(let side, _, _, let cause):
                switch Self.phase(of: cause, openMove: open?.actor != nil ? open?.moveID : nil) {
                case .confusion: begin(side); add(event)
                case .action: add(event)
                case .residual: addResidual(event)
                }
            case .weather(let id): if id == nil { addResidual(event) } else { add(event) }
            default: add(event)
            }
        }
        close()
        for draft in drafts { queue.append(makeBeat(draft)) }
        startNext()
    }
    /// Commits the beat on screen once its time is up (`display` takes its `after`, it joins `history`
    /// and `recent`) and starts the next queued beat at `clock()`. `PracticeSession.tick()` calls it.
    func advance() {
        if let current = beat {
            guard clock() >= beatEnd else { return }
            commit(current)
        }
        startNext()
    }
    /// Plays every queued beat instantly (screen hidden, or the user skips).
    func skipToEnd() {
        if let current = beat { commit(current) }
        while !queue.isEmpty { commit(queue.removeFirst()) }
    }

    private struct Draft {
        var actor: PracticeSide?
        var moveID: String?
        var turn: Int
        var events: [PracticeEvent]
        var timedOut = false
    }
    private enum Phase { case action, residual, confusion }
    /// Damage and heal sources that happen inside a move; every other source is end-of-turn.
    private static let actionCauses: Set<String> = [
        "recoil", "drain", "lifeorb", "rockyhelmet", "roughskin", "ironbarbs", "shellbell", "voltabsorb", "waterabsorb",
    ]
    /// Causes that share a name with a move yet only tick at the end of the turn.
    private static let residualMoveCauses: Set<String> = [
        "leechseed", "wrap", "bind", "firespin", "whirlpool", "sandtomb", "clamp", "magmastorm", "infestation",
        "curse", "nightmare", "sandstorm", "hail",
    ]
    /// A cause equal to the move the open beat is playing (crash damage, Pain Split) is that move's own effect.
    private static func phase(of cause: String?, openMove: String?) -> Phase {
        guard let cause else { return .action }
        let key = cause.filter { !$0.isWhitespace }
        if key == "confusion" { return .confusion }
        if residualMoveCauses.contains(key) { return .residual }
        return actionCauses.contains(key) || key == openMove ? .action : .residual
    }

    private func makeBeat(_ draft: Draft) -> PracticeBeat {
        var state = queued
        var before = queued
        var callouts: [PracticeCallout] = draft.timedOut ? [.timedOut] : []
        for event in draft.events {
            switch event {
            case .damage(let side, let hp, let maxHP, let cause), .heal(let side, let hp, let maxHP, let cause):
                if state[side] == nil {
                    let full = PracticeDisplaySide(hp: maxHP, maxHP: maxHP, status: nil, fainted: false)
                    state[side] = full; before[side] = full
                }
                state[side]?.hp = hp; state[side]?.maxHP = maxHP
                if case .damage = event, cause == "recoil" { callouts.append(.recoil(side)) }
            case .superEffective(let side): callouts.append(.superEffective(side))
            case .resisted(let side): callouts.append(.resisted(side))
            case .immune(let side): callouts.append(.immune(side))
            case .critical(let side): callouts.append(.critical(side))
            case .miss(let side): callouts.append(.miss(side))
            case .failed(let side): callouts.append(.failed(side))
            case .status(let side, let code): state[side]?.status = code; callouts.append(.status(side, code: code))
            case .cureStatus(let side, let code): state[side]?.status = nil; callouts.append(.cureStatus(side, code: code))
            case .boost(let side, let stat, let stages): callouts.append(.boost(side, stat: stat, stages: stages))
            case .cant(let side, let reason): callouts.append(.cant(side, reason: reason))
            case .faint(let side):
                state[side]?.fainted = true; state[side]?.hp = 0; state[side]?.status = nil
                callouts.append(.fainted(side))
            case .weather(let id): callouts.append(.weather(id))
            case .abilityRevealed(let side, let id): callouts.append(.abilityRevealed(side, abilityID: id))
            case .turn, .switchIn, .move, .timedOut, .end: break
            }
        }
        var delta: [PracticeSide: Int] = [:]
        for (side, now) in state { delta[side] = now.percent - (before[side]?.percent ?? now.percent) }
        queued = state
        defer { nextID += 1 }
        return PracticeBeat(id: nextID, turn: draft.turn, actor: draft.actor, moveID: draft.moveID,
                            callouts: callouts, hpDelta: delta, after: state)
    }
    private func startNext() {
        guard beat == nil, !queue.isEmpty else { return }
        let next = queue.removeFirst()
        beat = next
        beatStart = clock()
        beatLength = next.actor == nil ? Self.residualBeat : Self.actionBeat
        beatEnd = beatStart + beatLength * max(0, timeScale)
    }
    private func commit(_ finished: PracticeBeat) {
        display = finished.after
        history.append(finished)
        recent.insert(finished, at: 0)
        if recent.count > 5 { recent.removeLast(recent.count - 5) }
        if beat?.id == finished.id { beat = nil }
    }
}

private extension PracticeSide {
    var foe: PracticeSide { self == .player ? .opponent : .player }
}
