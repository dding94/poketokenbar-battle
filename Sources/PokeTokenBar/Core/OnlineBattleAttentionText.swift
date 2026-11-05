import Foundation

/// In-app wording shared by the menu-bar mark, the banner and the home subtitle.
/// Outcome words stay out on purpose: the mark and subtitle are visible outside the staging gate.
struct OnlineAttentionCopy: Equatable, Sendable {
    let tooltip: String
    let subtitle: String
    let banner: String
}

struct OnlineAttentionNotificationCopy: Equatable, Sendable {
    let title: String
    let body: String
}

extension L {
    func onlineAttentionCopy(_ attention: OnlineAttention, now: Date) -> OnlineAttentionCopy {
        let name = attention.opponentName ?? onlineAnonymous
        let seconds = onlineAttentionSeconds(attention, now: now)
        switch attention.kind {
        case .incomingChallenge:
            return .init(tooltip: online("\(name)님이 대결을 신청했어요", "\(name) challenged you to a battle"),
                         subtitle: online("\(name)님의 대결 신청", "Challenge from \(name)"),
                         banner: online("\(name)님이 대결을 신청했어요. 수락하거나 거절해 주세요.", "\(name) challenged you to a battle. Accept or decline."))
        case .challengeAccepted:
            return .init(tooltip: online("\(name)님이 신청을 수락했어요", "\(name) accepted your challenge"),
                         subtitle: online("\(name)님 수락 · 최종 확인 필요", "\(name) accepted · Confirm next"),
                         banner: online("\(name)님이 신청을 수락했어요. 최종 확인을 눌러 주세요.", "\(name) accepted your challenge. Select Confirm challenge."))
        case .finalConfirmed:
            return .init(tooltip: online("\(name)님과의 대결이 확정됐어요", "Your battle with \(name) is confirmed"),
                         subtitle: online("\(name)님과 대결 확정 · 전투 준비 필요", "Battle with \(name) confirmed · Get ready"),
                         banner: online("\(name)님과의 대결이 확정됐어요. 전투 준비를 눌러 주세요.", "Your battle with \(name) is confirmed. Select Ready for battle."))
        case .myTurn:
            return .init(tooltip: online("\(name)님과 대전 중: \(seconds)초 안에 기술을 고르세요", "Battle with \(name): choose a move within \(seconds)s"),
                         subtitle: online("\(name)님과 대전 중 · 내 차례", "Battling \(name) · Your turn"),
                         banner: online("내 차례예요. \(name)님과의 대전에서 \(seconds)초 안에 기술을 고르세요.", "Your turn against \(name). Choose a move within \(seconds)s."))
        case .rematchRequested:
            return .init(tooltip: online("\(name)님이 다시 겨루자고 해요", "\(name) wants a rematch"),
                         subtitle: online("\(name)님의 재대결 신청", "Rematch request from \(name)"),
                         banner: online("\(name)님이 다시 겨루자고 해요. 수락하거나 거절해 주세요.", "\(name) wants a rematch. Accept or decline."))
        case .requestEnded:
            let summary = onlineEndedSummary(attention.ending, name: name)
            return .init(tooltip: summary, subtitle: summary,
                         banner: attention.ending.flatMap { onlineEndedNotice($0.state, opponent: name, reason: $0.reason) } ?? summary)
        case .matchEnded:
            return .init(tooltip: online("\(name)님과의 대전이 끝났어요", "Your battle with \(name) has ended"),
                         subtitle: online("\(name)님과 대전 종료 · 결과 확인 중", "Battle with \(name) ended · Checking result"),
                         banner: online("\(name)님과의 대전이 끝났어요. 결과를 확인하고 있어요.", "Your battle with \(name) has ended. Checking the result."))
        case .resultReady:
            return .init(tooltip: online("\(name)님과의 대전 결과가 나왔어요", "Your battle result with \(name) is in"),
                         subtitle: online("\(name)님과의 대전 결과 도착", "Result in · \(name)"),
                         banner: online("\(name)님과의 대전 결과가 나왔어요. 눌러서 확인하세요.", "Your battle result with \(name) is in. Open it to see."))
        }
    }

    /// Takes a notice rather than an attention, so in-app kinds have no notification wording at all.
    func onlineAttentionNotificationCopy(_ notice: OnlineAttentionNotice, now: Date) -> OnlineAttentionNotificationCopy {
        let attention = notice.attention
        let name = attention.opponentName ?? onlineAnonymous
        switch notice.kind {
        case .incomingChallenge:
            return .init(title: online("대결 신청", "Battle challenge"),
                         body: online("\(name)님이 대결을 신청했어요", "\(name) challenged you to a battle"))
        case .challengeAccepted:
            return .init(title: online("신청 수락", "Challenge accepted"),
                         body: online("\(name)님이 신청을 수락했어요. 최종 확인을 눌러 주세요", "\(name) accepted your challenge. Select Confirm challenge"))
        case .finalConfirmed:
            return .init(title: online("대결 확정", "Battle confirmed"),
                         body: online("\(name)님과의 대결이 확정됐어요. 전투 준비를 눌러 주세요", "Your battle with \(name) is confirmed. Select Ready for battle"))
        case .rematchRequested:
            return .init(title: online("재대결 신청", "Rematch request"),
                         body: online("\(name)님이 다시 겨루자고 해요", "\(name) wants a rematch"))
        case .requestEnded:
            return .init(title: online("신청 종료", "Challenge ended"), body: onlineEndedSummary(attention.ending, name: name))
        case .myTurn:
            let seconds = onlineAttentionSeconds(attention, now: now)
            return .init(title: online("내 차례예요", "Your turn"),
                         body: online("\(name)님과의 대전: \(seconds)초 안에 기술을 고르세요", "Battle with \(name): choose a move within \(seconds)s"))
        }
    }

    /// One line each. `reason` is on screen while the system dialog is up; `denied` says where to turn notifications back on.
    func onlineNotificationHint(_ hint: OnlineNotificationHint) -> String {
        switch hint {
        case .reason:
            online("알림을 켜 두면 팝오버가 닫혀 있어도 대결 신청과 내 차례를 알려 드려요",
                   "Turn on notifications to hear about challenges and your turn while this window is closed")
        case .undecided:
            online("알림 권한을 아직 고르지 않았어요. 허용하면 닫혀 있을 때도 알려 드려요",
                   "You haven't chosen whether to allow notifications yet. Allow them to hear about requests while this window is closed")
        case .denied:
            online("알림이 꺼져 있어요. 시스템 설정 > 알림에서 켜면 닫혀 있을 때도 알려 드려요",
                   "Notifications are off. Turn them on in System Settings > Notifications to hear about requests while this window is closed")
        }
    }

    /// One line about a room that ended while this person was waiting on it. No advice: the banner adds that.
    private func onlineEndedSummary(_ ending: OnlineAttentionEnding?, name: String) -> String {
        switch ending?.state {
        case .declined: return online("\(name)님이 신청을 거절했어요", "\(name) declined your challenge")
        case .expired: return online("\(name)님과의 신청 시간이 지났어요", "Your challenge with \(name) timed out")
        case .cancelled where ending?.reason == "participant_left":
            return online("\(name)님이 그룹을 떠나 신청이 취소됐어요", "\(name) left the group, so the challenge was cancelled")
        default: return online("\(name)님이 신청을 취소했어요", "\(name) cancelled the challenge")
        }
    }

    private func onlineAttentionSeconds(_ attention: OnlineAttention, now: Date) -> Int {
        max(1, Int((attention.deadline ?? now).timeIntervalSince(now).rounded(.up)))
    }
}

/// What the menu bar shows at the end of its first line for online play.
struct OnlineMenuMark: Equatable, Sendable {
    /// `urgent` is a myTurn with ten seconds or less left: the same mark in another color, with no notification.
    enum Tone: Equatable, Sendable { case attention, urgent, ongoing }
    static let attentionDot = "\u{25CF}"
    static let ongoingDot = "\u{25CB}"
    static let urgentSeconds: TimeInterval = 10
    let text: String
    let tone: Tone
    let tooltip: String
}

extension OnlineAttentionInput {
    /// Rooms the local trainer is playing right now, whether or not anything is asked of them.
    /// A relaunch with the popover closed has no other way to show that a match is still going on.
    var hasOngoingRoom: Bool {
        guard let me = localTrainerID else { return false }
        return battles.contains { ($0.state == .running || $0.state == .reported) && $0.side(for: me) != nil }
    }
}

extension L {
    func onlineMenuMark(_ input: OnlineAttentionInput) -> OnlineMenuMark? {
        let active = OnlineAttentionCalculator.active(input)
        guard let current = active.first else {
            guard input.hasOngoingRoom else { return nil }
            return .init(text: OnlineMenuMark.ongoingDot, tone: .ongoing,
                         tooltip: online("진행 중인 온라인 대전이 있어요", "An online battle is in progress"))
        }
        let urgent = active.contains { attention in
            guard attention.kind == .myTurn, let deadline = attention.deadline else { return false }
            return deadline.timeIntervalSince(input.now) <= OnlineMenuMark.urgentSeconds
        }
        let others = active.count - 1
        let more = others == 0 ? "" : online(" (외 \(others)건)", " (+\(others) more)")
        return .init(text: active.count == 1 ? OnlineMenuMark.attentionDot : OnlineMenuMark.attentionDot + "\(active.count)",
                     tone: urgent ? .urgent : .attention,
                     tooltip: onlineAttentionCopy(current, now: input.now).tooltip + more)
    }

    /// One line under "Online battle" on the home screen.
    /// `polling` is not "reconnecting" here: on a network that blocks the socket it can last, and the HTTP read still brings news worth showing.
    func onlineHomeSubtitle(_ input: OnlineAttentionInput, connection: OnlineBattleConnectionState?) -> String {
        guard let me = input.localTrainerID else {
            return online("동료와 겨루기 · 아직 가입 안 함", "Battle your group · Not joined yet")
        }
        if input.recoveryCodeShowing { return online("복구코드를 저장해 주세요", "Save your recovery code") }
        if input.hostCodeShowing { return online("복사하지 않은 코드가 있어요", "A code is waiting to be copied") }
        if connection == .connecting || connection == .retryWaiting { return online("다시 연결하는 중", "Reconnecting") }
        let active = OnlineAttentionCalculator.active(input)
        if let current = active.first {
            guard current.kind == .incomingChallenge || current.kind == .rematchRequested else {
                return onlineAttentionCopy(current, now: input.now).subtitle
            }
            let received = active.filter { $0.kind == .incomingChallenge || $0.kind == .rematchRequested }.count
            return online("받은 신청 \(received)건", received == 1 ? "1 request received" : "\(received) requests received")
        }
        if input.hasOngoingRoom { return online("진행 중인 대전이 있어요", "A battle is in progress") }
        if let waiting = onlineWaitingLine(input, me: me) { return waiting }
        return connection == .connected
            ? online("동료와 겨루기 · 접속 중", "Battle your group · Online")
            : online("동료와 겨루기", "Battle your group")
    }

    /// Only a room that is still open: past its expiry the server is about to end it, so it is not worth promising a wait.
    /// No mark goes with this line, because nothing is asked of the person.
    private func onlineWaitingLine(_ input: OnlineAttentionInput, me: String) -> String? {
        let waiting = input.battles.filter {
            OnlineAttentionCalculator.isWaiting($0, me: me) && $0.expiresAt / 1000 > input.now.timeIntervalSince1970
        }
        guard let room = waiting.first else { return nil }
        guard waiting.count == 1 else { return online("신청 대기 중 \(waiting.count)건", "\(waiting.count) requests waiting") }
        let other = room.side(for: me) == .p1 ? room.p2.trainerId : room.p1.trainerId
        let name = input.nicknames[other] ?? onlineAnonymous
        return room.state == .pending
            ? online("\(name)님에게 신청 · 응답 대기 중", "Challenged \(name) · Waiting")
            : online("\(name)님의 응답 대기 중", "Waiting for \(name)")
    }

    /// The line at the top of the online screen. Nil before anything has been reported.
    func onlineConnectionLine(_ status: OnlineConnectionStatus) -> String? {
        switch status {
        case .unknown: nil
        case .accessOff: online("키체인 접근이 꺼져 있어요", "Keychain access is off")
        case .accessStopped: online("키체인 접근이 꺼져 있어 온라인 배틀을 중단했어요", "Online battles stopped because Keychain access is off")
        case .connection(.unconfigured): online("서버 주소를 설정해 주세요", "Set the server address")
        case .connection(.credentialsRequired): online("접속 정보가 필요해요", "Sign-in details are needed")
        case .connection(.connecting): online("연결 중", "Connecting")
        case .connection(.connected): online("접속 중", "Connected")
        case .connection(.retryWaiting): online("다시 연결할 때까지 기다리고 있어요", "Waiting to reconnect")
        case .connection(.polling): online("다시 연결하는 중", "Reconnecting")
        case .connection(.replaced): online("다른 기기에서 연결했어요. 다시 열면 연결해요", "Connected from another device. Reopen this window to connect here")
        // Also what a member who was removed sees: their recovery code answers account_left, so it names the invite too.
        case .connection(.revoked): online("접속키를 더 이상 쓸 수 없어요. 복구코드로 다시 연결하거나, 내보내졌다면 새 초대코드로 다시 참여해 주세요", "Your access key no longer works. Reconnect with your recovery code or, if you were removed, join again with a new invite code")
        case .connection(.protocolError): online("서버와 앱 버전을 확인해 주세요", "Check the app and server versions")
        }
    }
}
