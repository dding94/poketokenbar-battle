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
    /// false keeps tests offline: the item emoji instead of a downloaded sprite.
    var artwork = false

    /// The healing items that would work at `share`, in shop order (cheapest first), with how many I own.
    static func options(share: Double, counts: [ItemKind: Int]) -> [(kind: ItemKind, count: Int)] {
        [ItemKind.potion, .hyperPotion, .revive].compactMap { kind in
            let count = counts[kind] ?? 0
            return BattleItemUse(kind, count: count, healthShare: share) == .usable ? (kind: kind, count: count) : nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onToggle) {
                Label(l.practiceHeal, systemImage: isOpen ? "chevron.up" : "cross.case.fill")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            if isOpen {
                let options = Self.options(share: share, counts: counts)
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
            Group {
                if artwork {
                    ItemIconView(kind: kind, size: 20)
                } else {
                    Text(kind.fallbackEmoji).font(.system(size: 14)).frame(width: 20, height: 20)
                }
            }
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
