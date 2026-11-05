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
    /// The system question is still unanswered: nothing is off, so it must not read like `denied`.
    case undecided
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
    var waits = OnlineAttentionWaitRecord()

    private enum CodingKeys: String, CodingKey { case seen, permissionHandled, waits }
}

extension OnlineAttentionState {
    /// Builds before the wait record wrote only the first two fields. A synthesized decoder would throw that file away,
    /// and the upgrade would ask for the permission again and announce everything once more.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        seen = try container.decode(OnlineAttentionSeenRecord.self, forKey: .seen)
        permissionHandled = try container.decode(Bool.self, forKey: .permissionHandled)
        waits = try container.decodeIfPresent(OnlineAttentionWaitRecord.self, forKey: .waits) ?? .init()
    }
}

/// What macOS may show for a notification that arrives while the app is active. Without an answer it shows nothing,
/// and a popover closed with X or Esc leaves this menu bar app active until another app is clicked.
enum OnlineNotificationForeground {
    /// `battleId` is nil for the usage-limit and companion alerts, which share the delegate and are always shown.
    /// An online one already `add`ed when the popover came forward is the banner's now, so it is not shown twice.
    static func options(battleId: String?, attentionInFront: Bool) -> UNNotificationPresentationOptions {
        battleId != nil && attentionInFront ? [] : [.banner, .sound]
    }
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
    private let syncEnded: (_ unread: Set<String>, _ read: [String]) -> Void
    private var state: OnlineAttentionState
    private var settlingPermission = false

    init(center: any OnlineNotificationCenter, store: any OnlineAttentionStateStoring, l: @escaping () -> L,
         setHint: @escaping (OnlineNotificationHint?) -> Void,
         syncEnded: @escaping (_ unread: Set<String>, _ read: [String]) -> Void = { _, _ in }) {
        self.syncEnded = syncEnded
        self.center = center
        self.store = store
        self.l = l
        self.setHint = setHint
        state = store.load()
    }

    /// Call on every presentation change. The record is updated and saved before anything is awaited, so
    /// two overlapping calls can never announce the same occurrence twice.
    func handle(_ input: OnlineAttentionInput, popoverOpen: Bool) async {
        var input = input
        var waits = OnlineAttentionCalculator.trackWaits(input, record: state.waits)
        // An ending that reaches the open lobby is read: the lobby says it as its own notice. Only listed rooms can be told.
        let listed = Set(input.battles.map(\.battleId))
        let read = OnlineAttentionCalculator.lobbyIsShowing(input) ? waits.unreadEnded.map(\.battleId).filter { listed.contains($0) } : []
        waits.unreadEnded.removeAll { read.contains($0.battleId) }
        state.waits = waits
        input.unreadEndedBattleIDs = waits.unreadIDs
        syncEnded(waits.unreadIDs, read)
        let evaluation = OnlineAttentionCalculator.evaluate(input, seen: state.seen)
        state.seen = evaluation.seen
        persist()
        if !evaluation.resolved.isEmpty { center.withdraw(identifiers: evaluation.resolved.map(\.notificationIdentifier)) }
        if popoverOpen, input.localTrainerID != nil, !state.permissionHandled { await settlePermission() }
        // A popover in front says it itself, as the banner or as the room on screen, so it is marked seen above and never announced later.
        guard !popoverOpen, !evaluation.notices.isEmpty else { return }
        switch await center.permission() {
        case .allowed: break
        case .denied: setHint(.denied); return
        case .notDetermined: setHint(.undecided); return
        }
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
    // The async calls stay nonisolated: the center is not Sendable, and a completion-handler closure written in a
    // main-actor method would inherit that isolation and trap when the framework calls it on its own queue.
    nonisolated func permission() async -> OnlineNotificationPermission {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized, .provisional, .ephemeral: .allowed
        @unknown default: .denied
        }
    }

    nonisolated func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    nonisolated func add(_ request: OnlineNotificationRequest) async {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.sound = .default
        content.threadIdentifier = "online-attention.\(request.battleId)"
        content.userInfo = [OnlineAttentionNotifier.userInfoBattleKey: request.battleId]
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: request.identifier, content: content, trigger: nil))
    }

    func withdraw(identifiers: [String]) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}
