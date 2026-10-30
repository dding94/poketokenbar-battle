import SwiftUI

// PR 03C battle items and HP in the popover: what the practice screens may do with the bag, the line for the store's
// verdict on a healing item, HP as a bar or "Fainted", and the IV reroll's two steps. Everything but the store glue at
// the top takes plain values. Practice files use these views but never name the store (practice read-only guard).

/// What the practice screens may do with the bag: count battle items, ask the store whether a healing item works on
/// one individual (`HealingItemVerdict`, the store's one rule) and use it. `CompanionStore` conforms below, outside the
/// practice files.
@MainActor
protocol PracticeItemBag: AnyObject {
    func itemCount(_ kind: ItemKind) -> Int
    func healingItemVerdict(_ kind: ItemKind, on instanceID: String) -> HealingItemVerdict
    @discardableResult func useHealingItem(_ kind: ItemKind, on instanceID: String) -> Bool
}

extension HealingItemVerdict {
    /// The line in place of Use when the item does not work now; nil when it does, or when there is nothing to say
    /// (not a healing item, none left: the bag lists only what it holds).
    func reason(_ l: L) -> String? {
        switch self {
        case .usable, .notHealing, .noneLeft: nil
        case .inBattle: l.battleItemInBattle
        case .needsRevive: l.battleItemNeedsRevive
        case .hpFull: l.battleItemFullHealth
        case .notFainted: l.battleItemOnlyFainted
        }
    }
}

extension CompanionStore: PracticeItemBag {
    /// The current Pokémon's individual; nil for an egg or before its profile exists.
    var currentInstanceID: String? { state.active?.profile?.instanceID }
    /// The current Pokémon's six IVs, for the reroll's confirm; nil without a profile.
    var currentIVs: PokemonIVs? { state.active?.profile?.ivs }
    /// The current Pokémon's HP share between battles (1 = full, 0 = fainted); nil without one.
    var currentHealthShare: Double? { currentInstanceID.map { healthShare(of: $0) } }
}

/// HP shares as the screens show them.
enum BattleHealth {
    /// 0 only when fainted and 100 only when full: a scratch reads 99%, a sliver 1%.
    static func percent(_ share: Double) -> Int {
        if share <= 0 { return 0 }
        if share >= 1 { return 100 }
        return min(99, max(1, Int((share * 100).rounded())))
    }
}

/// HP as a thin bar and a percentage, or a gray "Fainted" tag at 0.
@MainActor
struct BattleHealthLine: View {
    let share: Double
    let l: L

    var body: some View {
        if share <= 0 {
            BattleFaintedTag(l: l)
        } else {
            let percent = BattleHealth.percent(share)
            HStack(spacing: 6) {
                // The practice HP bar on a fixed scale: it eases once when the share changes.
                PracticeHPBar(hp: Int((share * 1000).rounded()), maxHP: 1000, height: 5)
                    .frame(minWidth: 40, maxWidth: 140)
                Text("\(percent)%")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(l.battleHP)
            .accessibilityValue("\(percent)%")
        }
    }
}

/// "기절" / "Fainted" in a small gray capsule.
@MainActor
struct BattleFaintedTag: View {
    let l: L

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "heart.slash.fill").font(.system(size: 8, weight: .bold))
            Text(l.battleFainted)
        }
        .font(.system(size: 10, weight: .bold))
        .lineLimit(1)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6).padding(.vertical, 1)
        .background(Color.secondary.opacity(0.16), in: Capsule())
        .fixedSize()
    }
}

/// The six IVs in two rows of three with their stat names; with `previous`, an arrow shows how each one moved.
@MainActor
struct IVGrid: View {
    let ivs: PokemonIVs
    var previous: PokemonIVs?
    let l: L

    enum Change: Equatable { case up, down, same }

    /// How one IV moved since `previous`; nil without one.
    static func change(_ stat: String, from previous: PokemonIVs?, to ivs: PokemonIVs) -> Change? {
        guard let previous else { return nil }
        let before = previous[stat], after = ivs[stat]
        return after > before ? .up : after < before ? .down : .same
    }

    private static let rows = [Array(PokemonStatCalculator.order.prefix(3)), Array(PokemonStatCalculator.order.suffix(3))]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            ForEach(Self.rows, id: \.self) { stats in
                GridRow {
                    ForEach(stats, id: \.self) { stat in cell(stat) }
                }
            }
        }
        .font(.caption)
    }

    private func cell(_ stat: String) -> some View {
        HStack(spacing: 4) {
            Text(l.statLabel(stat)).foregroundStyle(.secondary).lineLimit(1)
            Text("\(ivs[stat])").fontWeight(.semibold).monospacedDigit()
            if let change = Self.change(stat, from: previous, to: ivs), change != .same {
                Image(systemName: change == .up ? "arrow.up" : "arrow.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(change == .up ? Color.green : Color.red)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// What the last battle item used in the bag did: the HP it left the current Pokémon with, or the IVs a reroll drew.
enum BattleItemFeedback: Equatable {
    case healed(ItemKind, share: Double)
    case rerolled(old: PokemonIVs, new: PokemonIVs)
}

/// The bag's top card for `BattleItemFeedback` until it is closed. It sits outside the item cards because using the
/// last one of a kind removes its card, and the result must stay.
@MainActor
struct BattleItemFeedbackCard: View {
    let feedback: BattleItemFeedback
    let l: L
    var artwork = true
    let onClose: () -> Void

    var body: some View {
        switch feedback {
        case .healed(let kind, let share):
            HStack(spacing: 8) {
                ItemIconView(kind: kind, size: 22, artwork: artwork)
                Text(l.itemName(kind)).font(.callout.weight(.semibold)).lineLimit(1)
                Image(systemName: "arrow.right").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                BattleHealthLine(share: share, l: l)
                Spacer(minLength: 4)
                Button(l.close, action: onClose).buttonStyle(.borderless).controlSize(.small)
            }
            .padding(10)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        case .rerolled(let old, let new):
            IVRerollPanel(stage: .result(old: old, new: new), l: l, onReroll: {}, onCancel: {}, onDone: onClose)
        }
    }
}

/// The IV reroll's two steps in the bag: the current six with a warning that they may drop, then the new six with
/// how each moved. The bag owns the step and calls `useIVReroll()`.
@MainActor
struct IVRerollPanel: View {
    enum Stage: Equatable {
        case confirm(current: PokemonIVs)
        case result(old: PokemonIVs, new: PokemonIVs)
    }

    let stage: Stage
    let l: L
    let onReroll: () -> Void
    let onCancel: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            switch stage {
            case .confirm(let current):
                Text(l.ivRerollCurrent).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                IVGrid(ivs: current, l: l)
                Label {
                    Text(l.ivRerollMayDrop)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.caption.weight(.semibold))
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button(l.cancel, action: onCancel).buttonStyle(.borderless)
                    Button(l.ivRerollAction, action: onReroll).buttonStyle(.borderedProminent)
                }
                .controlSize(.regular)
            case .result(let old, let new):
                Text(l.ivRerollNew).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                IVGrid(ivs: new, previous: old, l: l)
                HStack {
                    Spacer(minLength: 0)
                    Button(l.close, action: onDone).buttonStyle(.bordered)
                }
                .controlSize(.small)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}
