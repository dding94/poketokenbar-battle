import Foundation
import UserNotifications

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

/// `online-attention-state.json` in the online state folder. Never the game save.
struct OnlineAttentionStateFile: OnlineAttentionStateStoring {
    static let fileName = "online-attention-state.json"
    let directory: URL
    private var url: URL { directory.appendingPathComponent(Self.fileName) }

    /// A missing or unreadable file starts clean: at worst one event is announced twice, and nothing crashes.
    func load() -> OnlineAttentionState {
        guard let data = try? Data(contentsOf: url), let state = try? JSONDecoder().decode(OnlineAttentionState.self, from: data) else {
            return OnlineAttentionState()
        }
        return state
    }

    func save(_ state: OnlineAttentionState) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Decides what reaches macOS notifications. Notifications are the second channel: the menu-bar mark from
/// the same attention input is the base, so every path here fails quietly and never blocks the app.
@MainActor
final class OnlineAttentionNotifier {
    nonisolated static let userInfoBattleKey = "ptbOnlineBattleId"

    private let center: any OnlineNotificationCenter
    private let store: any OnlineAttentionStateStoring
    private let l: () -> L
    private let setHint: (OnlineNotificationHint?) -> Void
    private var state: OnlineAttentionState
    private var settlingPermission = false

    init(center: any OnlineNotificationCenter, store: any OnlineAttentionStateStoring, l: @escaping () -> L,
         setHint: @escaping (OnlineNotificationHint?) -> Void) {
        self.center = center
        self.store = store
        self.l = l
        self.setHint = setHint
        state = store.load()
    }

    /// Call on every presentation change. The record is updated and saved before anything is awaited, so
    /// two overlapping calls can never announce the same occurrence twice.
    func handle(_ input: OnlineAttentionInput, popoverOpen: Bool) async {
        let evaluation = OnlineAttentionCalculator.evaluate(input, seen: state.seen)
        state.seen = evaluation.seen
        persist()
        if !evaluation.resolved.isEmpty { center.withdraw(identifiers: evaluation.resolved.map(\.notificationIdentifier)) }
        if popoverOpen, input.localTrainerID != nil, !state.permissionHandled { await settlePermission() }
        // An open popover already shows the event, so it is marked seen above and never announced later.
        guard !popoverOpen, !evaluation.notices.isEmpty else { return }
        guard await center.permission() == .allowed else { setHint(.denied); return }
        let copy = l()
        for notice in evaluation.notices {
            let text = copy.onlineAttentionNotificationCopy(notice, now: input.now)
            await center.add(.init(identifier: notice.attention.key.notificationIdentifier, battleId: notice.attention.battleId,
                                   title: text.title, body: text.body))
        }
    }

    /// The person may flip the setting in System Settings at any time, so the popover re-reads it when it opens.
    func refreshPermissionHint() async {
        switch await center.permission() {
        case .denied: setHint(.denied)
        case .allowed: setHint(nil)
        case .notDetermined: break
        }
    }

    /// Asks once. The reason goes on screen first and stays until the system dialog is answered.
    private func settlePermission() async {
        guard !settlingPermission else { return }
        settlingPermission = true
        defer { settlingPermission = false }
        switch await center.permission() {
        case .notDetermined:
            setHint(.reason)
            let granted = await center.requestPermission()
            setHint(granted ? nil : .denied)
        case .denied:
            setHint(.denied)
        case .allowed:
            setHint(nil)
        }
        state.permissionHandled = true
        persist()
    }

    /// A failed save keeps the in-memory record, so nothing is re-announced during this run.
    private func persist() { try? store.save(state) }

    nonisolated static func battleId(fromUserInfo userInfo: [AnyHashable: Any]) -> String? {
        guard let id = userInfo[userInfoBattleKey] as? String, !id.isEmpty else { return nil }
        return id
    }
}

/// UNUserNotificationCenter behind the protocol. Callers must check `AppEnv.isBundledApp` first:
/// `current()` traps in a raw `swift run` binary. Authorization is shared with the usage-limit alerts.
@MainActor
final class SystemOnlineNotificationCenter: OnlineNotificationCenter {
    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }

    func permission() async -> OnlineNotificationPermission {
        // The settings object is not Sendable, so only its status crosses back (Swift 6.1 rejects the async form).
        let center = center
        let status = await withCheckedContinuation { (continuation: CheckedContinuation<UNAuthorizationStatus, Never>) in
            center.getNotificationSettings { continuation.resume(returning: $0.authorizationStatus) }
        }
        switch status {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized, .provisional, .ephemeral: .allowed
        @unknown default: .denied
        }
    }

    func requestPermission() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func add(_ request: OnlineNotificationRequest) async {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.sound = .default
        content.threadIdentifier = "online-attention.\(request.battleId)"
        content.userInfo = [OnlineAttentionNotifier.userInfoBattleKey: request.battleId]
        try? await center.add(UNNotificationRequest(identifier: request.identifier, content: content, trigger: nil))
    }

    func withdraw(identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}
