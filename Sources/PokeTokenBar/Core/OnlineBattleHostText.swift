import Foundation

/// The host panel's words. Kept out of `OnlineBattleLocalization.swift`, which several online changes edit at once.
extension L {
    var onlineHostOpen: String { "" }
    var onlineHostTitle: String { "" }
    var onlineHostBack: String { "" }
    var onlineHostInvitesTitle: String { "" }
    func onlineHostChoice(_ choice: OnlineBattleHostInviteChoice) -> String { "" }
    var onlineHostCreateInvite: String { "" }
    var onlineHostInviteHint: String { "" }
    func onlineHostSecretTitle(_ secret: OnlineBattleHostSecret, name: String?) -> String { "" }
    func onlineHostSecretDetail(_ secret: OnlineBattleHostSecret, name: String?, timeZone: TimeZone = .current) -> String { "" }
    var onlineHostStaysOpen: String { "" }
    var onlineHostCopy: String { "" }
    var onlineHostHide: String { "" }
    func onlineHostCopied(_ kind: OnlineBattleHostSecret.Kind, name: String?) -> String { "" }
    var onlineHostActiveInvites: String { "" }
    var onlineHostNoInvites: String { "" }
    func onlineHostInviteLine(_ invite: OnlineBattleInvite, timeZone: TimeZone = .current) -> String { "" }
    var onlineHostRevoke: String { "" }
    var onlineHostRevoked: String { "" }
    var onlineHostInvitesFailed: String { "" }
    var onlineHostInvitesLoading: String { "" }
    var onlineHostMembers: String { "" }
    var onlineHostNoMembers: String { "" }
    var onlineHostReissue: String { "" }
    var onlineHostRemove: String { "" }
    func onlineHostConfirmRemove(name: String) -> String { "" }
    var onlineHostConfirmRemoveButton: String { "" }
    var onlineHostCancelRemove: String { "" }
    func onlineHostRemoved(name: String, revokedInvites: Int) -> String { "" }
    func onlineHostServerError(_ error: OnlineBattleServerError) -> String? { nil }
}
