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
              let me = account?.trainer.trainerId, room.side(for: me) != nil,
              endedNoticeIDs.insert(room.battleId).inserted else { return }
        showEndedNotice(room, me: me, l: l)
    }

    private func showEndedNotice(_ room: OnlineBattleView, me: String, l: L) {
        let otherID = room.side(for: me) == .p1 ? room.p2.trainerId : room.p1.trainerId
        let name = members.first { $0.trainerId == otherID }?.displayEmail
        guard let text = l.onlineEndedNotice(room.state, opponent: name, reason: room.reason) else { return }
        notice = text
        stickyNotice = text
        stickyNoticeBattleID = room.battleId
    }

    /// This app ended the room itself (cancel or decline): it must not be announced back to the person who pressed it.
    func suppressEndedNotice(for battleID: String) {
        endedNoticeIDs.insert(battleID)
        ownEndedBattleIDs.insert(battleID)
    }
    /// The server refused that cancel or decline, so the room did not end by this app's hand.
    func allowEndedNotice(for battleID: String) {
        endedNoticeIDs.remove(battleID)
        ownEndedBattleIDs.remove(battleID)
    }

    /// The notifier's list of unread endings, minus whatever the view took in the meantime. `read` were on the open lobby.
    func syncEnded(unread: Set<String>, read: [String], l: L) {
        for id in read { acknowledgeEnded(id, l: l) }
        let next = unread.subtracting(acknowledgedEndedBattleIDs)
        if next != unreadEndedBattleIDs { unreadEndedBattleIDs = next }
    }

    /// The person reached the ending. After a relaunch the session never saw the room change, so the lobby's notice
    /// is raised here; one already told in this run is not repeated.
    func acknowledgeEnded(_ battleID: String, l: L) {
        acknowledgedEndedBattleIDs.insert(battleID)
        unreadEndedBattleIDs.remove(battleID)
        guard let me = account?.trainer.trainerId, let room = battles.first(where: { $0.battleId == battleID }),
              endedNoticeIDs.insert(battleID).inserted else { return }
        showEndedNotice(room, me: me, l: l)
    }

    /// Closing the banner reads the ending, so the same words do not wait on the lobby. No words are needed here.
    func dismissEnded(_ battleID: String) {
        acknowledgedEndedBattleIDs.insert(battleID)
        unreadEndedBattleIDs.remove(battleID)
        endedNoticeIDs.insert(battleID)
        if stickyNoticeBattleID == battleID, noticeSurvivesRefresh { notice = nil; stickyNotice = nil }
    }
}
