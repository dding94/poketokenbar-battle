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
        case .denied:
            online("알림이 꺼져 있어요. 시스템 설정 > 알림에서 켜면 닫혀 있을 때도 알려 드려요",
                   "Notifications are off. Turn them on in System Settings > Notifications to hear about requests while this window is closed")
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
    /// `connectionStatus` is the presentation's connection line; only its connected and reconnecting wording is read here.
    func onlineHomeSubtitle(_ input: OnlineAttentionInput, connectionStatus: String) -> String {
        guard input.localTrainerID != nil else {
            return online("동료와 겨루기 · 아직 가입 안 함", "Battle your group · Not joined yet")
        }
        if Self.onlineReconnectingStatuses.contains(connectionStatus) { return online("다시 연결하는 중", "Reconnecting") }
        let active = OnlineAttentionCalculator.active(input)
        if let current = active.first {
            guard current.kind == .incomingChallenge || current.kind == .rematchRequested else {
                return onlineAttentionCopy(current, now: input.now).subtitle
            }
            let received = active.filter { $0.kind == .incomingChallenge || $0.kind == .rematchRequested }.count
            return online("받은 신청 \(received)건", received == 1 ? "1 request received" : "\(received) requests received")
        }
        if input.hasOngoingRoom { return online("진행 중인 대전이 있어요", "A battle is in progress") }
        return connectionStatus == Self.onlineConnectedStatus
            ? online("동료와 겨루기 · 접속 중", "Battle your group · Online")
            : online("동료와 겨루기", "Battle your group")
    }

    /// The wording OnlineBattleSession puts on `connectionStatus` for the connected and the not-yet-connected states.
    static let onlineConnectedStatus = "접속 중"
    static let onlineReconnectingStatuses: Set<String> = ["연결 중", "다시 연결할 때까지 기다리고 있어요"]
}
