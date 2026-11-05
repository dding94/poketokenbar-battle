import Foundation

/// Wording of the online result screen. Every line says only what the settlement receipt recorded.
extension L {
    func onlineResultTitle(_ kind: OnlineBattleUIResult.Kind) -> String { "" }
    func onlineResultSubtitle(_ kind: OnlineBattleUIResult.Kind, turns: Int?, foe: String) -> String { "" }
    /// HP and XP lines, in reading order. Empty when there is no receipt behind the result.
    func onlineResultEffectLines(_ result: OnlineBattleUIResult, name: String?) -> [String] { [] }
    func onlineResultOpponentLine(name: String, streak: Int, record: (wins: Int, losses: Int, draws: Int)) -> String { "" }
    var onlineRematchAgain: String { "" }
    func onlineRematchWaitingCancel(_ name: String) -> String { "" }
    func onlineRematchReceived(_ name: String) -> String { "" }
    var onlineRematchOpenRoom: String { "" }
    var onlineResultNoXP: String { "" }
    var onlineRematchLater: String { "" }
    var onlineResultToLobby: String { "" }
    func onlineRematchBlockLine(_ block: OnlineRematchBlock) -> String { "" }
    var onlineRematchOpponentOffline: String { "" }
}
