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

/// What the last item used from the bag's target list did, and to whom: the HP it left, the IVs a reroll drew, or the
/// nature a Mint gave someone other than the current Pokémon (the current one shows that on Home).
enum BattleItemFeedback: Equatable {
    case healed(ItemKind, name: String, share: Double)
    case rerolled(name: String, old: PokemonIVs, new: PokemonIVs)
    case natureChanged(name: String, nature: PokemonNature)
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
        case .healed(let kind, let name, let share):
            row(kind, name: name) { BattleHealthLine(share: share, l: l) }
        case .rerolled(let name, let old, let new):
            IVRerollPanel(stage: .result(old: old, new: new), l: l, targetName: name, onReroll: {}, onCancel: {}, onDone: onClose)
        case .natureChanged(let name, let nature):
            row(.mint, name: name) {
                Text(nature.name(l.lang)).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private func row(_ kind: ItemKind, name: String, @ViewBuilder result: () -> some View) -> some View {
        HStack(spacing: 8) {
            ItemIconView(kind: kind, size: 22, artwork: artwork)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.callout.weight(.semibold)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(l.itemName(kind)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    Image(systemName: "arrow.right").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                    result()
                }
            }
            Spacer(minLength: 4)
            Button(l.close, action: onClose).buttonStyle(.borderless).controlSize(.small)
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// The owned individuals an item can go to: who it works on, each with a Use button, and below them who a reason keeps
/// from it. The list scrolls past `visibleRows`, and its rows are lazy so a long dex loads only the sprites on screen.
@MainActor
struct ItemTargetPicker: View {
    let kind: ItemKind
    let targets: [ItemTarget]
    let l: L
    var artwork = true
    let onUse: (ItemTarget) -> Void
    let onCancel: () -> Void

    static let rowHeight: CGFloat = 42
    static let rowSpacing: CGFloat = 4
    static let visibleRows = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(l.itemChooseTarget).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                Button(l.cancel, action: onCancel).buttonStyle(.borderless).controlSize(.small)
            }
            if targets.count > Self.visibleRows {
                ScrollView {
                    LazyVStack(spacing: Self.rowSpacing) { rows }.reservesScrollerLane()
                }
                .frame(height: CGFloat(Self.visibleRows) * (Self.rowHeight + Self.rowSpacing) - Self.rowSpacing)
            } else {
                VStack(spacing: Self.rowSpacing) { rows }
            }
        }
    }

    private var rows: some View {
        ForEach(targets) { target in
            HStack(spacing: 8) {
                icon(target.individual)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        PracticeNameLevel(name: target.individual.name, level: target.individual.level, font: .caption.weight(.semibold))
                        if target.individual.isCurrent {
                            Text(l.dexRaising).font(.caption2).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                        }
                    }
                    detail(target)
                }
                Spacer(minLength: 4)
                if target.verdict == .usable {
                    Button(l.use) { onUse(target) }
                        .buttonStyle(.bordered).controlSize(.small)
                } else if let reason = target.verdict.reason(l) {
                    Text(reason).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing).lineLimit(2)
                }
            }
            .padding(.horizontal, 6)
            .frame(height: Self.rowHeight)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private func icon(_ individual: OwnedIndividual) -> some View {
        if artwork {
            SpriteView(speciesID: individual.speciesID, size: 28, shiny: individual.shiny, form: individual.form)
                .frame(width: 28, height: 28)
        }
    }

    /// What this item is about for the row: HP for a healing item, the nature for a Mint, the IVs for a reroll.
    @ViewBuilder
    private func detail(_ target: ItemTarget) -> some View {
        switch kind {
        case .mint:
            Text(target.individual.nature?.name(l.lang) ?? "—").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        case .ivReroll:
            Text(l.ivTotalLine(target.individual.ivs.total)).font(.caption2).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
        default:
            BattleHealthLine(share: target.healthShare, l: l)
        }
    }
}

/// The IV reroll's two steps in the bag: the current six with a warning that they may drop, then the new six with
/// how each moved. The bag owns the step and calls `useIVReroll(on:)`.
@MainActor
struct IVRerollPanel: View {
    enum Stage: Equatable {
        case confirm(current: PokemonIVs)
        case result(old: PokemonIVs, new: PokemonIVs)
    }

    let stage: Stage
    let l: L
    /// Who the reroll is for, once it can be someone other than the current Pokémon; nil leaves the line out.
    var targetName: String?
    let onReroll: () -> Void
    let onCancel: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let targetName {
                Text(targetName).font(.callout.weight(.semibold)).lineLimit(1)
            }
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
