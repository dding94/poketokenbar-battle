import Foundation

/// How my finished games against one opponent ended.
struct OnlineBattleRecord: Equatable, Sendable {
    var wins = 0
    var losses = 0
    var draws = 0
    var isEmpty: Bool { wins + losses + draws == 0 }
}

/// What the arena says about the person on the other side. Only values the server already gave the app are used:
/// the member list's nickname, the finished games in the battles list and, when the standings were loaded, the
/// streak. A value that is not there stays out, so the card never shows a made-up line.
extension OnlineBattlePresentation {
    /// The trainer in the other seat of the room on screen.
    var opponentTrainerID: String? {
        guard let room else { return nil }
        return localSide == .p1 ? room.p2.trainerId : room.p1.trainerId
    }

    var opponentNickname: String? {
        guard let id = opponentTrainerID,
              let name = members.first(where: { $0.trainerId == id })?.displayEmail, !name.isEmpty else { return nil }
        return name
    }

    /// Finished games with a result between me and this opponent, counted from my seat. A game still running, one
    /// that ended without a result (void, declined, expired) and games against anybody else are not counted.
    var opponentRecord: OnlineBattleRecord {
        guard let room, let foe = opponentTrainerID else { return OnlineBattleRecord() }
        let me = localSide == .p1 ? room.p1.trainerId : room.p2.trainerId
        var record = OnlineBattleRecord()
        for battle in battles where battle.state == .completed {
            guard let winner = battle.result?.winner, let seat = battle.side(for: me),
                  battle.side(for: foe) != nil, seat != battle.side(for: foe) else { continue }
            if winner == .draw { record.draws += 1 } else if winner.rawValue == seat.rawValue { record.wins += 1 } else { record.losses += 1 }
        }
        return record
    }

    /// The opponent's current win streak from the standings, only while those are loaded and only when it is a streak.
    var opponentStreak: Int? {
        guard let id = opponentTrainerID, let streak = standings?.rows.first(where: { $0.trainerId == id })?.streak,
              streak >= 2 else { return nil }
        return streak
    }
}
