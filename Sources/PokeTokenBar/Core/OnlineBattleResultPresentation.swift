import Foundation

/// What a settled battle did to this save, exactly as the settlement receipt recorded it.
struct OnlineBattleResultEffects: Equatable, Sendable {
    /// The Pokémon that fought here, so the wording can name it.
    let instanceID: String
    /// Experience the receipt granted; 0 when none was paid.
    let xp: Int64
    /// The share of its HP the Pokémon kept. 0 means it fainted.
    let hpShare: Double
    var fainted: Bool { hpShare <= 0 }
    /// Whole percent of HP kept; 1 at least while it still stands.
    var hpPercent: Int { fainted ? 0 : max(1, Int((min(1, hpShare) * 100).rounded(.down))) }
}

/// The result screen's data. Wording lives in `L`; nothing here is a display string.
struct OnlineBattleUIResult: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case win, loss, draw
        /// The server voided the match: nothing was applied.
        case void
        /// Fought with a Pokémon this save does not have. No receipt exists, so no effect is claimed.
        case record
    }
    let kind: Kind
    /// nil unless a receipt exists. Without one the screen says nothing about HP or XP of a settled battle.
    let effects: OnlineBattleResultEffects?
    var isVoid: Bool { kind == .void }
}

/// What the finished room's rematch looks like from this seat.
enum OnlineRematchOffer: Equatable {
    /// I asked and the other seat has not answered yet.
    case sent(OnlineBattleView)
    /// The other seat asked and I have not answered yet.
    case received(OnlineBattleView)
    /// The rematch room moved on (accepted, ready, running): it is a room to open, not a request to answer.
    case underway(OnlineBattleView)
    var room: OnlineBattleView {
        switch self {
        case .sent(let room), .received(let room), .underway(let room): room
        }
    }
}

/// Why the result screen's rematch button is off. Said in one line below it.
enum OnlineRematchBlock: Equatable {
    case noHealthyPokemon, opponentLeft
    /// A healthy Pokémon exists, but another request or match of mine holds it.
    case entryHeld
    /// The other seat's request is waiting and was put off; asking again would cross it.
    case requestWaiting
}

/// Everything the result screen shows, decided here so a test can read it and the view only draws it.
struct OnlineBattleResultScreen: Equatable {
    struct Totals: Equatable { let turns: Int; let dealtPercent: Int; let takenPercent: Int }
    enum Rematch: Equatable {
        /// Nothing to offer: a voided match, a record from another save, or a room this person did not fight in.
        case none
        /// "Fight again". Off when `OnlineRematchBlock` or a busy moment says so.
        case request(enabled: Bool)
        /// "Waiting for Sky · Cancel": cancels the rematch room, not the result.
        case waiting(label: String, battleID: String)
        /// The other seat's request, answered here.
        case answer(banner: String, battleID: String)
        /// The rematch is already a room: open it.
        case open(battleID: String)
    }
    let title: String
    let subtitle: String
    let opponent: String
    let effects: [String]
    let totals: Totals?
    let rematch: Rematch
    /// One line under the controls: why the button is off, or a hint that does not turn it off.
    let note: String?
    /// The finished room's id, which "Fight again" is about.
    let sourceID: String?
    /// My own request when it crossed theirs: the room the extra "cancel mine" button ends.
    var cancelOwnRequest: String? = nil

    /// What the main control sends: ask again, cancel the request, answer theirs, or open the room. Each names the room
    /// it is about. nil when there is no control.
    var primaryAction: OnlineBattleUIAction? {
        switch rematch {
        case .none: nil
        case .request: sourceID.map { .prepareRematch($0) }
        case .waiting(_, let id): .cancel(id)
        case .answer(_, let id): .accept(id)
        case .open(let id): .followAttention(id)
        }
    }
    /// "Later" on a request shown over the result.
    var secondaryAction: OnlineBattleUIAction? {
        if case .answer(_, let id) = rematch { return .deferRematch(id) }
        return nil
    }
    /// Off only for a rematch the person cannot ask for; accepting is gated where the Pokémon is known.
    var primaryEnabled: Bool {
        if case .request(let enabled) = rematch { return enabled }
        return true
    }
}

extension OnlineBattlePresentation {
    private var localTrainerID: String? { account?.trainer.trainerId }

    private func opponentID(in battle: OnlineBattleView) -> String? {
        guard let side = localTrainerID.flatMap({ battle.side(for: $0) }) else { return nil }
        return side == .p1 ? battle.p2.trainerId : battle.p1.trainerId
    }

    /// What this seat's finished battle came to, from the server's own report.
    private func outcome(of battle: OnlineBattleView) -> OnlineBattleOutcome? {
        guard battle.state == .completed, let me = localTrainerID, let side = battle.side(for: me), let winner = battle.result?.winner else { return nil }
        if winner == .draw { return .draw }
        return winner.rawValue == side.rawValue ? .win : .loss
    }

    /// The open room that follows `source` as a rematch, newest first. A request still waiting is sent or received
    /// by who made it; one that moved on is a room to open.
    /// Requests can cross when both seats ask at once. Then theirs is the one to answer, whichever came last.
    func rematchOffer(for source: OnlineBattleView) -> OnlineRematchOffer? {
        guard let me = localTrainerID else { return nil }
        let open = openRematches(of: source, me: me)
        if let moved = open.first(where: { $0.state != .pending }) { return .underway(moved) }
        if let asked = open.first(where: { $0.p1.trainerId != me }) { return .received(asked) }
        return open.first.map { .sent($0) }
    }

    private func openRematches(of source: OnlineBattleView, me: String) -> [OnlineBattleView] {
        battles.filter { $0.rematchOf == source.battleId && $0.state.isActive && $0.side(for: me) != nil }
            .sorted { ($0.createdAt, $0.battleId) > ($1.createdAt, $1.battleId) }
    }

    /// My own request when the other seat's is waiting too. It may be what holds the Pokémon their request needs.
    func crossedRematch(for source: OnlineBattleView) -> OnlineBattleView? {
        guard let me = localTrainerID, case .received? = rematchOffer(for: source) else { return nil }
        return openRematches(of: source, me: me).first { $0.state == .pending && $0.p1.trainerId == me }
    }

    /// The room a room action may name: the one on screen, or while it is a finished room, its open rematch.
    /// Nothing else, so a press never reaches a room the person was not looking at.
    func actionRoom(_ id: String) -> OnlineBattleView? {
        guard let room else { return nil }
        if room.battleId == id { return room }
        guard room.state == .completed, let me = localTrainerID else { return nil }
        return openRematches(of: room, me: me).first { $0.battleId == id }
    }

    /// Who enters when a rematch request is accepted from the result: the selected Pokémon if it can fight, else the
    /// first that can. The result names it next to the button, so the choice is never silent.
    var answerEntry: PracticeCandidate? {
        if let selectedEntry, entryIsEligible(selectedEntry) { return selectedEntry }
        return roster.first(where: entryIsEligible)
    }

    /// Which seat this person has in `target`. The shown room's side is the published one.
    func side(in target: OnlineBattleView) -> OnlineBattleSide {
        if target.battleId == room?.battleId { return localSide }
        return localTrainerID.flatMap { target.side(for: $0) } ?? .p1
    }

    func rematchBlock(for source: OnlineBattleView) -> OnlineRematchBlock? {
        guard !isBusy, !showsStandings, source.state == .completed, let target = opponentID(in: source) else { return nil }
        if case .received(let asked)? = rematchOffer(for: source), deferredRematchIDs.contains(asked.battleId) { return .requestWaiting }
        guard members.contains(where: { $0.trainerId == target && $0.status == .active }) else { return .opponentLeft }
        guard roster.contains(where: entryIsEligible) else { return unavailableEntryBlock }
        return nil
    }

    /// Nobody can enter. A Pokémon that is well and only held elsewhere is not a health problem.
    private var unavailableEntryBlock: OnlineRematchBlock {
        let held = roster.contains { $0.snapshot != nil && $0.blockedReason == nil && (entryHP[$0.id] ?? 0) > 0 && blockedEntryIDs.contains($0.id) }
        return held ? .entryHeld : .noHealthyPokemon
    }

    /// True when the opponent is an active member who is not connected now: the request still reaches them.
    func rematchOpponentOffline(for source: OnlineBattleView) -> Bool {
        guard let target = opponentID(in: source) else { return false }
        return members.contains { $0.trainerId == target && $0.status == .active && !$0.online }
    }

    /// Wins and losses against one member among the completed battles.
    func headToHead(against trainerID: String) -> OnlineBattleRecord {
        var record = OnlineBattleRecord()
        for battle in battles where opponentID(in: battle) == trainerID {
            switch outcome(of: battle) {
            case .win?: record.wins += 1
            case .loss?: record.losses += 1
            case .draw?: record.draws += 1
            case nil: break
            }
        }
        return record
    }

    /// Wins in a row ending at `source`, counting completed battles only: a draw or a loss ends the run, a voided
    /// match is not in it at all.
    func winStreak(through source: OnlineBattleView) -> Int {
        let upTo = battles
            .filter { outcome(of: $0) != nil && ($0.createdAt, $0.battleId) <= (source.createdAt, source.battleId) }
            .sorted { ($0.createdAt, $0.battleId) > ($1.createdAt, $1.battleId) }
        var streak = 0
        for battle in upTo {
            guard outcome(of: battle) == .win else { break }
            streak += 1
        }
        return streak
    }

    /// The staged totals of the shown room. A round that never reached the screen (a rebuilt log stages none, and
    /// a closed popover skips the beats) would make them short, so the last staged turn has to reach the final one.
    func resultSummary() -> PracticeSummary? {
        guard let stage, let room, room.state == .completed else { return nil }
        let finalTurn = room.result?.terminalSeq ?? room.roundSeq
        guard let last = stage.playback.history.last, last.turn >= finalTurn else { return nil }
        return stage.playback.summary
    }

    func resultScreen(l: L) -> OnlineBattleResultScreen? {
        guard let room else { return nil }
        let side = localTrainerID.flatMap { room.side(for: $0) }
        let foeID = opponentID(in: room)
        let foeName = members.first { $0.trainerId == foeID }?.displayEmail ?? l.onlineAnonymous
        let kind = result?.kind
        let played = kind == .win || kind == .loss || kind == .draw
        let totals = played ? resultSummary().map { OnlineBattleResultScreen.Totals(turns: $0.turns, dealtPercent: $0.damageDealtPercent, takenPercent: $0.damageTakenPercent) } : nil
        let turns = played ? room.result?.terminalSeq : nil
        let ownName = result?.effects.flatMap { effects in roster.first { $0.id == effects.instanceID }?.name }
        let opponent = foeID.map {
            l.onlineResultOpponentLine(name: foeName, streak: kind == .win ? winStreak(through: room) : 0, record: headToHead(against: $0))
        } ?? ""

        var rematch = OnlineBattleResultScreen.Rematch.none
        var note: String?
        var cancelOwnRequest: String?
        if room.state == .completed, side != nil {
            switch rematchOffer(for: room) {
            case .sent(let sent)?:
                rematch = .waiting(label: l.onlineRematchWaitingCancel(foeName), battleID: sent.battleId)
            case .received(let asked)? where !deferredRematchIDs.contains(asked.battleId):
                rematch = .answer(banner: l.onlineRematchReceived(foeName), battleID: asked.battleId)
                let crossed = crossedRematch(for: room)
                cancelOwnRequest = crossed?.battleId
                note = answerEntry.map { l.onlineRematchAnswerEntry($0.name) }
                    ?? (crossed != nil ? l.onlineRematchCrossedNote : l.onlineRematchBlockLine(unavailableEntryBlock))
            case .received? where crossedRematch(for: room) != nil:
                // Theirs was put off; mine is what is left to wait on, and it stays cancelable.
                if let mine = crossedRematch(for: room) { rematch = .waiting(label: l.onlineRematchWaitingCancel(foeName), battleID: mine.battleId) }
            case .underway(let moved)?:
                rematch = .open(battleID: moved.battleId)
            case .received?, nil:
                let block = rematchBlock(for: room)
                // Their request is still open: asking back would cross it, so the button waits for that answer.
                rematch = .request(enabled: block != .requestWaiting && canRematch(room))
                if let block { note = l.onlineRematchBlockLine(block) }
                else if rematchOpponentOffline(for: room) { note = l.onlineRematchOpponentOffline }
            }
        }
        return OnlineBattleResultScreen(
            title: result.map { l.onlineResultTitle($0.kind) } ?? l.onlineResult,
            subtitle: result.map { l.onlineResultSubtitle($0.kind, turns: turns, foe: foeName) } ?? "",
            opponent: opponent,
            effects: result.map { l.onlineResultEffectLines($0, name: ownName) } ?? [],
            totals: totals, rematch: rematch, note: note, sourceID: room.battleId, cancelOwnRequest: cancelOwnRequest)
    }
}
