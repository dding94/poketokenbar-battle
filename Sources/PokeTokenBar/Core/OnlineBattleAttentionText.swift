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
        case .myTurn:
            let seconds = onlineAttentionSeconds(attention, now: now)
            return .init(title: online("내 차례예요", "Your turn"),
                         body: online("\(name)님과의 대전: \(seconds)초 안에 기술을 고르세요", "Battle with \(name): choose a move within \(seconds)s"))
        }
    }

    private func onlineAttentionSeconds(_ attention: OnlineAttention, now: Date) -> Int {
        max(1, Int((attention.deadline ?? now).timeIntervalSince(now).rounded(.up)))
    }
}
