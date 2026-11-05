import Foundation

/// The words of the turn bar, the opening splash and the foe card's line. Kept out of `OnlineBattleLocalization.swift`,
/// which several online changes edit at once.
extension L {
    /// The header's right side: the turn, then the seconds. Only the person choosing is told about the auto-pick.
    func onlineClockText(_ state: OnlineBattleTurnClock.State, turn: Int) -> String {
        switch state {
        case .idle: online("\(turn)턴", "Turn \(turn)")
        case .preparing: online("\(turn)턴 · 다음 턴 준비 중", "Turn \(turn) · Preparing")
        case .counting(let remaining, _, let mine):
            mine && state.isUrgent
                ? online("\(turn)턴 · \(remaining)초 · 시간 초과 시 자동 선택", "Turn \(turn) · \(remaining)s · Auto-pick on timeout")
                : onlineTurn(turn, seconds: remaining)
        }
    }

    /// Under the VS mark; nothing without a name, so the splash never invents one.
    func onlineSplashLine(_ nickname: String?) -> String? {
        guard let nickname, !nickname.isEmpty else { return nil }
        return online("\(nickname)님과 대전 시작!", "Battle with \(nickname)")
    }
    var onlineSplashSkip: String { online("건너뛰기", "Skip") }

    /// "상대 · 닉네임"; without a nickname the plain label of the card.
    func onlineFoeLabel(nickname: String?) -> String {
        guard let nickname, !nickname.isEmpty else { return practiceFoe }
        return "\(practiceFoe) · \(nickname)"
    }

    /// "연승 3 · 상대 전적 2승 1패", whichever parts there are; nil when there are none.
    func onlineOpponentLine(record: OnlineBattleRecord, streak: Int?) -> String? {
        var parts: [String] = []
        if let streak { parts.append(online("연승 \(streak)", "\(streak)-win streak")) }
        if !record.isEmpty {
            let draws = record.draws > 0
            parts.append(online("상대 전적 \(record.wins)승\(draws ? " \(record.draws)무" : "") \(record.losses)패",
                                "vs them \(record.wins)W\(draws ? " \(record.draws)D" : "") \(record.losses)L"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
