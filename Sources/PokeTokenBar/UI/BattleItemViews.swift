import SwiftUI

// PR 03C battle items and HP in the popover: what the practice screens may do with the bag, whether a battle item
// works right now, HP as a bar or "Fainted", and the IV reroll's two steps. Everything but the store glue at the
// top takes plain values. Practice files use these views but never name the store (practice read-only guard).

/// What the practice screens may do with the bag: count battle items and use a healing item on one individual.
/// `CompanionStore` conforms below, outside the practice files.
@MainActor
protocol PracticeItemBag: AnyObject {
    func itemCount(_ kind: ItemKind) -> Int
    @discardableResult func useHealingItem(_ kind: ItemKind, on instanceID: String) -> Bool
}

extension CompanionStore: PracticeItemBag {
    /// The current Pokémon's individual; nil for an egg or before its profile exists.
    var currentInstanceID: String? { state.active?.profile?.instanceID }
    /// The current Pokémon's six IVs, for the reroll's confirm; nil without a profile.
    var currentIVs: PokemonIVs? { state.active?.profile?.ivs }
    /// The current Pokémon's HP share between battles (1 = full, 0 = fainted); nil without one.
    var currentHealthShare: Double? { currentInstanceID.map { healthShare(of: $0) } }
}

/// Whether a battle item works on a Pokémon right now, and why not. Mirrors `CompanionStore.useHealingItem`: a Potion
/// or Hyper Potion needs one that is hurt but standing, a Revive one that fainted; the IV reroll a hatched Pokémon.
/// `healthShare` is nil without a Pokémon (an egg, or before its profile exists).
enum BattleItemUse: Equatable {
    case usable
    case notOwned
    case noPokemon
    case fullHealth
    /// A Potion on a fainted Pokémon: only a Revive helps.
    case fainted
    /// A Revive on a Pokémon that is standing.
    case notFainted

    init(_ kind: ItemKind, count: Int, healthShare: Double?) { self = .notOwned }   // RED stub
}

/// HP shares as the screens show them.
enum BattleHealth {
    /// 0 only when fainted and 100 only when full: a scratch reads 99%, a sliver 1%.
    static func percent(_ share: Double) -> Int { 0 }   // RED stub
}

/// HP as a thin bar and a percentage, or a gray "Fainted" tag at 0.
@MainActor
struct BattleHealthLine: View {
    let share: Double
    let l: L

    var body: some View { EmptyView() }   // RED stub
}

/// "기절" / "Fainted" in a small gray capsule.
@MainActor
struct BattleFaintedTag: View {
    let l: L

    var body: some View { EmptyView() }   // RED stub
}

/// The six IVs in two rows of three with their stat names; with `previous`, an arrow shows how each one moved.
@MainActor
struct IVGrid: View {
    let ivs: PokemonIVs
    var previous: PokemonIVs?
    let l: L

    enum Change: Equatable { case up, down, same }

    /// How one IV moved since `previous`; nil without one.
    static func change(_ stat: String, from previous: PokemonIVs?, to ivs: PokemonIVs) -> Change? { nil }   // RED stub

    var body: some View { EmptyView() }   // RED stub
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

    var body: some View { EmptyView() }   // RED stub
}
