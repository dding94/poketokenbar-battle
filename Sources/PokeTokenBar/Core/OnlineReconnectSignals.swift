import AppKit

/// Says when the Mac may have a usable network again: on wake and when the network comes back.
/// It owns its own monitor because `NetworkReachabilityMonitor` has room for one listener.
@MainActor
final class OnlineReconnectSignals {
    let network = NetworkReachabilityMonitor()
    private let center: NotificationCenter
    private let signal: @MainActor @Sendable (OnlineBattleReconnectReason) async -> Void
    private var wakeObserver: NSObjectProtocol?

    init(center: NotificationCenter = NSWorkspace.shared.notificationCenter,
         signal: @escaping @MainActor @Sendable (OnlineBattleReconnectReason) async -> Void) {
        self.center = center; self.signal = signal
    }

    func start() {
        guard wakeObserver == nil else { return }
        let signal = signal
        wakeObserver = center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in await signal(.wake) }
        }
        network.onReconnected = { Task { @MainActor in await signal(.network) } }
        network.start()
    }
}
