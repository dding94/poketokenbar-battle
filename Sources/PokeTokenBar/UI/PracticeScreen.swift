import SwiftUI

/// The local practice battle inside the popover: selection → battle → result. It replaces the whole
/// popover content like Settings and Recap, at the same height as the tabs so the popover does not jump.
@MainActor
struct PracticeScreen: View {
    let session: PracticeSession
    let l: L
    /// false keeps tests offline: no sprite downloads and no PokéAPI name lookups.
    var artwork = true
    let onClose: () -> Void

    init(session: PracticeSession, l: L, artwork: Bool = true, onClose: @escaping () -> Void) {
        self.session = session; self.l = l; self.artwork = artwork; self.onClose = onClose
    }

    var body: some View {
        Color.clear.frame(width: PopoverMetrics.width, height: 1)
    }
}
