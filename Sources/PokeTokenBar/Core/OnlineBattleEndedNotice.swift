import Foundation

/// Ways out of a room that is still before the match. The server allows `decline` only for the
/// receiver while PENDING, and `cancel` for either side in PENDING, ACCEPTED and READY.
enum OnlineRoomExit: Equatable, Sendable { case cancelRequest, decline, cancelBattle }

extension OnlineBattlePresentation {
    private static let beforeMatch: [OnlineBattleState] = [.pending, .accepted, .ready]
    private static let endedBeforeMatch: [OnlineBattleState] = [.declined, .cancelled, .expired]

    /// The challenger made the request, so only they see "cancel request". The receiver declines
    /// while it is pending; after accepting, decline is no longer allowed and cancel is their way out.
    var roomExits: [OnlineRoomExit] {
        guard let room else { return [] }
        switch (room.state, localSide) {
        case (.pending, .p1), (.accepted, .p1), (.ready, .p1): return [.cancelRequest]
        case (.pending, .p2): return [.decline]
        case (.accepted, .p2), (.ready, .p2): return [.cancelBattle]
        default: return []
        }
    }

    /// Seconds until the server drops this room (server times are milliseconds). Negative when the
    /// time passed but the server has not yet marked the room expired.
    func requestRemaining(now: Date) -> TimeInterval? {
        guard let room, Self.beforeMatch.contains(room.state) else { return nil }
        return room.expiresAt / 1000 - now.timeIntervalSince1970
    }

    /// Called when a room this app was already tracking ends before the match. Only an ending seen
    /// live is announced, so loading old history never raises a notice, and each battle only once.
    func announceEnded(_ room: OnlineBattleView, previous: OnlineBattleState?, l: L) {
        guard let previous, Self.beforeMatch.contains(previous), Self.endedBeforeMatch.contains(room.state),
              let me = account?.trainer.trainerId, let side = room.side(for: me),
              endedNoticeIDs.insert(room.battleId).inserted else { return }
        let otherID = side == .p1 ? room.p2.trainerId : room.p1.trainerId
        let name = members.first { $0.trainerId == otherID }?.displayEmail
        guard let text = l.onlineEndedNotice(room.state, opponent: name, reason: room.reason) else { return }
        notice = text
        stickyNotice = text
    }

    /// This app ended the room itself (cancel or decline): it must not be announced back to the person who pressed it.
    func suppressEndedNotice(for battleID: String) { endedNoticeIDs.insert(battleID) }
}
