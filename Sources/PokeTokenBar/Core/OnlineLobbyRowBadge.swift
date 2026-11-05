import Foundation

/// The word on a row of the lobby's battle list that says what the room asks of me.
/// It reads the same attention calculation the menu bar and the banner use, so a row never says "my turn"
/// where the mark says nothing. Pure: nothing here stores, sends or draws.
enum OnlineLobbyRowBadge: String, CaseIterable, Equatable, Sendable {
    /// A request someone sent me and I have not answered.
    case received
    /// My own request, waiting for the other side.
    case sent
    /// The next move is mine: confirm, ready, or a move to pick.
    case myTurn

    /// One badge per room that has one, keyed by battle id.
    static func badges(_ input: OnlineAttentionInput) -> [String: OnlineLobbyRowBadge] {
        guard let me = input.localTrainerID else { return [:] }
        var found: [String: OnlineLobbyRowBadge] = [:]
        for attention in OnlineAttentionCalculator.active(input) {
            switch attention.kind {
            case .incomingChallenge, .rematchRequested: found[attention.battleId] = .received
            case .myTurn, .challengeAccepted, .finalConfirmed: found[attention.battleId] = .myTurn
            case .requestEnded, .resultReady, .matchEnded: break
            }
        }
        // A request I sent is nobody's event while it waits, so it comes from the room itself.
        for room in input.battles where room.state == .pending && room.side(for: me) == .p1 && found[room.battleId] == nil {
            found[room.battleId] = .sent
        }
        return found
    }
}
