import Foundation

/// Ways out of a room that is still before the match. The server allows `decline` only for the
/// receiver while PENDING, and `cancel` for either side in PENDING, ACCEPTED and READY.
enum OnlineRoomExit: Equatable, Sendable { case cancelRequest, decline, cancelBattle }

extension OnlineBattlePresentation {
    var roomExits: [OnlineRoomExit] { [] }
    func requestRemaining(now: Date) -> TimeInterval? { nil }
    func announceEnded(_ room: OnlineBattleView, previous: OnlineBattleState?, l: L) {}
    func suppressEndedNotice(for battleID: String) {}
}
