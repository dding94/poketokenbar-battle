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
    var roomProgress: OnlineRoomProgress? { nil }
    var challengeBlock: OnlineActionBlock? { nil }
    var acceptBlock: OnlineActionBlock? { nil }
    var prepareBlock: OnlineActionBlock? { nil }
    /// Nickname of the other side of the open room, if the group list has it.
    var roomOpponentName: String? { nil }
    var selectedOpponentOffline: Bool { false }
    func requestAge(now: Date) -> TimeInterval? { nil }
}
