import Foundation

/// What the app can say about macOS notification permission. Nothing else about the system leaks past this.
enum OnlineNotificationPermission: Equatable, Sendable { case notDetermined, denied, allowed }

/// The one-line in-app explanation of notifications, shown on the online screen and the home row.
enum OnlineNotificationHint: Equatable, Sendable {
    /// Shown while the system permission dialog is up, so the person knows why it appeared.
    case reason
    /// Permission is off: say where to turn it on. The menu-bar mark stays the base channel.
    case denied
}

struct OnlineNotificationRequest: Equatable, Sendable {
    let identifier: String
    let battleId: String
    let title: String
    let body: String
}

/// The slice of UNUserNotificationCenter the online notifier needs; tests use a fake.
@MainActor
protocol OnlineNotificationCenter: AnyObject {
    func permission() async -> OnlineNotificationPermission
    func requestPermission() async -> Bool
    func add(_ request: OnlineNotificationRequest) async
    func withdraw(identifiers: [String])
}

/// Persisted next to the online settings. Battle ids and revisions only: no keys, codes or nicknames.
struct OnlineAttentionState: Codable, Equatable, Sendable {
    var seen = OnlineAttentionSeenRecord()
    /// True once the permission question was settled (asked, or already answered), so it is never asked twice.
    var permissionHandled = false
}

protocol OnlineAttentionStateStoring: Sendable {
    func load() -> OnlineAttentionState
    func save(_ state: OnlineAttentionState) throws
}

struct OnlineAttentionStateFile: OnlineAttentionStateStoring {
    let directory: URL
    func load() -> OnlineAttentionState { OnlineAttentionState() }
    func save(_ state: OnlineAttentionState) throws {}
}

@MainActor
final class OnlineAttentionNotifier {
    static let userInfoBattleKey = "ptbOnlineBattleId"

    init(center: any OnlineNotificationCenter, store: any OnlineAttentionStateStoring, l: @escaping () -> L,
         setHint: @escaping (OnlineNotificationHint?) -> Void) {}

    func handle(_ input: OnlineAttentionInput, popoverOpen: Bool) async {}
    func refreshPermissionHint() async {}

    nonisolated static func battleId(fromUserInfo userInfo: [AnyHashable: Any]) -> String? { nil }
}
