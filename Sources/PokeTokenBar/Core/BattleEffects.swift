import Foundation

/// What a battle with stakes changes outside practice (PR 03C): an individual's HP between battles and growth XP
/// for the current Pokémon. `CompanionStore` implements it (with the healing items and the IV reroll, in
/// CompanionStore.swift, where the save is written), so practice code never touches the save itself; tests pass their
/// own or none (then battles change nothing outside the session).
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
