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
    /// The individual a running battle with stakes holds, or nil once none runs. The battle owns that HP until its
    /// end sets it, so nothing may heal the individual meanwhile. In memory only, never saved.
    func setInBattle(_ instanceID: String?)
    /// The save as it is now, a value copy, with the current Pokémon's name as the app shows it: what the session
    /// rebuilds its roster from, so growth, an evolution or an IV reroll since the practice screen opened reaches the
    /// next battle. nil from a stand-in that keeps no save; the roster `prepare` built then stays.
    func companionState() -> (state: CompanionState, activeName: String?)?
}
