import Foundation

/// The single definition of "the person must look at this". The menu-bar mark, macOS notifications,
/// the in-app banner and the home subtitle all read these values. Nothing here stores or sends.
enum OnlineAttentionKind: String, Codable, CaseIterable, Sendable {
    case myTurn, challengeAccepted, incomingChallenge, finalConfirmed, rematchRequested, requestEnded, resultReady, matchEnded

    var notifiable: OnlineAttentionNotifiableKind? {
        switch self {
        case .myTurn: .myTurn
        case .challengeAccepted: .challengeAccepted
        case .incomingChallenge: .incomingChallenge
        case .finalConfirmed: .finalConfirmed
        case .rematchRequested: .rematchRequested
        case .requestEnded: .requestEnded
        case .resultReady, .matchEnded: nil
        }
    }
}

/// The only kinds that may become a macOS notification. Every other kind is in-app only.
enum OnlineAttentionNotifiableKind: String, Sendable { case myTurn, challengeAccepted, incomingChallenge, finalConfirmed, rematchRequested, requestEnded }

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
    /// How the room ended, for requestEnded only.
    var ending: OnlineAttentionEnding? = nil
    var key: OnlineAttentionKey { .init(battleId: battleId, kind: kind, roundSeq: roundSeq) }
}

/// Why a room this person was waiting on ended before the match.
struct OnlineAttentionEnding: Equatable, Sendable {
    let state: OnlineBattleState
    let reason: String?
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

/// Rooms this person already took a step in, and endings of those rooms they have not read yet.
/// Persisted with the seen record, so a relaunch can tell "ended while I was away" from old history.
/// Battle ids and revisions only.
struct OnlineAttentionWaitRecord: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        let battleId: String
        var revision: Int
    }
    /// Oldest first.
    var waiting: [Entry] = []
    /// Oldest first.
    var unreadEnded: [Entry] = []
    static let capacity = 64
    var unreadIDs: Set<String> { Set(unreadEnded.map(\.battleId)) }
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
    /// Running battles whose open round has nothing to pick: a forced action such as a recharge.
    let noChoiceBattleIDs: Set<String>
    /// Rooms this app ended itself (cancel, decline, a withdrawn consent). Never announced back.
    let ownEndedBattleIDs: Set<String>
    /// Endings the person already read; monotonic, so a stale input can never bring one back.
    let acknowledgedEndedBattleIDs: Set<String>
    /// Endings still waiting to be read. The notifier owns the persisted list.
    var unreadEndedBattleIDs: Set<String>
    /// True only while the popover is open on the online screen.
    let onlineScreenShowing: Bool
    /// History, standings or a rematch draft covers the room.
    let overlayShowing: Bool
    let recoveryCodeShowing: Bool
    let now: Date

    @MainActor
    init(presentation: OnlineBattlePresentation, preparedBattleIDs: Set<String>, stagingHeldBattleIDs: Set<String>,
         noChoiceBattleIDs: Set<String> = [], onlineScreenShowing: Bool = false, now: Date) {
        localTrainerID = presentation.account?.trainer.trainerId
        battles = presentation.battles
        nicknames = presentation.members.reduce(into: [:]) { names, member in names[member.trainerId] = member.displayEmail }
        displayedRoom = presentation.room
        phase = presentation.phase
        hasResult = presentation.result != nil
        choiceSubmitted = presentation.choiceSubmitted
        self.preparedBattleIDs = preparedBattleIDs
        self.stagingHeldBattleIDs = stagingHeldBattleIDs
        self.noChoiceBattleIDs = noChoiceBattleIDs
        ownEndedBattleIDs = presentation.ownEndedBattleIDs
        acknowledgedEndedBattleIDs = presentation.acknowledgedEndedBattleIDs
        unreadEndedBattleIDs = presentation.unreadEndedBattleIDs
        self.onlineScreenShowing = onlineScreenShowing
        overlayShowing = presentation.showsHistory || presentation.showsStandings || presentation.rematchSourceID != nil
        recoveryCodeShowing = presentation.recoveryCode != nil
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
        let ended = input.battles
            .filter { input.unreadEndedBattleIDs.contains($0.battleId) }
            .sorted { ($0.createdAt, $0.battleId) < ($1.createdAt, $1.battleId) }
            .compactMap { endedRequest($0, me: me, input: input) }
        let outcome = displayedOutcome(input, me: me).map { [$0] } ?? []
        return (live + ended + outcome).enumerated()
            .sorted { (priority($0.element.kind), $0.offset) < (priority($1.element.kind), $1.offset) }
            .map(\.element)
    }

    static func current(_ input: OnlineAttentionInput) -> OnlineAttention? { active(input).first }

    /// What the in-popover banner shows: the first event that is not already on the online screen. With the popover in
    /// front the notification is suppressed and the event marked seen, so this has to speak on every other screen.
    static func banner(_ input: OnlineAttentionInput) -> OnlineAttention? {
        active(input).first { !isOnScreen($0, input) }
    }

    /// History, standings, a rematch draft and the recovery code all draw over the room or the lobby.
    private static func stageIsUncovered(_ input: OnlineAttentionInput) -> Bool {
        input.onlineScreenShowing && !input.overlayShowing && !input.recoveryCodeShowing
    }

    /// The lobby is where an ended request is told, as its closable notice.
    static func lobbyIsShowing(_ input: OnlineAttentionInput) -> Bool {
        stageIsUncovered(input) && input.phase == .lobby
    }

    private static func isOnScreen(_ attention: OnlineAttention, _ input: OnlineAttentionInput) -> Bool {
        if attention.kind == .requestEnded { return lobbyIsShowing(input) }
        return stageIsUncovered(input) && input.displayedRoom?.battleId == attention.battleId
    }

    /// True once this person has taken a step in a room that has not started, so its ending is news to them:
    /// the challenger from the start, the receiver after accepting. The next move may still be theirs.
    static func isWaiting(_ room: OnlineBattleView, me: String) -> Bool {
        guard let side = room.side(for: me), room.state == .pending || room.state == .accepted || room.state == .ready else { return false }
        return side == .p1 || room.state != .pending
    }

    /// Moves rooms through the record: a waited room that ended becomes unread unless this app ended it.
    /// Only an ending of a room in the record counts, so a first run over old history stays silent. A room missing
    /// from the list proves nothing (a relaunch publishes before hello refills it), so it stays until the list says.
    static func trackWaits(_ input: OnlineAttentionInput, record: OnlineAttentionWaitRecord) -> OnlineAttentionWaitRecord {
        guard let me = input.localTrainerID else { return record }
        var next = OnlineAttentionWaitRecord(unreadEnded: record.unreadEnded)
        for entry in record.waiting {
            guard let room = input.battles.first(where: { $0.battleId == entry.battleId }) else { next.waiting.append(entry); continue }
            guard !input.ownEndedBattleIDs.contains(entry.battleId) else { continue }
            if room.state == .declined || room.state == .cancelled || room.state == .expired {
                if !next.unreadIDs.contains(entry.battleId) { next.unreadEnded.append(.init(battleId: entry.battleId, revision: room.revision)) }
            } else if isWaiting(room, me: me) {
                next.waiting.append(.init(battleId: entry.battleId, revision: room.revision))
            }
        }
        let known = Set(next.waiting.map(\.battleId))
        let started = input.battles
            .filter { isWaiting($0, me: me) && !known.contains($0.battleId) && !input.ownEndedBattleIDs.contains($0.battleId) }
            .sorted { ($0.createdAt, $0.battleId) < ($1.createdAt, $1.battleId) }
        next.waiting += started.map { .init(battleId: $0.battleId, revision: $0.revision) }
        next.unreadEnded.removeAll { input.acknowledgedEndedBattleIDs.contains($0.battleId) }
        next.waiting = Array(next.waiting.suffix(OnlineAttentionWaitRecord.capacity))
        next.unreadEnded = Array(next.unreadEnded.suffix(OnlineAttentionWaitRecord.capacity))
        return next
    }

    private static func endedRequest(_ room: OnlineBattleView, me: String, input: OnlineAttentionInput) -> OnlineAttention? {
        guard let side = room.side(for: me) else { return nil }
        var ended = attention(.requestEnded, room: room, side: side, input: input, deadline: nil)
        ended.ending = .init(state: room.state, reason: room.reason)
        return ended
    }

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
            guard room.mode == .manual, room.ownChoice == nil, let deadline = room.deadline, date(deadline) > input.now,
                  !input.noChoiceBattleIDs.contains(room.battleId) else { return nil }
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
        case .requestEnded: 5
        case .resultReady: 6
        case .matchEnded: 7
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

/// Which online steps keep the popover open while the person works elsewhere, and where a reopened popover lands.
/// Pure: the app delegate reads it to choose `NSPopover.behavior`; nothing here opens or closes anything.
enum OnlinePopoverPinning {
    /// Entry, waiting and battle steps pin. The lobby list, a result and the home screen stay transient.
    /// A recovery code pins on any phase: it is shown once, and copying it means clicking another app.
    @MainActor
    static func isPinned(_ model: OnlineBattlePresentation, onlineScreenShowing: Bool) -> Bool {
        guard onlineScreenShowing else { return false }
        if model.recoveryCode != nil { return true }
        switch model.phase {
        case .setup, .room, .arena, .verifying: return true
        case .lobby, .result: return false
        }
    }

    /// A pinned popover can stay open behind another app, where nobody sees it. Only one in front replaces a notification.
    static func showsAttentionInstead(popoverShown: Bool, appActive: Bool) -> Bool {
        popoverShown && appActive
    }

    /// Where an opening lands: the menu bar, Finder's reopen, a relaunch and the home row all ask this.
    /// nil means nothing is waiting, so the popover stays on Home.
    /// A turn elsewhere cannot wait; otherwise a match in play or being verified keeps the screen and the banner
    /// carries the lesser event. Going back to the group list is a way out of a long verification, so only an event
    /// brings the person back from there.
    static func openRoute(_ input: OnlineAttentionInput) -> OnlineOpenRoute? {
        // The code is on no other screen and is gone for good once the app quits. It keeps whichever room is selected.
        if input.recoveryCodeShowing { return .init(battleId: nil) }
        let current = OnlineAttentionCalculator.current(input)
        if current?.kind == .myTurn { return current.map { .init(battleId: $0.battleId) } }
        switch input.phase {
        case .arena, .verifying: return .init(battleId: input.displayedRoom?.battleId)
        case .setup, .lobby, .room, .result: return current.map { .init(battleId: $0.battleId) }
        }
    }
}

/// Where a popover goes when it opens. `battleId` nil keeps whichever room is already selected.
struct OnlineOpenRoute: Equatable, Sendable {
    let battleId: String?
}
