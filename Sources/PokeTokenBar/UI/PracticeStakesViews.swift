import SwiftUI

// PR 03C on the practice screens: healing my entry from the selection screen. Plain values: the items, their counts
// and the store's verdicts come from the bag (`PracticeItemBag`).

/// One healing item for the Heal control: how many I own and the store's verdict on my entry.
struct PracticeHealItem: Equatable {
    let kind: ItemKind
    let count: Int
    let verdict: HealingItemVerdict
}

/// The "Heal" control on my entry card below full HP: it opens the healing items the store says work on the entry and
/// uses the one I pick. Without any, it says where to get one. (The selection shows only without a battle, so the
/// store never holds the entry for one here.)
@MainActor
struct PracticeHealControl: View {
    let items: [PracticeHealItem]
    let isOpen: Bool
    let l: L
    let onToggle: () -> Void
    let onUse: (ItemKind) -> Void
    /// false keeps tests offline: the item emoji instead of a downloaded sprite.
    var artwork = false

    /// The items the store says work on the entry, in the order given (shop order, cheapest first).
    static func options(_ items: [PracticeHealItem]) -> [PracticeHealItem] { items.filter { $0.verdict == .usable } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onToggle) {
                Label(l.practiceHeal, systemImage: isOpen ? "chevron.up" : "cross.case.fill")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            if isOpen {
                let options = Self.options(items)
                if options.isEmpty {
                    Text(l.practiceHealNone)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(options, id: \.kind) { option in
                        Button { onUse(option.kind) } label: { row(option.kind, count: option.count) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// One item to use: icon, name and count, and what it does.
    private func row(_ kind: ItemKind, count: Int) -> some View {
        HStack(spacing: 8) {
            ItemIconView(kind: kind, size: 20, artwork: artwork)
            Text(l.itemName(kind)).font(.caption.weight(.semibold)).lineLimit(1)
            Text("×\(count)").font(.caption2.weight(.bold)).foregroundStyle(.secondary).monospacedDigit()
            Spacer(minLength: 4)
            Text(l.battleItemEffectHint(kind)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }
}
