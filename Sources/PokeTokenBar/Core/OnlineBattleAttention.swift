import Foundation

/// The single definition of "the person must look at this". The menu-bar mark, macOS notifications,
/// the in-app banner and the home subtitle all read these values. Nothing here stores or sends.
enum OnlineAttentionKind: String, Codable, CaseIterable, Sendable {
    case myTurn, challengeAccepted, incomingChallenge, finalConfirmed, rematchRequested, resultReady, matchEnded

    var notifiable: OnlineAttentionNotifiableKind? {
        switch self {
        case .myTurn: .myTurn
        case .challengeAccepted: .challengeAccepted
        case .incomingChallenge: .incomingChallenge
        case .finalConfirmed: .finalConfirmed
        case .rematchRequested, .resultReady, .matchEnded: nil
        }
    }
}

/// The only kinds that may become a macOS notification. Every other kind is in-app only.
enum OnlineAttentionNotifiableKind: String, Sendable { case myTurn, challengeAccepted, incomingChallenge, finalConfirmed }

/// Identity of one occurrence: the same battle and stage is announced once, whatever the revision.
struct OnlineAttentionKey: Codable, Hashable, Sendable {
    let battleId: String
    let stage: String
    init(battleId: String, kind: OnlineAttentionKind, roundSeq: Int) {
        self.battleId = battleId
        stage = kind == .myTurn ? "\(kind.rawValue).\(roundSeq)" : kind.rawValue
    }
    /// Stable, so a re-delivered notification replaces the earlier one and can be withdrawn.
    var notificationIdentifier: String { "online-attention.\(battleId).\(stage)" }
}

struct OnlineAttention: Equatable, Sendable {
    let kind: OnlineAttentionKind
    let battleId: String
    let revision: Int
    let roundSeq: Int
    let opponentName: String?
    /// The turn deadline for myTurn, nil for every other kind.
    let deadline: Date?
    var key: OnlineAttentionKey { .init(battleId: battleId, kind: kind, roundSeq: roundSeq) }
}

/// An attention that is allowed to reach macOS notifications; in-app kinds cannot be turned into one.
struct OnlineAttentionNotice: Equatable, Sendable {
    let kind: OnlineAttentionNotifiableKind
    let attention: OnlineAttention
    init?(_ attention: OnlineAttention) {
        guard let kind = attention.kind.notifiable else { return nil }
        self.kind = kind
        self.attention = attention
    }
}

/// Persisted by the caller so a relaunch does not announce the same occurrence again.
struct OnlineAttentionSeenRecord: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        let key: OnlineAttentionKey
        var revision: Int
    }
    /// Oldest first.
    private(set) var entries: [Entry] = []
    static let capacity = 64
    func contains(_ key: OnlineAttentionKey) -> Bool { entries.contains { $0.key == key } }
}

/// One publish's view of the world, captured from the presentation.
struct OnlineAttentionInput: Sendable {
    let localTrainerID: String?
    let battles: [OnlineBattleView]
    let nicknames: [String: String]
    let displayedRoom: OnlineBattleView?
    let phase: OnlineBattlePresentation.Phase
    let hasResult: Bool
    let choiceSubmitted: Bool
    /// Battles this connection already pressed "ready" for. The server view does not expose it.
    let preparedBattleIDs: Set<String>
    /// Battles whose final staging beats have not played, so win or lose must stay hidden.
    let stagingHeldBattleIDs: Set<String>
    let now: Date

    @MainActor
    init(presentation: OnlineBattlePresentation, preparedBattleIDs: Set<String>, stagingHeldBattleIDs: Set<String>, now: Date) {
        localTrainerID = presentation.account?.trainer.trainerId
        battles = presentation.battles
        nicknames = presentation.members.reduce(into: [:]) { names, member in names[member.trainerId] = member.displayEmail }
        displayedRoom = presentation.room
        phase = presentation.phase
        hasResult = presentation.result != nil
        choiceSubmitted = presentation.choiceSubmitted
        self.preparedBattleIDs = preparedBattleIDs
        self.stagingHeldBattleIDs = stagingHeldBattleIDs
        self.now = now
    }
}

struct OnlineAttentionEvaluation: Equatable, Sendable {
    /// Everything that currently needs attention, highest priority first.
    let active: [OnlineAttention]
    /// Occurrences that were not in the seen record.
    let raised: [OnlineAttention]
    /// The notification-eligible subset of `raised`.
    let notices: [OnlineAttentionNotice]
    /// Occurrences that stopped applying; pending notifications for these should be withdrawn.
    let resolved: [OnlineAttentionKey]
    /// Save this after handling the evaluation.
    let seen: OnlineAttentionSeenRecord
    var current: OnlineAttention? { active.first }
}

enum OnlineAttentionCalculator {
    static func active(_ input: OnlineAttentionInput) -> [OnlineAttention] {
        guard let me = input.localTrainerID else { return [] }
        let live = input.battles
            .sorted { ($0.createdAt, $0.battleId) < ($1.createdAt, $1.battleId) }
            .compactMap { actionable($0, me: me, input: input) }
        let outcome = displayedOutcome(input, me: me).map { [$0] } ?? []
        return (live + outcome).enumerated()
            .sorted { (priority($0.element.kind), $0.offset) < (priority($1.element.kind), $1.offset) }
            .map(\.element)
    }

    static func current(_ input: OnlineAttentionInput) -> OnlineAttention? { active(input).first }

    static func evaluate(_ input: OnlineAttentionInput, seen: OnlineAttentionSeenRecord) -> OnlineAttentionEvaluation {
        let active = active(input)
        let raised = active.filter { !seen.contains($0.key) }
        let listed = Set(input.battles.map(\.battleId))
        let activeKeys = Set(active.map(\.key))
        // A battle missing from the list proves nothing: a relaunch publishes before hello refills it.
        // A finished match cannot return to an earlier stage, so its keys outlive being dismissed.
        let resolved = input.localTrainerID == nil ? [] : seen.entries.map(\.key).filter {
            listed.contains($0.battleId) && !activeKeys.contains($0) && !isOutcome($0)
        }
        return .init(active: active, raised: raised, notices: raised.compactMap(OnlineAttentionNotice.init), resolved: resolved,
                     seen: seen.updated(active: active, removing: Set(resolved)))
    }

    /// Requests and turns come from every live view, so a room that is not selected still reaches the person.
    private static func actionable(_ room: OnlineBattleView, me: String, input: OnlineAttentionInput) -> OnlineAttention? {
        guard let side = room.side(for: me), let kind = actionableKind(room, side: side, input: input) else { return nil }
        return attention(kind, room: room, side: side, input: input,
                         deadline: kind == .myTurn ? room.deadline.map(date) : nil)
    }

    private static func actionableKind(_ room: OnlineBattleView, side: OnlineBattleSide, input: OnlineAttentionInput) -> OnlineAttentionKind? {
        let unexpired = date(room.expiresAt) > input.now
        let unprepared = !input.preparedBattleIDs.contains(room.battleId)
        switch room.state {
        case .pending:
            guard side == .p2, unexpired else { return nil }
            return room.rematchOf == nil ? .incomingChallenge : .rematchRequested
        case .accepted:
            guard unexpired else { return nil }
            if room.confirmed { return unprepared ? .finalConfirmed : nil }
            return side == .p1 ? .challengeAccepted : nil
        case .ready:
            // Readiness is bound to a connection, so a relaunched app has to press it again.
            return unexpired && unprepared ? .finalConfirmed : nil
        case .running:
            guard room.mode == .manual, room.ownChoice == nil, let deadline = room.deadline, date(deadline) > input.now else { return nil }
            let optimisticallyChosen = input.choiceSubmitted && input.displayedRoom?.battleId == room.battleId
            return optimisticallyChosen ? nil : .myTurn
        case .reported, .completed, .declined, .cancelled, .expired, .void:
            return nil
        }
    }

    /// Only the room publish() put on screen may speak about the outcome. The battle list also carries
    /// archive summaries, and a settled room can still be playing its last beats behind the gate.
    private static func displayedOutcome(_ input: OnlineAttentionInput, me: String) -> OnlineAttention? {
        guard let room = input.displayedRoom, let side = room.side(for: me),
              !input.stagingHeldBattleIDs.contains(room.battleId) else { return nil }
        let kind: OnlineAttentionKind
        switch (input.phase, room.state) {
        case (.verifying, .reported): kind = .matchEnded
        case (.result, .completed), (.result, .void): kind = input.hasResult ? .resultReady : .matchEnded
        default: return nil
        }
        return attention(kind, room: room, side: side, input: input, deadline: nil)
    }

    private static func attention(_ kind: OnlineAttentionKind, room: OnlineBattleView, side: OnlineBattleSide,
                                  input: OnlineAttentionInput, deadline: Date?) -> OnlineAttention {
        let opponent = side == .p1 ? room.p2.trainerId : room.p1.trainerId
        return .init(kind: kind, battleId: room.battleId, revision: room.revision, roundSeq: room.roundSeq,
                     opponentName: input.nicknames[opponent], deadline: deadline)
    }

    private static func isOutcome(_ key: OnlineAttentionKey) -> Bool {
        key.stage == OnlineAttentionKind.matchEnded.rawValue || key.stage == OnlineAttentionKind.resultReady.rawValue
    }

    private static func date(_ milliseconds: Double) -> Date { Date(timeIntervalSince1970: milliseconds / 1000) }

    private static func priority(_ kind: OnlineAttentionKind) -> Int {
        switch kind {
        case .myTurn: 0
        case .challengeAccepted: 1
        case .incomingChallenge: 2
        case .finalConfirmed: 3
        case .rematchRequested: 4
        case .resultReady: 5
        case .matchEnded: 6
        }
    }
}

private extension OnlineAttentionSeenRecord {
    /// Records every active occurrence, then evicts the oldest entries that no longer apply.
    func updated(active: [OnlineAttention], removing resolved: Set<OnlineAttentionKey>) -> OnlineAttentionSeenRecord {
        var entries = self.entries.filter { !resolved.contains($0.key) }
        for attention in active {
            if let index = entries.firstIndex(where: { $0.key == attention.key }) {
                entries[index].revision = attention.revision
            } else {
                entries.append(.init(key: attention.key, revision: attention.revision))
            }
        }
        let activeKeys = Set(active.map(\.key))
        var excess = entries.count - Self.capacity
        entries.removeAll { entry in
            guard excess > 0, !activeKeys.contains(entry.key) else { return false }
            excess -= 1
            return true
        }
        var record = self
        record.entries = entries
        return record
    }
}
