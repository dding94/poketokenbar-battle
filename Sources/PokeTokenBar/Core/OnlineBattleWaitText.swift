import Foundation

/// What the arena says about the other side while this app waits for it. Kept out of
/// `OnlineBattleLocalization.swift`, which several online changes edit at once.
extension L {
    var onlineChoiceDone: String { online("선택 완료", "Choice sent") }
    var onlineYourPick: String { online("내가 고른 기술", "Your pick") }
    /// Between rounds: the cards are open, the turn is not yet.
    var onlineRoundOpening: String { online("다음 턴을 여는 중 · 미리 골라도 돼요", "Opening the next turn · you can pick now") }
    /// A move picked between rounds, kept until the round opens.
    var onlineChoiceHeld: String { online("턴이 열리면 바로 보내요", "Sends when the turn opens") }
    /// The kept move cannot be used in the round that opened.
    var onlineHeldChoiceUnusable: String {
        online("골라 둔 기술을 이번 턴에는 쓸 수 없어요. 다시 골라 주세요.", "The move you picked can't be used this turn. Please choose again.")
    }
    /// The round that opened has nothing to pick, so the kept move is gone and there is nothing to choose instead.
    var onlineHeldChoiceForced: String {
        online("이번 턴은 고를 수 없어 골라 둔 기술을 취소했어요.", "This turn has nothing to pick, so your move was cancelled.")
    }
    /// The server already has a different move of mine for this round. The first one stands.
    var onlineErrorChoiceAlreadyIn: String {
        online("이번 턴 기술은 이미 보냈어요. 먼저 보낸 기술로 진행돼요.", "Your move for this turn is already in. The first one you sent stands.")
    }
    func onlineOpponentWait(_ wait: OnlineBattlePresentation.OpponentWait) -> String {
        switch wait {
        case .submitted: online("상대 선택 완료", "Opponent has chosen")
        case .choosing: online("상대가 고르는 중…", "Opponent is choosing…")
        case .offline: online("상대 연결 끊김, 시간 초과 시 자동 선택", "Opponent disconnected, auto-pick if time runs out")
        // The presence behind this one may be old (the socket is down), so it only says "may".
        case .offlineMaybe: online("상대 연결이 끊겼을 수 있어요, 시간 초과 시 자동 선택", "Opponent may be offline, auto-pick if time runs out")
        }
    }
}
