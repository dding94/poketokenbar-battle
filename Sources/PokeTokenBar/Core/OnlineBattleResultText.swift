import Foundation

/// Wording of the online result screen. Every line says only what the settlement receipt recorded.
extension L {
    func onlineResultTitle(_ kind: OnlineBattleUIResult.Kind) -> String {
        switch kind {
        case .win: online("승리", "Victory")
        case .loss: online("패배", "Defeat")
        case .draw: online("무승부", "Draw")
        case .void: online("경기 무효", "Match voided")
        case .record: onlineOtherSaveResultTitle
        }
    }

    /// `turns` is the match's own round count when the server report gives it; nil keeps the line free of a number.
    func onlineResultSubtitle(_ kind: OnlineBattleUIResult.Kind, turns: Int?, foe: String) -> String {
        switch kind {
        case .win:
            if let turns { return practiceWonLine(turns: turns, foe: foe) }
            return online("\(foe)에게 이겼어요", "Beat \(foe)")
        case .loss:
            if let turns { return practiceLostLine(turns: turns, foe: foe) }
            return online("\(foe)에게 졌어요", "Lost to \(foe)")
        case .draw:
            if let turns { return practiceDrawLine(turns: turns) }
            return online("승부가 나지 않았어요", "No winner")
        case .void:
            return online("경기가 무효로 끝났어요. 체력과 경험치는 바뀌지 않았어요.", "The match was voided. HP and XP did not change.")
        case .record:
            return onlineOtherSaveResultDetail
        }
    }

    /// HP and XP lines, in reading order. Empty when there is no receipt behind the result.
    func onlineResultEffectLines(_ result: OnlineBattleUIResult, name: String?) -> [String] {
        guard let effects = result.effects else { return [] }
        var lines: [String] = []
        if effects.xp > 0 { lines.append(onlineXP(effects.xp)) }
        else if result.kind == .win { lines.append(onlineResultNoXP) }
        if effects.fainted { lines.append(onlineResultFainted(name)) }
        else { lines.append(online("남은 체력 \(effects.hpPercent)%를 반영했어요", "\(effects.hpPercent)% HP kept")) }
        return lines
    }

    var onlineResultNoXP: String { online("이번 승리에는 경험치가 없어요", "No XP for this win") }

    func onlineResultFainted(_ name: String?) -> String {
        if lang == .ko {
            let who = name.map { KoreanParticle.subject.attach(to: $0) } ?? "출전한 포켓몬이"
            return "\(who) 기절했어요 · 기력의조각으로 되살릴 수 있어요"
        }
        return "\(name ?? "Your Pokémon") fainted · a Revive brings it back"
    }

    /// "Opponent · Sky · Streak 3 · Record 2W 1L". The streak shows from two wins on; draws show only when there are some.
    func onlineResultOpponentLine(name: String, streak: Int, record: (wins: Int, losses: Int, draws: Int)) -> String {
        var parts = [online("상대 · \(name)", "vs \(name)")]
        if streak >= 2 { parts.append(online("연승 \(streak)", "\(streak)-win streak")) }
        let draws = record.draws > 0 ? online(" \(record.draws)무", " \(record.draws)D") : ""
        parts.append(online("상대 전적 \(record.wins)승 \(record.losses)패", "Record \(record.wins)W \(record.losses)L") + draws)
        return parts.joined(separator: " · ")
    }

    var onlineRematchAgain: String { online("한 번 더 겨루기", "Fight again") }
    func onlineRematchWaitingCancel(_ name: String) -> String {
        online("\(name)님의 응답을 기다려요 · \(cancel)", "Waiting for \(name) · \(cancel)")
    }
    func onlineRematchReceived(_ name: String) -> String { online("\(name)님이 한 번 더 겨루자고 해요", "\(name) wants to fight again") }
    /// Who enters when the request is accepted from the result.
    func onlineRematchAnswerEntry(_ name: String) -> String { online("수락하면 \(name) 출전", "Accepting sends \(name)") }
    var onlineRematchOpenRoom: String { online("재대결 방 열기", "Open the rematch room") }
    var onlineRematchLater: String { online("나중에", "Later") }
    var onlineResultToLobby: String { online("로비로 돌아가기", "Back to lobby") }

    /// One short line under the button, so it stays on one line at the caption size.
    func onlineRematchBlockLine(_ block: OnlineRematchBlock) -> String {
        switch block {
        case .noHealthyPokemon: online("건강한 포켓몬이 없어요 · 기절했다면 되살려요", "No healthy Pokémon · revive fainted ones")
        case .opponentLeft: online("상대가 그룹을 떠났어요", "Your opponent left the group")
        case .requestWaiting: online("상대의 신청이 기다리고 있어요 · 로비에서 답해요", "Their request is waiting · answer in the lobby")
        }
    }
    var onlineRematchOpponentOffline: String {
        online("상대가 오프라인이에요 · 돌아오면 신청이 보여요", "They are offline · they will see it when back")
    }
}
