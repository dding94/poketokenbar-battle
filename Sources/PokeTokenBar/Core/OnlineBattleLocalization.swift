import Foundation

extension L {
    /// Online battle ships Korean first; other app languages use the English fallback.
    func online(_ ko: String, _ en: String) -> String { lang == .ko ? ko : en }
    var onlineTitle: String { online("온라인 배틀", "Online battle") }
    var onlineSetup: String { online("동료와 정식전 시작하기", "Battle with your group") }
    var onlineServer: String { online("서버 주소", "Server address") }
    var onlineSaveServer: String { online("서버 주소 적용", "Apply server address") }
    var onlineServerHint: String { online("① 방장이 보낸 https:// 서버 주소를 붙여넣고 아래 버튼을 누르세요.", "① Paste the HTTPS server address from your host, then apply it below.") }
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
}
