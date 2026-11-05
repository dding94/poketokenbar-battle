import Foundation

/// The host panel's words. Kept out of `OnlineBattleLocalization.swift`, which several online changes edit at once.
extension L {
    var onlineHostOpen: String { online("멤버 관리", "Manage members") }
    var onlineHostTitle: String { online("멤버 관리", "Host tools") }
    var onlineHostBack: String { online("로비로", "Back to lobby") }
    var onlineHostInvitesTitle: String { online("초대코드", "Invite codes") }
    func onlineHostChoice(_ choice: OnlineBattleHostInviteChoice) -> String {
        switch choice {
        case .group: online("30명 · 7일", "30 people · 7 days")
        case .single: online("1회용 · 7일", "Single use · 7 days")
        }
    }
    var onlineHostCreateInvite: String { online("초대코드 만들기", "Create invite code") }
    var onlineHostInviteHint: String {
        online("동료가 앱의 ‘그룹 참여’에 코드를 넣으면 들어와요. 코드는 만든 직후에만 보여요.",
               "Colleagues join by entering the code under Join group. The code is shown only right after you create it.")
    }
    func onlineHostSecretTitle(_ secret: OnlineBattleHostSecret, name: String?) -> String {
        switch secret.kind {
        case .invite: return online("새 초대코드", "New invite code")
        case .reconnect:
            let who = name ?? onlineAnonymous
            return online("\(who)님의 재연결 코드", "Reconnect code for \(who)")
        }
    }
    func onlineHostSecretDetail(_ secret: OnlineBattleHostSecret, name: String?, timeZone: TimeZone = .current) -> String {
        let clock = onlineHostClock(secret.expiresAt, timeZone: timeZone)
        switch secret.kind {
        case .invite(let maxUses):
            if maxUses == 1 { return online("1명만 쓸 수 있고 \(clock)까지 유효해요.", "One person can use it, until \(clock).") }
            return online("최대 \(maxUses)명이 쓸 수 있고 \(clock)까지 유효해요.", "Up to \(maxUses) people can use it, until \(clock).")
        case .reconnect:
            let who = name ?? onlineAnonymous
            return online("\(who)님이 ‘기존 계정 연결’의 재연결 코드 칸에 넣으면 돼요. 한 번만 쓸 수 있고 \(clock)까지 유효해요.",
                          "\(who) enters it under Reconnect your account. It works once, until \(clock).")
        }
    }
    var onlineHostStaysOpen: String {
        online("복사하는 동안 다른 앱을 눌러도 이 창은 닫히지 않아요.", "This window stays open while you copy, even if you click another app.")
    }
    var onlineHostCopy: String { online("복사", "Copy") }
    var onlineHostHide: String { online("숨기기", "Hide") }
    func onlineHostCopied(_ kind: OnlineBattleHostSecret.Kind, name: String?) -> String {
        switch kind {
        case .invite:
            return online("초대코드를 복사하고 화면에서 가렸어요. 다시 볼 수 없으니, 잃어버렸다면 새로 만들고 이전 코드는 회수하세요.",
                          "Invite code copied and hidden. It cannot be shown again; if you lose it, create a new one and revoke this one.")
        case .reconnect:
            let who = name ?? onlineAnonymous
            return online("\(who)님의 재연결 코드를 복사했어요. 다시 볼 수 없으니 필요하면 새로 발급하세요.",
                          "Reconnect code for \(who) copied and hidden. It cannot be shown again; issue a new one if needed.")
        }
    }
    var onlineHostActiveInvites: String { online("사용할 수 있는 초대코드", "Active invite codes") }
    var onlineHostNoInvites: String { online("사용할 수 있는 초대코드가 없어요.", "No active invite codes.") }
    func onlineHostInviteLine(_ invite: OnlineBattleInvite, timeZone: TimeZone = .current) -> String {
        let created = onlineHostClock(invite.createdAt, timeZone: timeZone), until = onlineHostClock(invite.expiresAt, timeZone: timeZone)
        return online("\(created) 발급 · \(invite.uses)/\(invite.maxUses)명 사용 · \(until)까지",
                      "Created \(created) · \(invite.uses)/\(invite.maxUses) used · until \(until)")
    }
    var onlineHostRevoke: String { online("회수", "Revoke") }
    var onlineHostRevoked: String { online("초대코드를 회수했어요. 이 코드로는 더 이상 들어올 수 없어요.", "Invite code revoked. It can no longer be used to join.") }
    var onlineHostInvitesFailed: String { online("초대코드 목록을 불러오지 못했어요.", "Could not load the invite codes.") }
    var onlineHostInvitesLoading: String { online("초대코드 목록을 불러오는 중…", "Loading invite codes…") }
    var onlineHostMembers: String { online("동료", "Members") }
    var onlineHostNoMembers: String {
        online("아직 다른 동료가 없어요. 초대코드를 만들어 동료에게 보내 주세요.", "No other members yet. Create an invite code and send it to them.")
    }
    var onlineHostReissue: String { online("재연결 코드", "Reconnect code") }
    var onlineHostRemove: String { online("제거", "Remove") }
    func onlineHostConfirmRemove(name: String) -> String {
        online("\(name)님을 제거할까요? 진행 중인 신청은 취소되고 접속키가 폐기돼요. 열린 초대코드도 모두 회수돼요.",
               "Remove \(name)? Their open challenges are cancelled and their access key is revoked. Every open invite code is revoked too.")
    }
    var onlineHostConfirmRemoveButton: String { online("제거하기", "Yes, remove") }
    var onlineHostCancelRemove: String { online("취소", "Cancel") }
    /// The server revokes every open invite with a removal; the result says how many that was.
    func onlineHostRemoved(name: String, revokedInvites: Int) -> String {
        guard revokedInvites > 0 else {
            return online("\(name)님을 제거했어요. 회수할 열린 초대코드는 없었어요.", "\(name) was removed. There were no open invite codes to revoke.")
        }
        let en = revokedInvites == 1 ? "1 open invite code was" : "\(revokedInvites) open invite codes were"
        return online("\(name)님을 제거했어요. 열린 초대코드 \(revokedInvites)개도 함께 회수했어요. 필요하면 새 코드를 만드세요.",
                      "\(name) was removed. \(en) revoked with it; create a new one if needed.")
    }
    /// Refusals the host panel can explain by itself. Anything else falls back to the general notice.
    func onlineHostServerError(_ error: OnlineBattleServerError) -> String? {
        switch error.code {
        case .forbidden: online("방장만 할 수 있어요. 방장이 바뀌었는지 확인해 주세요.", "Only the host can do this. Check whether the host changed.")
        case .notFound: online("대상을 찾지 못했어요. 이미 나갔거나 회수됐을 수 있어요. 목록을 새로 읽을게요.", "Could not find it. It may have left or been revoked already. Reloading the list.")
        case .cannotTargetSelf: online("나 자신에게는 쓸 수 없어요.", "This cannot be used on yourself.")
        default: nil
        }
    }
    private func onlineHostClock(_ milliseconds: Double, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: lang == .ko ? "ko_KR" : "en_US_POSIX")
        formatter.dateFormat = lang == .ko ? "M월 d일 HH:mm" : "MMM d, HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: milliseconds / 1000))
    }
}
