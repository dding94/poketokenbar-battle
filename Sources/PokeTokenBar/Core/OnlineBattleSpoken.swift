import Foundation

/// What VoiceOver says in the online arena, computed from plain values so a test can read it when the render
/// environment gives no accessibility tree. The views only hand these results to their accessibility modifiers.
/// Every value comes from what the screen draws (the staged display, never the engine's view ahead of it) and the
/// opponent's side is only ever the public percent: a label never says more than the picture does.
enum OnlineBattleSpoken {
    struct Card: Equatable {
        let label: String
        let value: String
    }

    /// A move, ability or type name as the screen shows it: the loaded translation, else the readable identifier.
    static func name(_ kind: PokemonNameResource.Kind, slug: String, l: L, artwork: Bool,
                     names: [PokemonNameResource: [String: String]]) -> String {
        let fallback = PokemonNameLocalization.identifier(slug)
        guard artwork, let translations = names[PokemonNameResource(kind: kind, name: slug)] else { return fallback }
        return l.lang.resolveName(translations) ?? fallback
    }

    static func moveLabel(l: L, slot: Int, name: String) -> String {
        l.online("기술 \(slot): \(name)", "Move \(slot): \(name)")
    }

    /// Type, PP (a forced move has none), then the hint's own words. A picked card says so first.
    static func moveValue(l: L, typeName: String, pp: Int, maxPP: Int, special: Bool, details: String, chosen: Bool) -> String {
        var parts: [String] = []
        if chosen { parts.append(l.onlineYourPick) }
        if !typeName.isEmpty { parts.append(typeName) }
        if !special { parts.append("PP \(pp)/\(maxPP)") }
        if !details.isEmpty { parts.append(details) }
        return parts.joined(separator: l.practiceSeparator)
    }

    /// `display` is what the card draws now. The opponent's value is the public percent and nothing finer.
    static func card(l: L, own: Bool, name: String, level: Int, nickname: String?, display: PracticeDisplaySide) -> Card {
        let label: String
        if own {
            label = l.online("내 포켓몬 \(name), 레벨 \(level)", "Your Pokémon, \(name), level \(level)")
        } else if let nickname, !nickname.isEmpty {
            label = l.online("상대 \(nickname)의 \(name), 레벨 \(level)", "\(nickname)'s \(name), level \(level)")
        } else {
            label = l.online("상대 포켓몬 \(name), 레벨 \(level)", "Opposing Pokémon, \(name), level \(level)")
        }
        guard !display.fainted else { return Card(label: label, value: l.online("기절", "Fainted")) }
        var parts = [l.online("체력 \(display.percent)%", "HP \(display.percent)%")]
        if own { parts.append("\(display.hp)/\(display.maxHP)") }
        if let status = display.status, !status.isEmpty { parts.append(l.practiceStatusName(status)) }
        return Card(label: label, value: parts.joined(separator: l.practiceSeparator))
    }

    /// The turn bar: the turn and the seconds. A bar with no deadline is "preparing", never zero seconds.
    static func clock(l: L, state: OnlineBattleTurnClock.State, turn: Int) -> String {
        switch state {
        case .idle:
            return l.practiceTurn(turn)
        case .preparing:
            return l.online("\(turn)턴, 다음 턴 준비 중", "Turn \(turn), preparing the next turn")
        case .counting(let remaining, _, let mine):
            var parts = [l.practiceTurn(turn)]
            if !mine { parts.append(l.online("상대 선택을 기다리는 중", "Waiting for the opponent")) }
            parts.append(l.online("남은 시간 \(remaining)초", "\(remaining) seconds left"))
            if state.isUrgent { parts.append(l.online("시간 초과 시 자동 선택", "Auto-pick when time runs out")) }
            return parts.joined(separator: ", ")
        }
    }

    /// Said when a turn opens for my choice. Seconds only when the server's deadline has some left.
    static func turnStart(l: L, turn: Int, remaining: Int?) -> String {
        var line = l.online("\(turn)턴 시작, 기술을 고르세요", "Turn \(turn) started, choose a move")
        if let remaining, remaining > 0 { line += l.online(", 남은 시간 \(remaining)초", ", \(remaining) seconds left") }
        return line
    }

    static func result(l: L, title: String, subtitle: String) -> String {
        let head = l.online("대전 결과: ", "Battle result: ") + title
        return subtitle.isEmpty ? head : head + ". " + subtitle
    }
}

/// Which announcements were already made. It lives with the presentation model, which outlives the popover's views,
/// so closing and reopening the popover never says the same turn twice.
struct OnlineBattleAnnouncementLedger: Equatable {
    private var turnKey: String?
    private var resultID: String?

    /// True once per battle and turn, and only for a picker that is open, a display that has caught up with the
    /// engine and a screen the person can see. A refusal consumes nothing, so the turn is still due when it is seen.
    mutating func claimTurn(battleID: String, turn: Int, shown: Bool, open: Bool, playing: Bool) -> Bool {
        guard shown, open, !playing else { return false }
        let key = "\(battleID)#\(turn)"
        guard key != turnKey else { return false }
        turnKey = key
        return true
    }

    /// True once per battle, only on a visible screen and never while a beat is still on its way.
    mutating func claimResult(battleID: String, shown: Bool, playing: Bool) -> Bool {
        guard shown, !playing, battleID != resultID else { return false }
        resultID = battleID
        return true
    }
}
