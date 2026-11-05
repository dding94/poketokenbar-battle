import Foundation

/// Room-guide wording. It only says what this app knows: an opponent shown as online may still be
/// away, so nothing here promises that the other side has seen anything.
extension L {
    func onlineStepName(_ step: OnlineRoomStep) -> String {
        switch step {
        case .request: online("신청", "Request")
        case .accept: online("수락", "Accept")
        case .confirm: online("최종 확인", "Confirm")
        case .ready: online("전투 준비", "Ready")
        }
    }
    /// Spoken state of one step in the progress bar, for VoiceOver.
    func onlineStepState(done: Bool, current: Bool) -> String {
        done ? online("완료", "Done") : current ? online("지금 단계", "Current step") : online("아직", "Not yet")
    }
    func onlineRoomGuide(_ progress: OnlineRoomProgress, opponent: String?) -> String {
        let name = opponent ?? onlineAnonymous
        switch (progress.step, progress.turn) {
        case (.accept, .mine):
            return online("내 차례: \(name)님의 신청을 수락하거나 거절해 주세요", "Your turn: accept or decline the challenge from \(name)")
        case (.accept, _):
            return online("\(name)님의 수락을 기다려요", "Waiting for \(name) to accept")
        case (.confirm, .mine):
            return online("내 차례: 최종 확인을 눌러 주세요", "Your turn: select Confirm challenge")
        case (.confirm, _):
            return online("\(name)님의 최종 확인을 기다려요", "Waiting for \(name) to confirm")
        case (.ready, .mine):
            return online("내 차례: 전투 준비를 눌러 주세요", "Your turn: select Ready for battle")
        case (.ready, .theirs):
            return online("내 준비 완료 · \(name)님의 준비를 기다려요", "You're ready · waiting for \(name)")
        case (.ready, .none), (.request, _):
            return online("양쪽 준비 완료 · 전투 시작을 기다려요", "Both ready · waiting for the battle to start")
        }
    }
    func onlineActionBlock(_ block: OnlineActionBlock) -> String {
        switch block {
        case .busy: online("처리하고 있어요. 잠시 기다려 주세요.", "Working. Please wait.")
        case .noOpponent: online("상대를 선택하세요", "Select an opponent")
        case .noEntry: online("출전 포켓몬을 고르세요", "Pick your Pokémon")
        case .fainted: online("기절한 포켓몬은 회복이 필요해요", "A fainted Pokémon needs healing first")
        case .held: online("이 포켓몬은 다른 정식전에 출전 중이에요", "This Pokémon is entered in another battle")
        case .entryUnavailable: online("이 포켓몬은 지금 출전할 수 없어요", "This Pokémon can't enter right now")
        case .connecting: online("서버에 연결하는 중…", "Connecting to the server…")
        case .reconnecting: online("서버에 다시 연결하는 중…", "Reconnecting to the server…")
        case .replaced: online("다른 기기에서 접속 중이에요. 팝오버를 닫았다가 다시 열면 여기로 연결해요",
                               "Connected from another device. Close and reopen this window to connect here")
        case .versionMismatch: online("서버와 앱 버전을 확인해 주세요", "Check the app and server versions")
        case .signInNeeded: online("접속 정보가 필요해요", "Sign-in details are needed")
        }
    }
    func onlineRoomVersus(_ opponent: String?) -> String {
        let name = opponent ?? onlineAnonymous
        return online("\(name)님과의 정식전", "Official battle with \(name)")
    }
    func onlineRequestSent(opponent: String?) -> String {
        let name = opponent ?? onlineAnonymous
        return online("\(name)님에게 신청을 보냈어요", "Challenge sent to \(name)")
    }
    func onlineRequestAge(seconds: Int) -> String {
        let minutes = max(0, seconds) / 60
        if minutes < 1 { return online("방금 보냈어요", "Just sent") }
        if minutes < 60 { return online("신청한 지 \(minutes)분 지났어요", "Sent \(minutes) min ago") }
        let hours = minutes / 60
        return online("신청한 지 \(hours)시간 지났어요", "Sent \(hours) h ago")
    }
    var onlineOwnReady: String { online("내 준비 완료 · 상대 대기 중", "You're ready · waiting for opponent") }
    func onlineOpponentOffline(_ opponent: String?) -> String {
        let name = opponent ?? onlineAnonymous
        return online("\(name)님은 오프라인이에요. 신청은 보낼 수 있지만 언제 확인할지는 알 수 없어요",
                      "\(name) is offline. You can still send a challenge, but it may be a while before they respond")
    }
}
