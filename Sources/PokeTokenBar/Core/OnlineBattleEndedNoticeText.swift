import Foundation

extension L {
    func onlineEndedNotice(_ state: OnlineBattleState, opponent: String?, reason: String?) -> String? { nil }
    var onlineDismissNotice: String { "" }
    var onlineCancelBattle: String { "" }
    var onlineVerifyingAuto: String { "" }
    func onlineAwaitingResponse(opponent: String?) -> String { "" }
    func onlineRequestExpiry(remaining: TimeInterval, expiresAt: Date, timeZone: TimeZone = .current) -> String { "" }
}
