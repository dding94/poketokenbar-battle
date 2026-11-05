import Foundation

/// The four consent steps a challenge goes through. The room screen always names the current one.
enum OnlineRoomStep: Int, CaseIterable, Sendable { case request, accept, confirm, ready }

/// Whose move it is at the current step. `none` means both sides are done and the match is starting.
enum OnlineRoomTurn: Equatable, Sendable { case mine, theirs, none }

struct OnlineRoomProgress: Equatable, Sendable {
    let step: OnlineRoomStep
    let turn: OnlineRoomTurn
    /// This app already sent its ready call and the server answered; the button must not repeat it.
    let localReady: Bool
}

/// Why a primary room or lobby button is disabled. Nil means the button is usable.
enum OnlineActionBlock: Equatable, Sendable {
    case busy, noOpponent, noEntry, fainted, held, entryUnavailable, connecting
}

extension OnlineBattlePresentation {
    /// Nil outside the three room states, where no consent step is pending.
    var roomProgress: OnlineRoomProgress? {
        guard let room else { return nil }
        switch room.state {
        case .pending:
            return .init(step: .accept, turn: localSide == .p2 ? .mine : .theirs, localReady: localReady)
        case .accepted where !room.confirmed:
            return .init(step: .confirm, turn: localSide == .p1 ? .mine : .theirs, localReady: localReady)
        case .accepted, .ready:
            // READY on the server means both sides answered; only this app's own flag says whether I did.
            let turn: OnlineRoomTurn = localReady ? (room.state == .ready ? .none : .theirs) : .mine
            return .init(step: .ready, turn: turn, localReady: localReady)
        default:
            return nil
        }
    }

    /// Entry rules shared by the challenge and accept buttons, in the order a person fixes them.
    private var entryBlock: OnlineActionBlock? {
        guard let entry = selectedEntry else { return .noEntry }
        if blockedEntryIDs.contains(entry.id) { return .held }
        if (entryHP[entry.id] ?? 0) <= 0 { return .fainted }
        if entry.snapshot == nil || entry.blockedReason != nil { return .entryUnavailable }
        return nil
    }
    var challengeBlock: OnlineActionBlock? {
        guard !canChallenge, phase == .lobby, !showsHistory, !showsStandings, rematchSourceID == nil else { return nil }
        if isBusy { return .busy }
        guard let opponent = selectedOpponent, opponent.status == .active,
              opponent.trainerId != account?.trainer.trainerId else { return .noOpponent }
        return entryBlock
    }
    var acceptBlock: OnlineActionBlock? {
        guard !canAccept, room?.state == .pending, localSide == .p2 else { return nil }
        return isBusy ? .busy : entryBlock
    }
    var prepareBlock: OnlineActionBlock? {
        guard !canPrepare, !localReady, room?.confirmed == true, [.accepted, .ready].contains(room?.state),
              !showsHistory, !showsStandings, rematchSourceID == nil else { return nil }
        if isBusy { return .busy }
        return canStart ? nil : .connecting
    }
    /// Nickname of the other side of the open room, if the group list has it.
    var roomOpponentName: String? {
        guard let room else { return nil }
        let id = localSide == .p1 ? room.p2.trainerId : room.p1.trainerId
        return members.first { $0.trainerId == id }?.displayEmail
    }
    var selectedOpponentOffline: Bool { selectedOpponent.map { !$0.online } ?? false }
    /// Seconds since the challenge was created (server times are milliseconds).
    func requestAge(now: Date) -> TimeInterval? {
        room.map { max(0, now.timeIntervalSince1970 - $0.createdAt / 1000) }
    }
}
