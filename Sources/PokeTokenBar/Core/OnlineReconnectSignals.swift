import AppKit

/// Says when the Mac may have a usable network again: on wake and when the network comes back.
/// It owns its own monitor because `NetworkReachabilityMonitor` has room for one listener.
@MainActor
final class OnlineReconnectSignals {
    let network = NetworkReachabilityMonitor()
    private let center: NotificationCenter
    private let signal: @MainActor @Sendable (OnlineBattleReconnectReason) -> Void

    init(center: NotificationCenter = NSWorkspace.shared.notificationCenter,
         signal: @escaping @MainActor @Sendable (OnlineBattleReconnectReason) -> Void) {
        self.center = center; self.signal = signal
    }

    func start() {}
    func stop() {}
}
