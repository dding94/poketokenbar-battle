import Foundation

extension L {
    /// Online battle ships Korean first; other app languages use the English fallback.
    func online(_ ko: String, _ en: String) -> String { lang == .ko ? ko : en }
    var onlineTitle: String { online("온라인 배틀", "Online battle") }
    var onlinePinned: String { "" }
    var onlineSetup: String { online("동료와 정식전 시작하기", "Battle with your group") }
    var onlineServer: String { online("서버 주소", "Server address") }
    var onlineSaveServer: String { online("서버 주소 적용", "Apply server address") }
    var onlineServerHint: String { online("① 방장이 보낸 HTTPS 서버 주소는 한 번 적용하면 저장돼요.", "① Apply the HTTPS server address from your host once to save it.") }
    var onlinePasteInvitation: String { online("초대 정보 붙여넣기", "Paste invitation details") }
    var onlinePasteInvitationFailed: String { online("서버 주소 하나와 12자리 초대코드가 함께 있는 내용을 복사해 주세요. 입력한 내용은 유지돼요.", "Copy one HTTPS server address and one 12-character invite code together. Your entries are unchanged.") }
    var onlineInvite: String { online("초대코드", "Invite code") }
    var onlineNickname: String { online("닉네임", "Nickname") }
    var onlineNicknameHint: String { online("② 초대코드와 공백 없는 닉네임을 입력하세요. 이메일은 필요 없어요.", "② Enter your invite code and nickname without spaces. No email is required.") }
    var onlineServerSaved: String { online("주소가 적용됐어요. 아래에서 그룹에 참여하세요.", "Address saved. Join your group below.") }
    func onlineSetupRequirement(_ requirement: OnlineBattleSetupInput.Requirement) -> String {
        switch requirement {
        case .busy: online("처리하고 있어요. 잠시 기다려 주세요.", "Working. Please wait.")
        case .serverMissing: online("먼저 방장에게 받은 https:// 서버 주소를 입력하세요.", "First enter the HTTPS server address from your host.")
        case .serverChanged: online("위의 ‘서버 주소 적용’을 먼저 눌러 주세요.", "Apply the server address above first.")
        case .inviteMissing: online("방장에게 받은 초대코드를 입력하세요.", "Enter the invite code from your host.")
        case .nicknameMissing: online("함께 사용할 닉네임을 입력하세요.", "Enter your nickname.")
        case .ready: online("준비됐어요. ‘그룹 참여’를 눌러 주세요.", "Ready. Select Join group.")
        }
    }
    var onlineJoin: String { online("그룹 참여", "Join group") }
    var onlineRecovery: String { online("기존 계정 연결", "Reconnect your account") }
    var onlineRecoveryCode: String { online("복구코드", "Recovery code") }
    var onlineReconnectCode: String { online("방장의 재연결 코드", "Host reconnect code") }
    var onlineRecover: String { online("복구코드로 연결", "Use recovery code") }
    var onlineReconnect: String { online("재연결 코드 사용", "Use reconnect code") }
    var onlineRecoveryTitle: String { online("복구코드를 보관하세요", "Keep your recovery code") }
    var onlineRecoveryHint: String { online("이 화면에서만 보여요. 키를 잃으면 이 코드로 계정을 다시 연결할 수 있어요.", "Shown only here. Keep this code to reconnect if you lose your key.") }
    var onlineRecoverySaved: String { online("코드를 보관했어요", "I saved this code") }
    var onlineRetrySave: String { online("접속키 저장 다시 시도", "Retry saving key") }
    var onlineRefresh: String { online("새로고침", "Refresh") }
    var onlineMembers: String { online("함께하는 동료", "Group members") }
    var onlineAnonymous: String { online("동료", "Trainer") }
    var onlineAvailable: String { online("접속 중", "Online") }
    var onlineOffline: String { online("오프라인", "Offline") }
    var onlineOwnEntry: String { online("출전 포켓몬", "Your entry") }
    var onlineNoEntries: String { online("출전할 수 있는 포켓몬이 없어요.", "No eligible Pokémon available.") }
    var onlineHeld: String { online("다른 정식전에 출전 중", "Reserved for another battle") }
    var onlineFainted: String { online("기절 · 회복이 필요해요", "Fainted · healing required") }
    var onlineManual: String { online("직접 조작", "Manual") }
    var onlineAuto: String { online("자동", "Auto") }
    var onlineMode: String { online("배틀 방식", "Battle mode") }
    var onlineTurnHint: String { online("직접 조작은 턴당 30초, 시간이 지나면 자동으로 선택해요.", "Manual turns last 30 seconds; timeout selects automatically.") }
    var onlineChallenge: String { online("정식전 신청", "Send challenge") }
    var onlineBattles: String { online("진행 중인 경기", "Battles") }
    var onlineNoBattles: String { online("아직 진행 중인 경기가 없어요.", "No battles yet.") }
    var onlineHistory: String { online("지난 경기", "Battle history") }
    var onlineStandings: String { online("그룹 전적판", "Group standings") }
    var onlineStandingsLoading: String { online("전적을 불러오고 있어요…", "Loading standings…") }
    var onlineStandingsUnavailable: String { online("전적판을 불러올 수 없어요.", "Standings are unavailable.") }
    var onlineNoStandings: String { online("표시할 그룹 멤버가 없어요.", "No group members to show.") }
    var onlineRetry: String { online("다시 시도", "Try again") }
    var onlineChampion: String { online("챔피언", "Champion") }
    var onlineStandingsRateHint: String { online("승률은 확정된 5경기부터 표시해요. 무승부도 경기 수에 포함돼요.", "Win rate appears after five confirmed battles; draws count toward the total.") }
    func onlineRecord(_ wins: Int, _ losses: Int, _ draws: Int) -> String {
        online("\(wins)승 \(losses)패 \(draws)무", "\(wins)W \(losses)L \(draws)D")
    }
    func onlineWinRate(_ rate: String) -> String { online("승률 \(rate)", "Win rate \(rate)") }
    func onlineCurrentStreak(_ streak: Int) -> String { online("현재 연승 \(streak)", "Current streak \(streak)") }
    func onlineBestStreak(_ streak: Int) -> String { online("최고 연승 \(streak)", "Best streak \(streak)") }
    var onlineRematch: String { online("재대결 신청", "Request rematch") }
    var onlineRematchPreparation: String { online("재대결 준비", "Prepare rematch") }
    var onlineRematchBack: String { online("이전 화면", "Back") }
    var onlineRematchOpponent: String { online("상대", "Opponent") }
    var onlineRematchLocked: String { online("상대와 배틀 방식은 이전 경기와 같아요.", "The opponent and battle mode match the previous battle.") }
    var onlineRematchSubmit: String { online("이 포켓몬으로 신청", "Request with this Pokémon") }
    var onlineRematchUnavailable: String { online("활동 중인 상대와 건강한 출전 포켓몬이 필요해요. 기절하거나 다른 경기에 출전 중인 포켓몬은 선택할 수 없어요.", "An active opponent and a healthy available Pokémon are required. Fainted or reserved Pokémon cannot enter.") }
    var onlineNoHistory: String { online("아직 지난 경기가 없어요.", "No past battles yet.") }
    var onlineBackToHistory: String { online("기록 목록", "Back to history") }
    var onlineReplay: String { online("다시보기", "Replay") }
    var onlineReplayUnavailable: String { online("이 경기는 다시 볼 자료가 없어요.", "This battle has no replay data.") }
    var onlineReplayLoading: String { online("다시보기를 확인하고 있어요…", "Checking replay…") }
    var onlineReplayFirst: String { online("처음", "First") }
    var onlineReplayPrevious: String { online("이전", "Previous") }
    var onlineReplayNext: String { online("다음", "Next") }
    var onlineReplayLast: String { online("마지막", "Last") }
    var onlineBattleLog: String { online("배틀 기록", "Battle log") }
    var onlineNoLog: String { online("아직 표시할 기록이 없어요.", "No events to show yet.") }
    func onlineReplayStep(_ current: Int, total: Int) -> String { online("장면 \(current)/\(total)", "Scene \(current)/\(total)") }
    func onlineHistoryOutcome(_ battle: OnlineBattleView, localTrainerID: String?) -> String {
        switch battle.state {
        case .void: return online("경기 무효 · 기록과 보상 변경 없음", "Void · no record or reward changes")
        case .cancelled: return online("신청 취소", "Challenge cancelled")
        case .declined: return online("신청 거절", "Challenge declined")
        case .expired: return online("신청 만료", "Challenge expired")
        case .completed:
            guard let result = battle.result, let localTrainerID,
                  let localSide = battle.side(for: localTrainerID) else { return onlineState(battle.state) }
            switch result.winner {
            case .draw: return online("무승부", "Draw")
            case .p1, .p2: return result.winner.rawValue == localSide.rawValue ? online("승리", "Win") : online("패배", "Loss")
            }
        default: return onlineState(battle.state)
        }
    }
    var onlineAccept: String { online("수락", "Accept") }
    var onlineConfirm: String { online("최종 확인", "Confirm challenge") }
    var onlinePrepare: String { online("전투 준비", "Ready for battle") }
    var onlineDecline: String { online("거절", "Decline") }
    var onlineCancel: String { online("신청 취소", "Cancel challenge") }
    var onlineWaiting: String { online("상대의 응답을 기다리고 있어요.", "Waiting for your opponent.") }
    var onlineHidden: String { online("기술과 특성은 전투에서 처음 쓰일 때 공개돼요.", "Moves and abilities are revealed when first used.") }
    var onlineNoLevelLimit: String { online("레벨 보정 없이 현재 능력치로 겨뤄요.", "Battles use current levels and stats.") }
    var onlineChoiceSent: String { online("선택 완료 · 상대를 기다리는 중", "Choice sent · waiting for opponent") }
    var onlineAutomatic: String { online("자동으로 전투 중", "Battle progressing automatically") }
    var onlineForced: String { online("필수 행동을 자동으로 처리하고 있어요.", "Resolving the required action automatically.") }
    var onlineVerifying: String { online("결과를 확인하고 있어요", "Verifying the result") }
    var onlineVerifyingHint: String { online("양쪽 결과가 일치하고 저장이 끝나야 체력과 경험치가 반영돼요.", "HP and XP apply after both results match and the save completes.") }
    var onlineResult: String { online("정식전 결과", "Battle result") }
    var onlineHPApplied: String { online("체력 반영 완료", "HP saved") }
    var onlineNoEffects: String { online("체력과 경험치 변화 없음", "No HP or XP changes") }
    var onlineDone: String { online("그룹으로 돌아가기", "Back to group") }
    var onlineCaption: String { online("온라인 정식전", "Official online battle") }
    var onlineStakesHint: String { online("승리하면 현재 키우는 포켓몬이 경험치 1천만을 받아요(온라인 하루 10회). 패배하면 출전 포켓몬이 기절해요.", "A win grants your current companion 10 million XP (10 online wins per day). A loss faints your battle entry.") }
    func onlineTurn(_ turn: Int, seconds: Int) -> String { online("\(turn)턴 · \(seconds)초", "Turn \(turn) · \(seconds)s") }
    func onlineXP(_ value: Int64) -> String { online("경험치 +\(value.formatted())", "XP +\(value.formatted())") }
    func onlineHP(_ value: Int) -> String { "HP \(value)%" }
    func onlineState(_ state: OnlineBattleState) -> String {
        switch state {
        case .pending: online("수락 대기", "Awaiting acceptance")
        case .accepted: online("최종 확인 대기", "Awaiting confirmation")
        case .ready: online("전투 준비 중", "Preparing battle")
        case .running: online("전투 중", "In battle")
        case .reported: online("결과 확인 중", "Verifying result")
        case .completed: online("완료", "Completed")
        case .declined: online("거절됨", "Declined")
        case .cancelled: online("취소됨", "Cancelled")
        case .expired: online("만료됨", "Expired")
        case .void: online("경기 무효", "Void")
        }
    }

    // MARK: Error notices
    var onlineErrorGeneric: String { online("온라인 정보를 확인하지 못했어요. 연결을 확인하고 다시 시도해 주세요.", "Could not read online information. Check your connection and try again.") }
    var onlineErrorKeySaveFailed: String { online("접속키를 안전하게 저장하지 못했어요. 저장을 다시 시도해 주세요.", "Could not save your access key safely. Try saving again.") }
    var onlineErrorKeySaveDisabled: String { online("접속키 저장이 꺼져 있어요. 설정을 확인해 주세요.", "Access key storage is turned off. Check your settings.") }
    var onlineErrorEntryChanged: String { online("출전 정보가 바뀌었어요. 최신 정보를 확인하고 다시 동의해 주세요.", "Your entry changed. Review the latest details and agree again.") }
    var onlineErrorResultUnverified: String { online("전투 결과를 확인하지 못해 체력과 경험치를 반영하지 않았어요.", "The battle result could not be verified, so health and XP were not applied.") }
    var onlineErrorPeerCancelled: String { online("상대가 신청을 취소했어요. 목록에서 다른 동료에게 다시 신청해 보세요.", "Your opponent cancelled the challenge. Pick someone from the list to challenge again.") }
    var onlineErrorPeerExpired: String { online("신청 시간이 지났어요. 상대에게 다시 신청해 달라고 부탁해 보세요.", "The challenge timed out. Ask your opponent to send it again.") }
    /// Maps server error codes the Worker is known to return to a cause plus a next step.
    /// Codes without a sentence here (including `version_mismatch`) fall back to the generic text;
    /// add one `case` once the app needs to explain it.
    func onlineServerError(_ error: OnlineBattleServerError) -> String? {
        switch error.code {
        case .invalidInvite: online("초대코드를 찾을 수 없어요. 코드를 다시 확인해 주세요.", "That invite code was not found. Check the code and try again.")
        case .inviteRevoked: online("방장이 이 초대코드를 회수했어요. 방장에게 새 초대코드를 요청해 주세요.", "The host revoked this invite code. Ask the host for a new one.")
        case .inviteExpired: online("초대코드 유효 시간이 지났어요. 방장에게 새 초대코드를 요청해 주세요.", "This invite code has expired. Ask the host for a new one.")
        case .inviteUsedUp: online("이 초대코드는 사용 횟수를 모두 썼어요. 방장에게 새 초대코드를 요청해 주세요.", "This invite code has no uses left. Ask the host for a new one.")
        case .displayEmailTaken: online("같은 닉네임을 쓰는 동료가 이미 있어요. 다른 닉네임으로 다시 참여해 주세요.", "Someone in the group already uses that nickname. Join again with a different one.")
        case .tooManyAttempts:
            error.retryAfter.map { seconds in online("시도가 너무 많았어요. \(seconds)초 뒤에 다시 시도해 주세요.", "Too many attempts. Try again in \(seconds) seconds.") }
                ?? online("시도가 너무 많았어요. 잠시 뒤에 다시 시도해 주세요.", "Too many attempts. Try again in a moment.")
        default: nil
        }
    }
}
