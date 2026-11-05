import AppKit
import SwiftUI
import XCTest
@testable import PokeTokenBar

/// T21: what VoiceOver says in the online arena. The render environment can give an empty accessibility tree, so the
/// words are computed by `OnlineBattleSpoken`, asserted here, and a source check pins that the views use them.
/// Whether VoiceOver itself reads them in order is not verified here (it needs a person with VoiceOver on).
@MainActor
final class OnlineBattleAccessibilityTests: XCTestCase {
    private let languages: [AppLanguage] = [.ko, .en]
    private var window: NSWindow?
    @MainActor private final class Recorder { var lines: [String] = [] }
    override func tearDown() async throws { window?.close(); window = nil }

    private func arenaView(_ model: OnlineBattlePresentation, announce: @escaping @MainActor (String) -> Void = { _ in }) -> OnlineBattleArena {
        var arena = OnlineBattleArena(model: model, l: L(.ko), artwork: false, speciesNameProvider: OnlineBattleSyntheticNameProvider(),
                                      speciesNameStore: PokemonNameDisplayStore())
        arena.announce = announce
        return arena
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    // MARK: Moves

    func testMoveLabelNamesTheMoveAndTheValueSaysTypeAndPPInBothLanguages() {
        for lang in languages {
            let l = L(lang)
            let label = OnlineBattleSpoken.moveLabel(l: l, slot: 2, name: "Thunderbolt")
            XCTAssertTrue(label.contains("Thunderbolt"), "\(lang): \(label)")
            XCTAssertTrue(label.contains("2"), "\(lang): the key it answers to")
            let value = OnlineBattleSpoken.moveValue(l: l, typeName: "Electric", pp: 12, maxPP: 15, special: false,
                                                     details: "Pow 90", chosen: false)
            XCTAssertTrue(value.contains("Electric"), "\(lang): \(value)")
            XCTAssertTrue(value.contains("12/15"), "\(lang): \(value)")
            XCTAssertTrue(value.contains("Pow 90"), "\(lang): the hint's words stay")
            XCTAssertFalse(value.contains(l.onlineYourPick), "\(lang): nothing is picked yet")
        }
        XCTAssertNotEqual(OnlineBattleSpoken.moveLabel(l: L(.ko), slot: 1, name: "X"), OnlineBattleSpoken.moveLabel(l: L(.en), slot: 1, name: "X"))
    }

    func testPickedMoveSaysSoAndASpecialMoveHasNoPP() {
        for lang in languages {
            let l = L(lang)
            let picked = OnlineBattleSpoken.moveValue(l: l, typeName: "Normal", pp: 3, maxPP: 5, special: false, details: "", chosen: true)
            XCTAssertTrue(picked.contains(l.onlineYourPick), "\(lang): \(picked)")
            XCTAssertTrue(picked.contains("3/5"))
            let struggle = OnlineBattleSpoken.moveValue(l: l, typeName: "Normal", pp: 0, maxPP: 0, special: true, details: "", chosen: false)
            XCTAssertFalse(struggle.contains("0/0"), "\(lang): Struggle has no PP to read: \(struggle)")
            XCTAssertTrue(struggle.contains("Normal"))
        }
    }

    func testNameShowsTheTranslationOnlyWhereTheScreenDoes() {
        let resource = PokemonNameResource(kind: .move, name: "iron-tail")
        let names = [resource: ["en": "Iron Tail", "ko": "아이언테일"]]
        XCTAssertEqual(OnlineBattleSpoken.name(.move, slug: "iron-tail", l: L(.ko), artwork: true, names: names), "아이언테일")
        XCTAssertEqual(OnlineBattleSpoken.name(.move, slug: "iron-tail", l: L(.en), artwork: true, names: names), "Iron Tail")
        XCTAssertEqual(OnlineBattleSpoken.name(.move, slug: "iron-tail", l: L(.ko), artwork: false, names: names), "Iron Tail",
                       "without artwork the screen draws the identifier, so that is what is read")
        XCTAssertEqual(OnlineBattleSpoken.name(.move, slug: "iron-tail", l: L(.ko), artwork: true, names: [:]), "Iron Tail")
    }

    /// The arena's own move cards carry those words: the name in the label, the type and PP in the value.
    func testArenaMoveCardsSpeakNameTypeAndPP() throws {
        let fixture = try OnlineBattleArenaFixture.arena(seat: .p1); defer { fixture.close() }
        let arena = arenaView(fixture.model)
        let moves = try XCTUnwrap(fixture.model.request?.moves)
        XCTAssertFalse(moves.isEmpty)
        for move in moves.prefix(4) {
            let card = arena.moveCard(move)
            XCTAssertFalse(card.spokenLabel.isEmpty, "slot \(move.slot)")
            XCTAssertTrue(card.spokenLabel.contains("\(move.slot)"))
            XCTAssertTrue(card.spokenValue.contains("\(move.pp)/\(move.maxpp)"), "slot \(move.slot): \(card.spokenValue)")
            XCTAssertTrue(card.spokenValue.lowercased().contains(PokemonNameLocalization.identifier(move.type.lowercased()).lowercased()),
                          "slot \(move.slot) type \(move.type): \(card.spokenValue)")
        }
    }

    // MARK: Cards

    func testOpponentCardSaysOnlyThePublicPercentNeverTheExactHP() {
        let display = PracticeDisplaySide(hp: 137, maxHP: 300, status: nil, fainted: false)
        for lang in languages {
            let card = OnlineBattleSpoken.card(l: L(lang), own: false, name: "Magikarp", level: 41, nickname: "Sky", display: display)
            XCTAssertTrue(card.value.contains("46%"), "\(lang): \(card.value)")
            XCTAssertFalse(card.value.contains("137") || card.value.contains("300"), "\(lang): \(card.value)")
            XCTAssertTrue(card.label.contains("Magikarp") && card.label.contains("Sky") && card.label.contains("41"), "\(lang): \(card.label)")
            XCTAssertFalse(card.label.contains("137"))
        }
    }

    func testOwnCardSaysPercentAndHPAndStatusAndFainted() {
        for lang in languages {
            let l = L(lang)
            let hurt = OnlineBattleSpoken.card(l: l, own: true, name: "Pikachu", level: 50, nickname: nil,
                                               display: .init(hp: 60, maxHP: 150, status: "par", fainted: false))
            XCTAssertTrue(hurt.value.contains("40%") && hurt.value.contains("60/150"), "\(lang): \(hurt.value)")
            XCTAssertTrue(hurt.value.contains(l.practiceStatusName("par")), "\(lang): \(hurt.value)")
            XCTAssertTrue(hurt.label.contains("Pikachu") && hurt.label.contains("50"), "\(lang): \(hurt.label)")
            let down = OnlineBattleSpoken.card(l: l, own: true, name: "Pikachu", level: 50, nickname: nil,
                                               display: .init(hp: 0, maxHP: 150, status: nil, fainted: true))
            XCTAssertNotEqual(down.value, hurt.value)
            XCTAssertTrue(down.value.contains(l.online("기절", "Fainted")), "\(lang): \(down.value)")
            XCTAssertFalse(down.value.contains("0/150"))
        }
        let own = OnlineBattleSpoken.card(l: L(.en), own: true, name: "A", level: 5, nickname: nil, display: .init(hp: 1, maxHP: 2, status: nil, fainted: false))
        let foe = OnlineBattleSpoken.card(l: L(.en), own: false, name: "A", level: 5, nickname: nil, display: .init(hp: 1, maxHP: 2, status: nil, fainted: false))
        XCTAssertNotEqual(own.label, foe.label, "who is who is in the label")
    }

    /// The arena's cards read the staged display, the same one the picture draws, and not the engine's view that is
    /// already ahead of it while beats play: no card says a result the screen has not shown yet.
    func testCardsSpeakTheStagedDisplayNotTheViewAheadOfIt() throws {
        let fixture = try OnlineBattleArenaFixture.arena(seat: .p1); defer { fixture.close() }
        try fixture.play(rounds: 1)
        XCTAssertTrue(fixture.staging.isPlaying)
        let view = try XCTUnwrap(fixture.model.arena), arena = arenaView(fixture.model)
        var aheadSomewhere = false
        for side in [PracticeSide.player, .opponent] {
            let card = arena.sideCard(side, view: view)
            let shown = try XCTUnwrap(fixture.staging.shown(side))
            let spoken = try XCTUnwrap(card.spoken, "\(side) card has VoiceOver words")
            let expected = OnlineBattleSpoken.card(l: L(.ko), own: side == .player, name: card.name, level: card.side.level,
                                                   nickname: side == .player ? nil : fixture.model.opponentNickname, display: shown)
            XCTAssertEqual(spoken, expected, "\(side)")
            let ahead = OnlineBattleSpoken.card(l: L(.ko), own: side == .player, name: card.name, level: card.side.level,
                                                nickname: side == .player ? nil : fixture.model.opponentNickname,
                                                display: OnlineBattleStaging.resting(card.side))
            if ahead.value != spoken.value { aheadSomewhere = true }
        }
        XCTAssertTrue(aheadSomewhere, "the first round must leave the view ahead of the beat on screen for this to prove anything")
    }

    // MARK: Clock

    func testClockValueSaysTheSecondsLeftAndWhoIsChoosing() {
        for lang in languages {
            let l = L(lang)
            let mine = OnlineBattleSpoken.clock(l: l, state: .counting(remaining: 12, fraction: 0.4, mine: true), turn: 3)
            XCTAssertTrue(mine.contains("12") && mine.contains("3"), "\(lang): \(mine)")
            let waiting = OnlineBattleSpoken.clock(l: l, state: .counting(remaining: 12, fraction: 0.4, mine: false), turn: 3)
            XCTAssertTrue(waiting.contains("12"), "\(lang): \(waiting)")
            XCTAssertNotEqual(mine, waiting, "\(lang): after my choice the clock is the other side's")
            let urgent = OnlineBattleSpoken.clock(l: l, state: .counting(remaining: 4, fraction: 0.1, mine: true), turn: 3)
            XCTAssertTrue(urgent.contains("4"), "\(lang): \(urgent)")
            XCTAssertTrue(urgent.contains(l.online("자동 선택", "Auto-pick")), "\(lang): the last seconds say the pick is automatic: \(urgent)")
            XCTAssertFalse(waiting.contains(l.online("자동 선택", "Auto-pick")), "\(lang): no alarm for the other side's time")
            let idle = OnlineBattleSpoken.clock(l: l, state: .idle, turn: 3)
            XCTAssertTrue(idle.contains("3") && !idle.contains("12"), "\(lang): \(idle)")
            let preparing = OnlineBattleSpoken.clock(l: l, state: .preparing, turn: 3)
            XCTAssertFalse(preparing.isEmpty); XCTAssertNotEqual(preparing, idle)
            XCTAssertFalse(preparing.contains("0초") || preparing.contains(" 0s"), "\(lang): no deadline is not zero seconds: \(preparing)")
        }
    }

    // MARK: Announcements

    func testTurnStartIsSaidOncePerTurnAndOnlyWhenTheScreenCanHearIt() {
        var ledger = OnlineBattleAnnouncementLedger()
        // Hidden, still playing, or no picker: nothing is said and nothing is used up.
        XCTAssertFalse(ledger.claimTurn(battleID: "b", turn: 2, shown: false, open: true, playing: false), "closed popover")
        XCTAssertFalse(ledger.claimTurn(battleID: "b", turn: 2, shown: true, open: true, playing: true), "the beats have not finished")
        XCTAssertFalse(ledger.claimTurn(battleID: "b", turn: 2, shown: true, open: false, playing: false), "no picker")
        XCTAssertTrue(ledger.claimTurn(battleID: "b", turn: 2, shown: true, open: true, playing: false), "due as soon as it can be heard")
        XCTAssertFalse(ledger.claimTurn(battleID: "b", turn: 2, shown: true, open: true, playing: false), "not twice in the same turn")
        XCTAssertFalse(ledger.claimTurn(battleID: "b", turn: 2, shown: true, open: true, playing: false), "still not")
        XCTAssertTrue(ledger.claimTurn(battleID: "b", turn: 3, shown: true, open: true, playing: false), "the next turn is new")
        XCTAssertTrue(ledger.claimTurn(battleID: "other", turn: 3, shown: true, open: true, playing: false), "a rematch room starts again")
        XCTAssertFalse(ledger.claimTurn(battleID: "other", turn: 3, shown: true, open: true, playing: false))
    }

    func testResultIsSaidOncePerBattleOnlyOnAVisibleScreenAfterTheBeats() {
        var ledger = OnlineBattleAnnouncementLedger()
        XCTAssertFalse(ledger.claimResult(battleID: "b", shown: false, playing: false), "closed popover")
        XCTAssertFalse(ledger.claimResult(battleID: "b", shown: true, playing: true), "a beat still hides the outcome")
        XCTAssertTrue(ledger.claimResult(battleID: "b", shown: true, playing: false))
        XCTAssertFalse(ledger.claimResult(battleID: "b", shown: true, playing: false), "not twice")
        XCTAssertTrue(ledger.claimResult(battleID: "rematch", shown: true, playing: false))
    }

    func testPresentationBuildsTheTurnLineFromTheServersDeadlineAndClaimsIt() throws {
        let fixture = try OnlineBattleArenaFixture.arena(seat: .p1); defer { fixture.close() }
        let model = fixture.model, now = Date(timeIntervalSince1970: 1_000)
        model.deadline = now.addingTimeInterval(25)
        model.screenShown = false
        XCTAssertNil(model.claimTurnAnnouncement(l: L(.ko), pickerOpen: true, playing: false, now: now), "closed popover")
        model.screenShown = true
        XCTAssertNil(model.claimTurnAnnouncement(l: L(.ko), pickerOpen: true, playing: true, now: now), "beats still playing")
        let line = try XCTUnwrap(model.claimTurnAnnouncement(l: L(.ko), pickerOpen: true, playing: false, now: now))
        XCTAssertTrue(line.contains("25"), line)
        XCTAssertTrue(line.contains("\(try XCTUnwrap(model.arena).turn)"), line)
        XCTAssertNil(model.claimTurnAnnouncement(l: L(.ko), pickerOpen: true, playing: false, now: now), "the ledger outlives the views")
        // No deadline yet: the line has no seconds rather than a zero.
        model.announcements = OnlineBattleAnnouncementLedger(); model.deadline = nil
        let bare = try XCTUnwrap(model.claimTurnAnnouncement(l: L(.en), pickerOpen: true, playing: false, now: now))
        XCTAssertFalse(bare.contains("0s") || bare.contains(" 0"), bare)
    }

    func testResultLineIsTheLocalizedTitleAndSaidOnce() throws {
        let fixture = try OnlineBattleArenaFixture.arena(seat: .p1); defer { fixture.close() }
        let model = fixture.model
        let screen = OnlineBattleResultScreen(title: "승리!", subtitle: "연승 중", opponent: "", effects: [], totals: nil,
                                              rematch: .none, note: nil, sourceID: nil)
        model.screenShown = true
        let line = try XCTUnwrap(model.claimResultAnnouncement(l: L(.ko), screen: screen))
        XCTAssertTrue(line.contains("승리!"), line)
        XCTAssertNil(model.claimResultAnnouncement(l: L(.ko), screen: screen), "once")
        for lang in languages {
            let text = OnlineBattleSpoken.result(l: L(lang), title: "Victory", subtitle: "")
            XCTAssertTrue(text.contains("Victory"), "\(lang): \(text)")
        }
    }

    /// The view side: a hosted arena speaks the turn when the screen is shown, and never again for the same turn.
    func testHostedArenaAnnouncesTheTurnOnceAndNotWhileHidden() async throws {
        let fixture = try OnlineBattleArenaFixture.arena(seat: .p1); defer { fixture.close() }
        fixture.staging.skipToEnd(); fixture.publish()
        fixture.model.screenShown = false
        let recorder = Recorder()
        let arena = arenaView(fixture.model) { recorder.lines.append($0) }
        let host = NSHostingView(rootView: arena.frame(width: PopoverMetrics.scrollContentWidth, height: 600))
        host.frame = NSRect(x: 0, y: 0, width: PopoverMetrics.scrollContentWidth, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil); self.window = window
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(recorder.lines, [], "a screen that is not shown stays quiet")
        fixture.model.screenShown = true
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(recorder.lines.count, 1, "\(recorder.lines)")
        fixture.model.deadline = Date().addingTimeInterval(20)
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(recorder.lines.count, 1, "a new deadline in the same turn is not a new turn: \(recorder.lines)")
    }

    // MARK: Wiring

    func testViewsUseTheSpokenValuesAndPostThroughTheLedger() throws {
        let arena = try source("Sources/PokeTokenBar/UI/OnlineBattleScreenArena.swift")
        XCTAssertTrue(arena.contains("OnlineBattleSpoken.card("), "cards")
        XCTAssertTrue(arena.contains("claimTurnAnnouncement("), "turn start goes through the ledger")
        let clock = try source("Sources/PokeTokenBar/UI/OnlineBattleTurnClock.swift")
        XCTAssertTrue(clock.contains("OnlineBattleSpoken.clock("), "the clock band")
        XCTAssertTrue(clock.contains(".accessibilityValue("))
        let board = try source("Sources/PokeTokenBar/UI/PracticeBattleBoard.swift")
        XCTAssertTrue(board.contains("OnlineBattleSpoken.moveLabel("), "move cards")
        XCTAssertTrue(board.contains("OnlineBattleSpoken.moveValue("))
        XCTAssertTrue(board.contains(".accessibilityLabel(spoken.label)") || board.contains("accessibilityLabel(spoken.label)"), "side cards")
        let result = try source("Sources/PokeTokenBar/UI/OnlineBattleResultView.swift")
        XCTAssertTrue(result.contains("claimResultAnnouncement("), "the result goes through the ledger")
    }
}
