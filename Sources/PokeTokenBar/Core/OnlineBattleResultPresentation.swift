import Foundation

/// What a settled battle did to this save, exactly as the settlement receipt recorded it.
struct OnlineBattleResultEffects: Equatable, Sendable {
    /// The Pokémon that fought here, so the wording can name it.
    let instanceID: String
    /// Experience the receipt granted; 0 when none was paid.
    let xp: Int64
    /// The share of its HP the Pokémon kept. 0 means it fainted.
    let hpShare: Double
    var fainted: Bool { hpShare <= 0 }
    /// Whole percent of HP kept; 1 at least while it still stands.
    var hpPercent: Int { fainted ? 0 : max(1, Int((min(1, hpShare) * 100).rounded(.down))) }
}

/// The result screen's data. Wording lives in `L`; nothing here is a display string.
struct OnlineBattleUIResult: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case win, loss, draw
        /// The server voided the match: nothing was applied.
        case void
        /// Fought with a Pokémon this save does not have. No receipt exists, so no effect is claimed.
        case record
    }
    let kind: Kind
    /// nil unless a receipt exists. Without one the screen says nothing about HP or XP of a settled battle.
    let effects: OnlineBattleResultEffects?
    var isVoid: Bool { kind == .void }
}

/// What the finished room's rematch looks like from this seat.
enum OnlineRematchOffer: Equatable {
    /// I asked and the other seat has not answered yet.
    case sent(OnlineBattleView)
    /// The other seat asked and I have not answered yet.
    case received(OnlineBattleView)
    /// The rematch room moved on (accepted, ready, running): it is a room to open, not a request to answer.
    case underway(OnlineBattleView)
    var room: OnlineBattleView {
        switch self {
        case .sent(let room), .received(let room), .underway(let room): room
        }
    }
}

/// Why the result screen's rematch button is off. Said in one line below it.
enum OnlineRematchBlock: Equatable {
    case noHealthyPokemon, opponentLeft
    /// The other seat's request is waiting and was put off; asking again would cross it.
    case requestWaiting
}

/// Everything the result screen shows, decided here so a test can read it and the view only draws it.
struct OnlineBattleResultScreen: Equatable {
    struct Totals: Equatable { let turns: Int; let dealtPercent: Int; let takenPercent: Int }
    enum Rematch: Equatable {
        /// Nothing to offer: a voided match, a record from another save, or a room this person did not fight in.
        case none
        /// "Fight again". Off when `OnlineRematchBlock` or a busy moment says so.
        case request(enabled: Bool)
        /// "Waiting for Sky · Cancel": cancels the rematch room, not the result.
        case waiting(label: String, battleID: String)
        /// The other seat's request, answered here.
        case answer(banner: String, battleID: String)
        /// The rematch is already a room: open it.
        case open(battleID: String)
    }
    let kind: OnlineBattleUIResult.Kind
    let title: String
    let subtitle: String
    let opponent: String
    let effects: [String]
    let totals: Totals?
    let rematch: Rematch
    /// One line under the controls: why the button is off, or a hint that does not turn it off.
    let note: String?
    /// The finished room's id, which "Fight again" is about.
    let sourceID: String?
}

extension OnlineBattlePresentation {
    func resultScreen(l: L) -> OnlineBattleResultScreen? { nil }
    func rematchOffer(for source: OnlineBattleView) -> OnlineRematchOffer? { nil }
    func actionRoom(_ id: String) -> OnlineBattleView? { room?.battleId == id ? room : nil }
    func rematchBlock(for source: OnlineBattleView) -> OnlineRematchBlock? { nil }
    /// True when the opponent is an active member who is not connected now: the request still reaches them.
    func rematchOpponentOffline(for source: OnlineBattleView) -> Bool { false }
    /// Wins and losses against one member among the completed battles.
    func headToHead(against trainerID: String) -> (wins: Int, losses: Int, draws: Int) { (0, 0, 0) }
    /// Wins in a row ending at `source`, counting completed battles only.
    func winStreak(through source: OnlineBattleView) -> Int { 0 }
    /// The staged totals of the shown room, or nil when any round never reached the screen.
    func resultSummary() -> PracticeSummary? { nil }
}
