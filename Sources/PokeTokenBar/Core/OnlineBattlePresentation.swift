import Foundation
import Observation

/// App-lifetime UI state. The session owns I/O, credentials, clocks and deterministic replay.
@MainActor
@Observable
final class OnlineBattlePresentation {
    enum Phase { case setup, lobby, room, arena, verifying, result }
    var phase: Phase = .setup
    var connectionStatus = ""
    var notice: String?
    var isBusy = false
    var serverAddress = ""
    var account: OnlineBattleAccount?
    var members: [OnlineBattleMember] = []
    var battles: [OnlineBattleView] = []
    /// Archive navigation is independent of the live room and arena.
    var showsHistory = false
    var selectedHistoryBattle: OnlineBattleView?
    var replay: OnlineBattleReplay?
    var replayFrameIndex = 0
    var historyBusy = false
    var historyError: String?
    var liveLogs: [String] = []
    var roster: [PracticeCandidate] = []
    var entryHP: [String: Int] = [:]
    var blockedEntryIDs: Set<String> = []
    /// Only ready/start needs the current WebSocket hello; HTTP consent remains available when polling.
    var canStart = false
    var canRetryCredentialSave = false
    var selectedEntryID: String?
    var selectedOpponentID: String?
    var mode: OnlineBattleMode = .manual
    var room: OnlineBattleView?
    var localSide: OnlineBattleSide = .p1
    /// Only the resolver's view, whose opponent moves/ability are already revealed.
    var arena: BattleView?
    var request: BattleRequest?
    /// Exact original slugs for IDs already exposed by resolver.view (and my own request).
    /// These maps must never enumerate the opponent's undisclosed set.
    var moveSlugs: [OnlineBattleSide: [String: String]] = [:]
    var abilitySlugs: [OnlineBattleSide: [String: String]] = [:]
    var deadline: Date?
    var choiceSubmitted = false
    /// Transient onboarding output only; never an access key or persisted UI state.
    var recoveryCode: String?
    var result: OnlineBattleUIResult?
    var onAction: (OnlineBattleUIAction) -> Void = { _ in }

    var selectedEntry: PracticeCandidate? { roster.first { $0.id == selectedEntryID } }
    var selectedOpponent: OnlineBattleMember? { members.first { $0.trainerId == selectedOpponentID } }
    func entryIsEligible(_ entry: PracticeCandidate) -> Bool {
        entry.snapshot != nil && entry.blockedReason == nil && (entryHP[entry.id] ?? 0) > 0 && !blockedEntryIDs.contains(entry.id)
    }
    var canChallenge: Bool {
        guard phase == .lobby, !isBusy, let account, let selectedEntry, entryIsEligible(selectedEntry),
              let opponent = selectedOpponent else { return false }
        return opponent.status == .active && opponent.trainerId != account.trainer.trainerId
    }
    var canAccept: Bool {
        guard !isBusy, room?.state == .pending, localSide == .p2,
              let selectedEntry else { return false }
        return entryIsEligible(selectedEntry)
    }
    var canConfirm: Bool { !isBusy && room?.state == .accepted && localSide == .p1 && room?.confirmed == false }
    var canPrepare: Bool { !isBusy && canStart && room?.confirmed == true && [.accepted, .ready].contains(room?.state) }
    func canChooseMove(_ slot: Int) -> Bool {
        !showsHistory && phase == .arena && room?.state == .running && room?.mode == .manual && !isBusy && !choiceSubmitted &&
        request?.kind == "move" && request?.moves.contains { $0.slot == slot && !$0.disabled && $0.pp > 0 } == true
    }
    func send(_ action: OnlineBattleUIAction) {
        // These are presentation guards. The session independently validates server state and replay state.
        switch action {
        case .setPopoverVisible:
            break
        case .backToLobby:
            break
        case .showHistory:
            guard phase == .lobby, !isBusy else { return }
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
            guard let account, members.contains(where: { $0.trainerId == id && $0.status == .active && id != account.trainer.trainerId }) else { return }
            selectedOpponentID = id
        case .setMode(let mode):
            self.mode = mode
        case .challenge: guard canChallenge else { return }
        case .accept: guard canAccept else { return }
        case .confirm: guard canConfirm else { return }
        case .prepareBattle: guard canPrepare else { return }
        case .chooseMove(let slot):
            guard canChooseMove(slot) else { return }
            choiceSubmitted = true
        case .decline: guard !isBusy, localSide == .p2, room?.state == .pending else { return }
        case .cancel: guard !isBusy, [.pending, .accepted, .ready].contains(room?.state) else { return }
        case .retryCredentialSave: guard !isBusy, canRetryCredentialSave else { return }
        case .configureServer(let address): guard !isBusy, (try? OnlineBattleOrigin(address)) != nil else { return }
        case .join(let code, let email): guard !isBusy, !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        case .recover(let code), .reconnect(let code): guard !isBusy, !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        case .acknowledgeRecoveryCode:
            guard recoveryCode != nil else { return }
            recoveryCode = nil
        case .openBattle(let id): guard !showsHistory, !isBusy, battles.contains(where: { $0.battleId == id && $0.state.isActive }) else { return }
        case .refresh, .dismissResult: guard !isBusy else { return }
        }
        onAction(action)
    }
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
    case join(inviteCode: String, email: String)
    case recover(code: String)
    case reconnect(code: String)
    case acknowledgeRecoveryCode, retryCredentialSave, refresh
    case setPopoverVisible(Bool)
    case selectEntry(String), selectOpponent(String), setMode(OnlineBattleMode)
    case challenge, openBattle(String), accept, confirm, prepareBattle, decline, cancel
    case showHistory, openReplay(String), seekReplay(Int), closeReplay
    case chooseMove(Int), dismissResult, backToLobby
}
