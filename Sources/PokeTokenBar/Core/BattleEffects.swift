import Foundation

/// What a battle with stakes changes outside practice (PR 03C): an individual's HP between battles and growth XP
/// for the current Pokémon. `CompanionStore` implements it, so practice code never touches the save itself; tests
/// pass their own or none (then battles change nothing outside the session).
@MainActor
protocol PracticeBattleEffects: AnyObject {
    /// Share of max HP the individual has left: 1 when untouched, 0 when fainted.
    func healthShare(of instanceID: String) -> Double
    /// Keeps the HP share an individual has left after a battle with stakes (0 = fainted).
    func setHealthShare(_ share: Double, of instanceID: String)
    /// Grows the current Pokémon by `xp` (a practice win). False when there is no current Pokémon to grow.
    @discardableResult
    func grantBattleXP(_ xp: Int) -> Bool
}

extension CompanionStore: PracticeBattleEffects {
    func healthShare(of instanceID: String) -> Double { 1 }            // contract stub
    func setHealthShare(_ share: Double, of instanceID: String) {}     // contract stub
    @discardableResult
    func grantBattleXP(_ xp: Int) -> Bool { false }                    // contract stub

    /// Uses a Potion, Hyper Potion or Revive on one individual. False (nothing spent) when it can't be used:
    /// none in the bag, a Revive on a Pokémon that isn't fainted, a Potion on a fainted or full one.
    @discardableResult
    func useHealingItem(_ kind: ItemKind, on instanceID: String) -> Bool { false }   // contract stub
    /// Re-rolls the current Pokémon's six IVs with one IV reroll; the new IVs, or nil (nothing spent) without one.
    @discardableResult
    func useIVReroll() -> PokemonIVs? { nil }                         // contract stub
}
