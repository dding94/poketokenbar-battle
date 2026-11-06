import Foundation

/// One line of the battle log, kept typed and worded when it is read (`PracticeEvent` does the same for staging). The
/// app language is therefore no input of the battle: it can change while one runs and never reaches the engine.
enum PracticeLogEntry {
    case opening(hasStakes: Bool)
    case timedOut
    case engine(String)
    case abilityRevealed(name: String, ability: String)
}

/// What the battle board says in place of its prompt, worded when it is read, like the log.
enum PracticeNotice {
    case moveUnavailable
    case failure(Error)

    func text(_ l: L) -> String {
        switch self {
        case .moveUnavailable: return l.practiceMoveUnavailable
        case .failure(let error): return PracticeText.failure(error, l: l)
        }
    }
}

/// Words engine output and failures in the app language (`L`), keeping an engine identifier that has no wording.
enum PracticeText {
    static func failure(_ error: Error, l: L) -> String {
        switch error {
        case BattleSnapshot.Failure.missingProfile: return l.practiceFailureProfile
        case BattleSnapshot.Failure.missingNature: return l.practiceFailureNature
        case BattleSnapshot.Failure.missingGender: return l.practiceFailureGender
        case BattleSnapshot.Failure.missingAbility: return l.practiceFailureAbility
        case BattleSnapshot.Failure.missingMoves: return l.practiceFailureMoves
        case BattleEngine.Failure.engine(let code):
            return code == "same_individual" ? l.practiceFailureSameIndividual : l.practiceFailureEngine(code)
        case BattleEngine.Failure.missingBundle: return l.practiceFailureMissingBundle
        case BattleEngine.Failure.checksumMismatch: return l.practiceFailureChecksum
        default: return l.practiceFailureUnknown
        }
    }
    static func line(_ entry: PracticeLogEntry, names: [String: String], l: L) -> String? {
        switch entry {
        case .opening(let hasStakes): return l.practiceLogOpening(hasStakes: hasStakes)
        case .timedOut: return l.practiceLogTimedOut
        case .engine(let line): return log(line, names: names, l: l)
        case .abilityRevealed(let name, let ability): return l.practiceLogAbilityRevealed(name, ability)
        }
    }
    static func log(_ line: String, names: [String: String], l: L) -> String? {
        let p = line.components(separatedBy: "|")
        guard p.count > 2 else { return nil }
        let actor = names[String(p[2].prefix(2))] ?? p[2]
        let detail = p.count > 3 ? p[3] : ""
        switch p[1] {
        case "turn": return l.practiceLogTurn(p[2])
        case "move": return l.practiceLogMove(actor, detail)
        case "-damage": return l.practiceLogDamage(actor, detail)
        case "-heal": return l.practiceLogHeal(actor, detail)
        case "-miss": return l.practiceLogMiss(actor)
        case "-immune": return l.practiceLogImmune(actor)
        case "-fail": return l.practiceLogFail(actor)
        case "-status": return l.practiceLogStatus(actor, detail)
        case "-curestatus": return l.practiceLogCured(actor)
        case "cant": return l.practiceLogCant(actor, detail)
        case "-boost", "-unboost": return l.practiceLogStat(actor, detail, raised: p[1] == "-boost")
        case "-supereffective": return l.practiceLogSuperEffective
        case "-resisted": return l.practiceLogResisted
        case "-crit": return l.practiceLogCritical
        case "faint": return l.practiceLogFaint(actor)
        case "win": return l.practiceLogWin(names[p[2]] ?? p[2])
        case "tie": return l.practiceLogTie
        case "-weather": return l.practiceLogWeather(p[2])
        case "-start", "-end", "-activate": return l.practiceLogEffect(actor, detail, ended: p[1] == "-end")
        default:
            return p[1].hasPrefix("-") ? "\(l.practiceLog) · \(p.dropFirst(2).joined(separator: " · "))" : nil
        }
    }
}
