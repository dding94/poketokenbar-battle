import AppKit
import SwiftUI

/// The host's group care: invite codes, members, reconnect codes. Drawn instead of the lobby while it is open.
@MainActor
struct OnlineBattleHostPanel: View {
    let model: OnlineBattlePresentation
    let l: L
    var writeClipboard: (String) -> Bool = { _ in false }

    /// Puts the shown code on the clipboard; only then does the screen forget it.
    func copySecret() {}

    var body: some View { EmptyView() }
}
