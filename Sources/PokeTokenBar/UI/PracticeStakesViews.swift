import SwiftUI

// PR 03C on the practice screens: healing my entry from the selection screen. Plain values: the item counts come
// from the bag (`PracticeItemBag`), the HP share from the session.

/// The "Heal" control on my entry card below full HP: it opens the healing items I own that would work on the entry
/// and uses the one I pick. Without any, it says where to get one.
@MainActor
struct PracticeHealControl: View {
    let share: Double
    let counts: [ItemKind: Int]
    let isOpen: Bool
    let l: L
    let onToggle: () -> Void
    let onUse: (ItemKind) -> Void

    /// The healing items that would work at `share`, in shop order (cheapest first), with how many I own.
    static func options(share: Double, counts: [ItemKind: Int]) -> [(kind: ItemKind, count: Int)] { [] }   // RED stub

    var body: some View { EmptyView() }   // RED stub
}
