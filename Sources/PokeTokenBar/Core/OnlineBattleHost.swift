import Foundation

/// How many people one new invite code admits. Both choices last seven days (the host decision of 2026-10-30).
enum OnlineBattleHostInviteChoice: Equatable, Sendable, CaseIterable {
    case group, single
    static let ttlSeconds = 7 * 24 * 60 * 60
    var maxUses: Int { self == .single ? 1 : 30 }
}

/// A code the screen shows once so the host can copy it to someone else: a new invite code, or a one-time
/// reconnect code for a member. It lives only in memory, is never encoded, and never prints.
struct OnlineBattleHostSecret: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    enum Kind: Equatable, Sendable { case invite(maxUses: Int), reconnect(trainerId: String) }
    let kind: Kind
    let code: String
    /// Server clock, milliseconds since 1970.
    let expiresAt: Double
    var description: String { "OnlineBattleHostSecret(redacted)" }
    var debugDescription: String { description }
}

/// Everything the host panel shows and holds. Reset whenever the account changes or the person is no longer the host.
struct OnlineBattleHostState {
    var visible = false
    /// Every invite the server lists; nil until the first read.
    var invites: [OnlineBattleInvite]?
    var invitesFailed = false
    var choice: OnlineBattleHostInviteChoice = .group
    /// Shown until it is copied or hidden. While it shows, the popover stays open (`OnlinePopoverPinning`).
    var secret: OnlineBattleHostSecret?
    /// What was just copied. The code itself is gone by then; only the fact stays.
    var copied: OnlineBattleHostSecret.Kind?
    /// The member the host asked to remove and has not yet confirmed.
    var pendingRemoval: String?
    var busy = false
    var notice: String?

    mutating func close() { self = .init() }

    /// Invites still usable at `now` (milliseconds since 1970 on the server's clock), newest first.
    func activeInvites(now: Date = Date()) -> [OnlineBattleInvite] {
        (invites ?? []).filter { $0.isActive(now: now) }
            .sorted { $0.createdAt == $1.createdAt ? $0.inviteId < $1.inviteId : $0.createdAt > $1.createdAt }
    }
}

extension OnlineBattleInvite {
    func isActive(now: Date = Date()) -> Bool {
        !revoked && expiresAt > now.timeIntervalSince1970 * 1000 && uses < maxUses
    }
}

/// What the host can ask for. The pure ones change only what is on screen and never reach the session.
enum OnlineBattleHostAction: Equatable {
    case open, close, refreshInvites
    case chooseInvite(OnlineBattleHostInviteChoice), createInvite(OnlineBattleHostInviteChoice)
    case revokeInvite(String), issueReconnect(String)
    /// Removing a member takes two steps: ask, then confirm the same member.
    case askRemove(String), cancelRemove, confirmRemove(String)
    /// The code reached the clipboard: the screen forgets it. `dismissSecret` forgets it without a copy.
    case copied, dismissSecret, dismissNotice
}

extension OnlineBattleHostSecret {
    /// What goes to the clipboard. A build that fixes the server needs only the code; a manual build adds the
    /// address on labelled lines, which the join form's paste understands.
    func clipboardText(server: String?, l: L) -> String {
        guard case .invite = kind, let server, !server.isEmpty else { return code }
        return l.online("서버 주소: \(server)\n초대코드: \(code)", "Server address: \(server)\nInvite code: \(code)")
    }
}
