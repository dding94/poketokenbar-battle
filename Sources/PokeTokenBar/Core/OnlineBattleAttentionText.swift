import Foundation

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
        .init(tooltip: "", subtitle: "", banner: "")
    }
    func onlineAttentionNotificationCopy(_ notice: OnlineAttentionNotice, now: Date) -> OnlineAttentionNotificationCopy {
        .init(title: "", body: "")
    }
}
