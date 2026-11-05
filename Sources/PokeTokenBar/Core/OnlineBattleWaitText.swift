import Foundation

/// What the arena says about the other side while this app waits for it. Kept out of
/// `OnlineBattleLocalization.swift`, which several online changes edit at once.
extension L {
    var onlineChoiceDone: String { online("선택 완료", "Choice sent") }
    var onlineYourPick: String { online("내가 고른 기술", "Your pick") }
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
