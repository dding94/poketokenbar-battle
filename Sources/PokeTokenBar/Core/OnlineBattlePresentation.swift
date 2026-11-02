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
    var roster: [PracticeCandidate] = []
    var selectedEntryID: String?
    var selectedOpponentID: String?
    var mode: OnlineBattleMode = .manual
    var room: OnlineBattleView?
    var localSide: OnlineBattleSide = .p1
    /// Only the resolver's view, whose opponent moves/ability are already revealed.
    var arena: BattleView?
    var request: BattleRequest?
    var deadline: Date?
    var choiceSubmitted = false
    /// Transient onboarding output only; never an access key or persisted UI state.
    var recoveryCode: String?
    var result: OnlineBattleUIResult?
    var onAction: (OnlineBattleUIAction) -> Void = { _ in }

    var selectedEntry: PracticeCandidate? { roster.first { $0.id == selectedEntryID } }
    var selectedOpponent: OnlineBattleMember? { members.first { $0.trainerId == selectedOpponentID } }
    var canChallenge: Bool { false }
    func canChooseMove(_ slot: Int) -> Bool { false }
    func send(_ action: OnlineBattleUIAction) {}
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
    case recover(groupID: String, trainerID: String, code: String)
    case reconnect(code: String)
    case acknowledgeRecoveryCode, refresh
    case selectEntry(String), selectOpponent(String), setMode(OnlineBattleMode)
    case challenge, openBattle(String), accept, confirm, decline, cancel
    case chooseMove(Int), dismissResult
}
