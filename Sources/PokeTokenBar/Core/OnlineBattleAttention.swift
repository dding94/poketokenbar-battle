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
    static func active(_ input: OnlineAttentionInput) -> [OnlineAttention] { [] }
    static func current(_ input: OnlineAttentionInput) -> OnlineAttention? { active(input).first }
    static func evaluate(_ input: OnlineAttentionInput, seen: OnlineAttentionSeenRecord) -> OnlineAttentionEvaluation {
        .init(active: [], raised: [], notices: [], resolved: [], seen: seen)
    }
}
