import XCTest
@testable import PokeTokenBar

// MARK: - BattleSeatFrame

final class BattleSeatFrameTests: XCTestCase {
    private let host = BattleSeatFrame(local: .p1), guest = BattleSeatFrame(local: .p2)

    private func pokemon(_ species: String, hp: Int, maxhp: Int) -> BattleView.Pokemon {
        .init(speciesNum: 1, species: species, level: 50, types: ["Normal"], hp: hp, maxhp: maxhp, status: "", moves: [], ability: nil)
    }

    func testIdentsFollowTheLocalSeat() {
        XCTAssertEqual(host.side(ident: "p1a: Pikachu"), .player)
        XCTAssertEqual(host.side(ident: "p2a: Magikarp"), .opponent)
        XCTAssertEqual(guest.side(ident: "p1a: Pikachu"), .opponent)
        XCTAssertEqual(guest.side(ident: "p2a: Magikarp"), .player)
        XCTAssertEqual(guest.side(ident: "p2"), .player)
        XCTAssertNil(guest.side(ident: "sandstorm"))
        XCTAssertNil(guest.side(ident: ""))
    }

    func testSeatAndPokemonFollowTheLocalSeat() {
        XCTAssertEqual(host.seat(.player), .p1); XCTAssertEqual(host.seat(.opponent), .p2)
        XCTAssertEqual(guest.seat(.player), .p2); XCTAssertEqual(guest.seat(.opponent), .p1)
        let view = BattleView(turn: 1, ended: false, p1: pokemon("Pikachu", hp: 34, maxhp: 100), p2: pokemon("Magikarp", hp: 90, maxhp: 110))
        XCTAssertEqual(guest.pokemon(.player, in: view).species, "Magikarp")
        XCTAssertEqual(guest.pokemon(.opponent, in: view).species, "Pikachu")
        XCTAssertEqual(host.pokemon(.player, in: view).species, "Pikachu")
    }

    func testPracticeFrameIsTheFirstSeat() {
        XCTAssertEqual(BattleSeatFrame.practice.local, .p1)
    }

    /// The engine never flips identifiers for a p2 viewer; only the HP scale follows the viewer.
    func testParserGoldenLinesFromTheSecondSeat() {
        var parser = PracticeEventParser(frame: guest)
        let lines = [
            "|switch|p1a: Pikachu|Pikachu, L50, M|100/100", "|switch|p2a: Magikarp|Magikarp, L50, M|110/110", "|turn|1",
            "|move|p1a: Pikachu|Volt Tackle|p2a: Magikarp", "|-supereffective|p2a: Magikarp", "|-crit|p2a: Magikarp",
            "|-damage|p2a: Magikarp|0 fnt", "|faint|p2a: Magikarp", "|-damage|p1a: Pikachu|72/100|[from] Recoil",
            "|cant|p2a: Magikarp|par", "|-status|p1a: Pikachu|psn", "|win|p1",
        ]
        XCTAssertEqual(parser.parse(lines), [
            .switchIn(.opponent, hp: 100, maxHP: 100), .switchIn(.player, hp: 110, maxHP: 110), .turn(1),
            .move(.opponent, moveID: "volttackle"), .superEffective(.player), .critical(.player),
            .damage(.player, hp: 0, maxHP: 110, cause: nil), .faint(.player),
            .damage(.opponent, hp: 72, maxHP: 100, cause: "recoil"),
            .cant(.player, reason: "par"), .status(.opponent, code: "psn"), .end(winner: .opponent),
        ])
    }

    func testWinnerAndTieFollowTheLocalSeat() {
        var guestParser = PracticeEventParser(frame: guest), hostParser = PracticeEventParser(frame: host)
        XCTAssertEqual(guestParser.parse(["|win|p2"]), [.end(winner: .player)])
        XCTAssertEqual(guestParser.parse(["|win|p1"]), [.end(winner: .opponent)])
        XCTAssertEqual(hostParser.parse(["|win|p2"]), [.end(winner: .opponent)])
        XCTAssertEqual(guestParser.parse(["|tie"]), [.end(winner: nil)])
    }

    func testRevealsMergeThroughTheFrameBeforeTheClosingTurn() {
        let guestParser = PracticeEventParser(frame: guest)
        let during = BattleLogReveal(kind: "ability", side: "p1", id: "static", turn: 1)
        let own = BattleLogReveal(kind: "ability", side: "p2", id: "pressure", turn: 0)
        let move = BattleLogReveal(kind: "move", side: "p1", id: "tackle", turn: 1)
        XCTAssertEqual(guestParser.merging([during, move], into: [.move(.opponent, moveID: "tackle"), .turn(2)]),
                       [.move(.opponent, moveID: "tackle"), .abilityRevealed(.opponent, abilityID: "static"), .turn(2)])
        // Turn 0 is the start of the battle: it stays after the first turn marker, for the next beat's preamble.
        XCTAssertEqual(guestParser.merging([own], into: [.turn(1)]), [.turn(1), .abilityRevealed(.player, abilityID: "pressure")])
        // A terminal round ends without a turn marker.
        XCTAssertEqual(guestParser.merging([during], into: [.end(winner: .player)]),
                       [.end(winner: .player), .abilityRevealed(.opponent, abilityID: "static")])
        let practice = PracticeEventParser()
        XCTAssertEqual(practice.merging([during], into: [.turn(2)]), [.abilityRevealed(.player, abilityID: "static"), .turn(2)])
    }
}
