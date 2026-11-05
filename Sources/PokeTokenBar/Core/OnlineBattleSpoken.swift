import Foundation

/// What VoiceOver says in the online arena, computed from plain values so a test can read it when the render
/// environment gives no accessibility tree. The views only hand these results to their accessibility modifiers.
/// Every value comes from what the screen draws (the staged display, never the engine's view ahead of it) and the
/// opponent's side is only ever the public percent: a label never says more than the picture does.
enum OnlineBattleSpoken {
    struct Card: Equatable {
        let label: String
        let value: String
    }

    /// A move, ability or type name as the screen shows it: the loaded translation, else the readable identifier.
    static func name(_ kind: PokemonNameResource.Kind, slug: String, l: L, artwork: Bool,
                     names: [PokemonNameResource: [String: String]]) -> String { "" }
    static func moveLabel(l: L, slot: Int, name: String) -> String { "" }
    static func moveValue(l: L, typeName: String, pp: Int, maxPP: Int, special: Bool, details: String, chosen: Bool) -> String { "" }
    static func card(l: L, own: Bool, name: String, level: Int, nickname: String?, display: PracticeDisplaySide) -> Card {
        Card(label: "", value: "")
    }
    static func clock(l: L, state: OnlineBattleTurnClock.State, turn: Int) -> String { "" }
    static func turnStart(l: L, turn: Int, remaining: Int?) -> String { "" }
    static func result(l: L, title: String, subtitle: String) -> String { "" }
}

/// Which announcements were already made. It lives with the presentation model, which outlives the popover's views,
/// so closing and reopening the popover never says the same turn twice.
struct OnlineBattleAnnouncementLedger: Equatable {
    /// True once per battle and turn, and only for a picker that is open, a display that has caught up with the
    /// engine and a screen the person can see. A refusal consumes nothing, so the turn is still due when it is seen.
    mutating func claimTurn(battleID: String, turn: Int, shown: Bool, open: Bool, playing: Bool) -> Bool { false }
    /// True once per battle, only on a visible screen and never while a beat is still on its way.
    mutating func claimResult(battleID: String, shown: Bool, playing: Bool) -> Bool { false }
}
