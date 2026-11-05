import Foundation
import Observation

/// What the connection line is about. Never a display string: the wording lives in `L.onlineConnectionLine`.
enum OnlineConnectionStatus: Equatable, Sendable {
    /// Nothing has been reported yet.
    case unknown
    /// Keychain access is off, before or after a session started.
    case accessOff, accessStopped
    case connection(OnlineBattleConnectionState)
}

/// App-lifetime UI state. The session owns I/O, credentials, clocks and deterministic replay.
@MainActor
@Observable
final class OnlineBattlePresentation {
    enum Phase { case setup, lobby, room, arena, verifying, result }
    var phase: Phase = .setup
    var connectionStatus: OnlineConnectionStatus = .unknown
    var connectionState: OnlineBattleConnectionState? {
        if case .connection(let state) = connectionStatus { return state }
        return nil
    }
    var notice: String?
    /// True while the popover ignores outside clicks (entry, waiting and battle steps). Written by the app delegate.
    var popoverPinned = false
    /// macOS notification guidance owned by the online notifier; nil when nothing needs saying.
    var notificationHint: OnlineNotificationHint?
    /// Set with an ended-challenge notice so a background refresh does not wipe it before it is read.
    var stickyNotice: String?
    var stickyNoticeBattleID: String?
    /// Battles whose ending was already announced (or was caused by this app's own cancel/decline).
    var endedNoticeIDs: Set<String> = []
    /// Rooms this app ended itself; their ending is never announced back. Separate from `endedNoticeIDs`, which also holds announced ones.
    var ownEndedBattleIDs: Set<String> = []
    /// Endings the person has not read yet. The notifier owns the persisted list and writes it through `syncEnded`.
    var unreadEndedBattleIDs: Set<String> = []
    /// Endings already read. Only grows, so an older input can never bring one back.
    var acknowledgedEndedBattleIDs: Set<String> = []
    var noticeSurvivesRefresh: Bool { stickyNotice != nil && notice == stickyNotice }
    var isBusy = false
    var serverAddress = ""
    /// True when the build fixed the server address (T08); the setup form then shows no address entry.
    var serverIsEmbedded = false
    /// Memory-only drafts survive popover disposal; never encode these in settings or saves.
    var setupInput = OnlineBattleSetupInput()
    var setupRecoveryExpanded = false
    var setupAdvancedExpanded = false
    var setupPasteFailure: OnlineBattleSetupInput.PasteFailure?
    func clearSetupCodes() { setupInput.clearCodes(); setupPasteFailure = nil }
    var account: OnlineBattleAccount? {
        didSet {
            // A different account, or one that stopped being the host, takes the panel and any unsaved code with it.
            if account?.trainer.trainerId != oldValue?.trainer.trainerId || !isHost { host.close() }
            // The first steps are for whoever just saw their recovery code; another account never inherits them.
            if account?.trainer.trainerId != oldValue?.trainer.trainerId { firstSteps = nil }
        }
    }
    /// The host panel (T10): invite codes, members, reconnect codes. Only a host ever shows it.
    var host = OnlineBattleHostState()
    var isHost: Bool { account?.trainer.role == .host && account?.trainer.status == .active }
    var showsHostPanel: Bool { host.visible && isHost }
    /// A copyable code is on screen: it is gone if the popover closes before it is copied, so the popover stays open.
    var hostSecretShowing: Bool { showsHostPanel && host.secret != nil }
    /// A host in the lobby with nothing covering it. The panel is a lobby tool: a room or a match keeps the screen.
    var canOpenHostPanel: Bool {
        isHost && phase == .lobby && !isBusy && !showsHistory && !showsStandings && rematchSourceID == nil
    }
    /// Who the host can act on: every active member but the host.
    var hostMembers: [OnlineBattleMember] { lobbyPeers }
    var members: [OnlineBattleMember] = []
    /// Who the lobby can challenge: every active member but me. Empty means the group has nobody else yet.
    var lobbyPeers: [OnlineBattleMember] {
        members.filter { $0.status == .active && $0.trainerId != account?.trainer.trainerId }
    }
    var battles: [OnlineBattleView] = []
    /// Archive navigation is independent of the live room and arena.
    var showsStandings = false
    var standings: OnlineBattleStandings?
    var standingsLoading = false
    var standingsError: String?
    var rematchSourceID: String?
    var rematchOpponent: OnlineBattleMember? { selectedOpponent }
    var rematchMode: OnlineBattleMode? { rematchSourceID == nil ? nil : mode }
    var canSubmitRematch: Bool {
        guard rematchSourceID != nil, !isBusy, let selectedEntry, entryIsEligible(selectedEntry),
              let account, let opponent = selectedOpponent else { return false }
        return opponent.status == .active && opponent.trainerId != account.trainer.trainerId
    }
    func canRematch(_ battle: OnlineBattleView) -> Bool {
        guard !isBusy, !showsStandings, battle.state == .completed, let account,
              let side = battle.side(for: account.trainer.trainerId), roster.contains(where: entryIsEligible) else { return false }
        let target = side == .p1 ? battle.p2.trainerId : battle.p1.trainerId
        return members.contains { $0.trainerId == target && $0.status == .active && target != account.trainer.trainerId }
    }
    var showsHistory = false
    var selectedHistoryBattle: OnlineBattleView?
    var replay: OnlineBattleReplay?
    var replayFrameIndex = 0
    var historyBusy = false
    var historyError: String?
    var liveLogs: [String] = []
    var stage: OnlineBattleStaging?
    var stageSpeed: PracticePlaybackSpeed = .normal
    var roster: [PracticeCandidate] = []
    var entryHP: [String: Int] = [:]
    var blockedEntryIDs: Set<String> = []
    /// Only ready/start needs the current WebSocket hello; HTTP consent remains available when polling.
    var canStart = false
    /// Set by the session: this app's ready call for the open room was accepted by the server.
    var localReady = false
    var canRetryCredentialSave = false
    /// A saved account exists but has not been read yet, so there is nothing to sign up for.
    var restoringAccount = false { didSet { if !restoringAccount { showsSetupWhileRestoring = false } } }
    /// The way out when the saved account cannot be reached: recover it, or use another server.
    var showsSetupWhileRestoring = false
    var showsRestoringAccount: Bool { restoringAccount && !showsSetupWhileRestoring }
    var selectedEntryID: String?
    var selectedOpponentID: String?
    var mode: OnlineBattleMode = .manual
    var room: OnlineBattleView?
    var localSide: OnlineBattleSide = .p1
    /// Only the resolver's view, whose opponent moves/ability are already revealed.
    var arena: BattleView?
    var request: BattleRequest?
    /// Hints for my own request's moves by slot (type matchup, STAB, power). Public data only.
    var moveHints: [Int: PracticeMoveHint] = [:]
    /// Exact original slugs for IDs already exposed by resolver.view (and my own request).
    /// These maps must never enumerate the opponent's undisclosed set.
    var moveSlugs: [OnlineBattleSide: [String: String]] = [:]
    var abilitySlugs: [OnlineBattleSide: [String: String]] = [:]
    var deadline: Date?
    var choiceSubmitted = false
    /// Transient onboarding output only; never an access key or persisted UI state.
    var recoveryCode: String? {
        // The check belongs to the code it was made for: a new code, or none, starts unchecked.
        didSet { if recoveryCode != oldValue { recoveryWrittenDown = false } }
    }
    /// The person says they wrote the code down. Only then may the keep button close the code screen.
    var recoveryWrittenDown = false
    var canAcknowledgeRecoveryCode: Bool { recoveryCode != nil && recoveryWrittenDown }
    /// The three-line guide shown once on the lobby after the recovery code was kept or copied. Memory only.
    var firstSteps: OnlineBattleFirstSteps?
    /// Leaves the recovery code screen for good: the code is forgotten and the first steps take its place.
    /// Nothing happens when no code is on screen, so a repeated press cannot bring the guide back.
    func finishRecoveryScreen(copied: Bool) {
        guard recoveryCode != nil else { return }
        recoveryCode = nil
        firstSteps = .init(copiedRecoveryCode: copied)
    }
    var result: OnlineBattleUIResult?
    var onAction: (OnlineBattleUIAction) -> Void = { _ in }

    var selectedEntry: PracticeCandidate? { roster.first { $0.id == selectedEntryID } }
    var selectedOpponent: OnlineBattleMember? { members.first { $0.trainerId == selectedOpponentID } }
    var activeBattles: [OnlineBattleView] { battles.filter { $0.state.isActive } }
    var historyBattles: [OnlineBattleView] {
        battles.filter { !$0.state.isActive }.sorted {
            $0.createdAt == $1.createdAt ? $0.battleId > $1.battleId : $0.createdAt > $1.createdAt
        }
    }
    func entryIsEligible(_ entry: PracticeCandidate) -> Bool {
        entry.snapshot != nil && entry.blockedReason == nil && (entryHP[entry.id] ?? 0) > 0 && !blockedEntryIDs.contains(entry.id)
    }
    var canChallenge: Bool {
        guard !showsHistory, !showsStandings, rematchSourceID == nil, phase == .lobby, !isBusy, let account, let selectedEntry, entryIsEligible(selectedEntry),
              let opponent = selectedOpponent else { return false }
        return opponent.status == .active && opponent.trainerId != account.trainer.trainerId
    }
    var canAccept: Bool {
        guard !showsHistory, !showsStandings, rematchSourceID == nil, !isBusy, room?.state == .pending, localSide == .p2,
              let selectedEntry else { return false }
        return entryIsEligible(selectedEntry)
    }
    var canConfirm: Bool { !showsHistory && !showsStandings && rematchSourceID == nil && !isBusy && room?.state == .accepted && localSide == .p1 && room?.confirmed == false }
    var canPrepare: Bool { !showsHistory && !showsStandings && rematchSourceID == nil && !isBusy && canStart && !localReady && room?.confirmed == true && [.accepted, .ready].contains(room?.state) }
    /// What the other seat is doing while this app waits for it in a manual round.
    /// `offlineMaybe` is the same news from a presence the app cannot vouch for (see `opponentWait`).
    enum OpponentWait: Equatable { case choosing, offline, offlineMaybe, submitted }
    /// The click that sent a choice, kept with its round so a later round never inherits the mark.
    private struct LocalChoice { let battleID: String; let roundSeq: Int; let slot: Int }
    private var localChoice: LocalChoice?
    /// Said in a live manual round once the other seat's choice is in (whether or not mine is) or mine is in;
    /// nil before that, so the moves stay uncluttered. A choice that is in wins over any presence.
    /// A foe flagged offline is stated as fact only while the socket is up. Presence is not refreshed while
    /// polling, so there the flag may be old and the wording is hedged. An old "online" is never taken as proof.
    var opponentWait: OpponentWait? {
        guard phase == .arena, let room, room.state == .running, room.mode == .manual else { return nil }
        if room.opponentSubmitted == true { return .submitted }
        guard choiceSubmitted else { return nil }
        let foe = localSide == .p1 ? room.p2.trainerId : room.p1.trainerId
        guard members.first(where: { $0.trainerId == foe })?.online == false else { return .choosing }
        return connectionState == .connected ? .offline : .offlineMaybe
    }
    /// The slot of my choice in this round: the server's own record once it is in the room, else my click.
    var chosenSlot: Int? {
        guard choiceSubmitted, let room else { return nil }
        if let own = room.ownChoice, let slot = own.split(separator: " ").last.flatMap({ Int($0) }) { return slot }
        guard let click = localChoice, click.battleID == room.battleId, click.roundSeq == room.roundSeq else { return nil }
        return click.slot
    }
    func canChooseMove(_ slot: Int) -> Bool {
        !showsHistory && !showsStandings && rematchSourceID == nil && phase == .arena && room?.state == .running && room?.mode == .manual && !isBusy && !choiceSubmitted &&
        request?.kind == "move" && request?.moves.contains { $0.slot == slot && !$0.disabled && $0.pp > 0 } == true
    }
    /// Host actions that only change what is on screen are applied here and stop; the rest are checked and go on.
    /// Removing a member is two steps, and the second must name the member the first asked about.
    private func applyHost(_ action: OnlineBattleHostAction) -> Bool {
        guard isHost else { return false }
        func isMember(_ id: String) -> Bool { hostMembers.contains { $0.trainerId == id } }
        switch action {
        case .open: return canOpenHostPanel
        case .close: host.close(); return false
        case .chooseInvite(let choice):
            if showsHostPanel { host.choice = choice }
            return false
        case .refreshInvites, .createInvite, .revokeInvite: return showsHostPanel && !host.busy
        case .issueReconnect(let id): return showsHostPanel && !host.busy && isMember(id)
        case .askRemove(let id):
            if showsHostPanel, !host.busy, isMember(id) { host.pendingRemoval = id; host.notice = nil }
            return false
        case .cancelRemove: host.pendingRemoval = nil; return false
        case .confirmRemove(let id): return showsHostPanel && !host.busy && host.pendingRemoval == id && isMember(id)
        case .copied:
            if let secret = host.secret { host.copied = secret.kind; host.secret = nil }
            return false
        case .dismissSecret: host.secret = nil; host.copied = nil; return false
        case .dismissNotice: host.notice = nil; return false
        }
    }

    func send(_ action: OnlineBattleUIAction) {
        // These are presentation guards. The session independently validates server state and replay state.
        switch action {
        case .showStandings:
            guard phase == .lobby, !isBusy, account != nil, rematchSourceID == nil else { return }
        case .refreshStandings:
            guard showsStandings else { return }
        case .prepareRematch(let id):
            guard let battle = selectedHistoryBattle?.battleId == id ? selectedHistoryBattle : room,
                  battle.battleId == id, canRematch(battle) else { return }
        case .submitRematch: guard canSubmitRematch else { return }
        case .cancelRematch: guard rematchSourceID != nil else { return }
        case .setPopoverVisible, .setOnlineScreenVisible, .skipStage, .setStageSpeed, .followAttention:
            break
        case .showSetupWhileRestoring:
            showsSetupWhileRestoring = true
            return
        case .dismissEnded(let id):
            // Pure presentation, like dismissNotice.
            dismissEnded(id)
            return
        case .dismissNotice:
            // Pure presentation: closing a banner never reaches the session or the server.
            notice = nil; stickyNotice = nil
            return
        case .backToLobby:
            break
        case .showHistory:
            guard phase == .lobby, !isBusy, !showsStandings, rematchSourceID == nil else { return }
            showsHistory = true
        case .openReplay(let id):
            guard showsHistory, !historyBusy,
                  let battle = battles.first(where: { $0.battleId == id && !$0.state.isActive }) else { return }
            selectedHistoryBattle = battle
        case .seekReplay(let index):
            guard showsHistory, let replay, replay.frames.indices.contains(index) else { return }
            replayFrameIndex = index
        case .closeReplay:
            guard showsHistory else { return }
            selectedHistoryBattle = nil
            replay = nil
            replayFrameIndex = 0
            historyError = nil
        case .selectEntry(let id):
            guard let entry = roster.first(where: { $0.id == id }), entryIsEligible(entry) else { return }
            selectedEntryID = id
        case .selectOpponent(let id):
            guard rematchSourceID == nil, let account, members.contains(where: { $0.trainerId == id && $0.status == .active && id != account.trainer.trainerId }) else { return }
            selectedOpponentID = id
        case .setMode(let mode):
            guard !showsHistory, !showsStandings, rematchSourceID == nil else { return }
            self.mode = mode
        case .challenge: guard canChallenge else { return }
        case .accept(let id): guard room?.battleId == id, canAccept else { return }
        case .confirm(let id): guard room?.battleId == id, canConfirm else { return }
        case .prepareBattle(let id): guard room?.battleId == id, canPrepare else { return }
        case .chooseMove(let slot):
            guard canChooseMove(slot) else { return }
            if let room { localChoice = LocalChoice(battleID: room.battleId, roundSeq: room.roundSeq, slot: slot) }
            choiceSubmitted = true
        case .decline(let id): guard room?.battleId == id, !showsHistory, !showsStandings, rematchSourceID == nil, !isBusy, localSide == .p2, room?.state == .pending else { return }
        case .cancel(let id): guard room?.battleId == id, !showsHistory, !showsStandings, rematchSourceID == nil, !isBusy, [.pending, .accepted, .ready].contains(room?.state) else { return }
        case .retryCredentialSave: guard !isBusy, canRetryCredentialSave else { return }
        case .applyingServer(let address, let inner):
            // Manual builds only: the session saves this address, then runs the inner setup request against it.
            guard !isBusy, !serverIsEmbedded, (try? OnlineBattleOrigin(address)) != nil else { return }
            switch inner {
            case .join(let code, let email):
                guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            case .recover(let code), .reconnect(let code):
                guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            default: return
            }
        case .configureServer(let address): guard !isBusy, (try? OnlineBattleOrigin(address)) != nil else { return }
        case .join(let code, let email): guard !isBusy, !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        case .recover(let code), .reconnect(let code): guard !isBusy, !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        case .setRecoveryWrittenDown(let written):
            // Pure presentation: ticking the box never reaches the session.
            if recoveryCode != nil { recoveryWrittenDown = written }
            return
        case .recoveryCopied:
            // The clipboard has the code, so this screen forgets it, as a host's one-time code does.
            finishRecoveryScreen(copied: true)
            return
        case .dismissFirstSteps:
            firstSteps = nil
            return
        case .acknowledgeRecoveryCode:
            guard canAcknowledgeRecoveryCode else { return }
            finishRecoveryScreen(copied: false)
        case .openBattle(let id): guard !showsHistory, !showsStandings, rematchSourceID == nil, !isBusy, battles.contains(where: { $0.battleId == id && $0.state.isActive }) else { return }
        case .refresh, .dismissResult: guard !isBusy else { return }
        case .host(let hostAction): guard applyHost(hostAction) else { return }
        }
        onAction(action)
    }
}

/// What the first lobby says after the recovery code was dealt with. `copiedRecoveryCode` adds the line that says
/// the code went to the clipboard and is hidden. Never holds the code.
struct OnlineBattleFirstSteps: Equatable, Sendable {
    let copiedRecoveryCode: Bool
}

struct OnlineBattleUIResult {
    let title: String
    let detail: String
    let xpAwarded: Int64
    let hpApplied: Bool
    let isVoid: Bool
}

enum OnlineBattleUIAction {
    case configureServer(String)
    indirect case applyingServer(String, OnlineBattleUIAction)
    case join(inviteCode: String, email: String)
    case recover(code: String)
    case reconnect(code: String)
    case acknowledgeRecoveryCode, retryCredentialSave, refresh
    /// Recovery code screen, all pure presentation: the box "I wrote it down", the code reaching the clipboard, closing the guide.
    case setRecoveryWrittenDown(Bool), recoveryCopied, dismissFirstSteps
    case setPopoverVisible(Bool)
    case setOnlineScreenVisible(Bool), skipStage, setStageSpeed(PracticePlaybackSpeed)
    case selectEntry(String), selectOpponent(String), setMode(OnlineBattleMode)
    case challenge, openBattle(String)
    /// Room actions name the battle on screen: agreeing to a match can never land on another room.
    case accept(String), confirm(String), prepareBattle(String), decline(String), cancel(String)
    case showStandings, refreshStandings, prepareRematch(String), submitRematch, cancelRematch
    case showHistory, openReplay(String), seekReplay(Int), closeReplay
    case chooseMove(Int), dismissResult, backToLobby, dismissNotice, showSetupWhileRestoring
    /// The way to a room from an event (notification, banner, reopening, home row). Not a lobby row: overlays may be up.
    case followAttention(String)
    /// Closes an ended-request banner without opening anything. Pure presentation.
    case dismissEnded(String)
    /// Host-only group care: invites, members, reconnect codes. Everything else about the host panel is in the state.
    case host(OnlineBattleHostAction)
}
