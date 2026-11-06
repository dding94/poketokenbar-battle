import XCTest
@testable import PokeTokenBar

private func hasHangul(_ text: String) -> Bool {
    text.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) }
}
private let otherLanguages = AppLanguage.allCases.filter { $0 != .ko }

/// An English app read Korean battle text because the strings sat in Core with no language to choose by. The tables
/// spell out both languages, so a line routed to the wrong word fails as well as a line left in Korean.
@MainActor
final class PracticeLanguageTests: XCTestCase {
    private func engine() throws -> BattleEngine { try BattleEngine(url: PracticeScreenRenderingTests.engineURL) }
    private func profile(_ id: String, moves: [String] = ["tackle"], ability: String? = "pressure") -> PokemonProfile {
        var p = PokemonProfile.generate(seed: 42, instanceID: id)
        p.level = 50; p.gender = .male; p.abilityName = ability
        p.moves = moves.map { PokemonKnownMove(name: $0, learnedAtLevel: 1) }
        return p
    }
    private func candidate(_ id: String, _ name: String, species: Int, moves: [String], ability: String = "pressure",
                           engine: BattleEngine) throws -> PracticeCandidate {
        PracticeCandidate(id: id, name: name,
                          snapshot: try BattleSnapshot.make(speciesID: species, nature: .hardy,
                                                            profile: profile(id, moves: moves, ability: ability), using: engine),
                          blockedReason: nil)
    }

    // MARK: Blocked reasons

    private struct Unrelated: Error {}
    func testEveryFailureFollowsTheAppLanguage() {
        let table: [(Error, String, String)] = [
            (BattleSnapshot.Failure.missingProfile, "개체 정보가 아직 준비되지 않았습니다. 잠시 후 연습전을 다시 열어 주세요.", "This Pokémon's details aren't ready yet. Reopen practice in a moment."),
            (BattleSnapshot.Failure.missingNature, "성격 정보가 없습니다.", "Nature data is missing."),
            (BattleSnapshot.Failure.missingGender, "성별 정보가 없습니다.", "Gender data is missing."),
            (BattleSnapshot.Failure.missingAbility, "특성 정보가 아직 없습니다.", "Ability data isn't ready yet."),
            (BattleSnapshot.Failure.missingMoves, "배운 기술 정보가 아직 없습니다.", "Learned-move data isn't ready yet."),
            (BattleEngine.Failure.engine("same_individual"), "상대는 내 다른 개체를 골라 주세요.", "Pick a different Pokémon as the opponent."),
            (BattleEngine.Failure.engine("rejected"), "전투를 진행할 수 없습니다 (rejected). 개체 정보는 바꾸지 않았습니다.", "The battle can't continue (rejected). Your Pokémon wasn't changed."),
            (BattleEngine.Failure.missingBundle, "전투 엔진이 없습니다. 완성된 앱 번들로 실행해 주세요.", "The battle engine is missing. Run the complete app bundle."),
            (BattleEngine.Failure.checksumMismatch, "전투 엔진 검증에 실패했습니다. 앱을 다시 빌드해 주세요.", "The battle engine failed verification. Rebuild the app."),
            (Unrelated(), "전투 정보를 확인할 수 없습니다. 연습전을 다시 열어 주세요.", "Couldn't read the battle data. Reopen practice."),
        ]
        for (error, korean, english) in table {
            XCTAssertEqual(PracticeText.failure(error, l: L(.ko)), korean)
            XCTAssertEqual(PracticeText.failure(error, l: L(.en)), english)
            for language in otherLanguages { XCTAssertFalse(hasHangul(PracticeText.failure(error, l: L(language))), "\(language)") }
        }
    }
    /// The trigger: a save in English whose Pokémon cannot fight yet.
    func testBlockedRowReadsTheSavesLanguage() throws {
        let engine = try engine()
        func reason(_ language: AppLanguage) throws -> String? {
            var state = CompanionState(); state.language = language
            state.dex = [DexEntry(baseID: 25, finalID: 25, chainOrder: [25], rarity: .common, caughtAt: nil, nature: .hardy,
                                  profile: profile("blocked", ability: nil), names: [25: ["en": "Pikachu"]])]
            return PracticeRoster(state: state, engine: engine).candidates.first?.blockedReason
        }
        XCTAssertEqual(try reason(.en), "Ability data isn't ready yet.")
        XCTAssertEqual(try reason(.ko), "특성 정보가 아직 없습니다.")
    }
    func testLoadErrorReadsTheSavesLanguage() {
        for (language, expected) in [(AppLanguage.en, "The battle engine is missing. Run the complete app bundle."),
                                     (.ko, "전투 엔진이 없습니다. 완성된 앱 번들로 실행해 주세요.")] {
            let session = PracticeSession(engineURL: nil)
            var state = CompanionState(); state.language = language
            session.prepare(state: state, activeName: nil)
            XCTAssertEqual(session.loadError, expected, "\(language)")
        }
    }

    // MARK: Battle log

    func testEveryLogLineFollowsTheAppLanguage() {
        let names = ["p1": "Mine", "p2": "Theirs"]
        let table: [(String, String, String)] = [
            ("|turn|3", "── 3턴 ──", "── Turn 3 ──"),
            ("|move|p1a: X|Tackle", "Mine · Tackle 사용", "Mine · used Tackle"),
            ("|-damage|p2a: X|50/100", "Theirs · 피해를 입었습니다 (HP 50/100).", "Theirs · took damage (HP 50/100)."),
            ("|-heal|p1a: X|60/100", "Mine · 체력을 회복했습니다 (HP 60/100).", "Mine · recovered HP (HP 60/100)."),
            ("|-miss|p1a: X", "Mine · 공격이 빗나갔습니다.", "Mine · missed."),
            ("|-immune|p2a: X", "Theirs · 효과가 없습니다.", "Theirs · no effect."),
            ("|-fail|p1a: X", "Mine · 기술이 실패했습니다.", "Mine · the move failed."),
            ("|-status|p2a: X|par", "Theirs · 마비 상태가 되었습니다.", "Theirs · is now paralyzed."),
            ("|-status|p2a: X|new", "Theirs · new 상태가 되었습니다.", "Theirs · is now new."),
            ("|-curestatus|p1a: X|par", "Mine · 상태이상이 회복됐습니다.", "Mine · status cured."),
            ("|cant|p1a: X|flinch", "Mine · 행동할 수 없습니다 (flinch).", "Mine · can't act (flinch)."),
            ("|-boost|p1a: X|atk|1", "Mine · 능력치 atk 상승", "Mine · atk up"),
            ("|-unboost|p2a: X|def|1", "Theirs · 능력치 def 하락", "Theirs · def down"),
            ("|-supereffective|p2a: X", "효과가 굉장합니다!", "Super effective!"),
            ("|-resisted|p2a: X", "효과가 별로입니다.", "Not very effective."),
            ("|-crit|p2a: X", "급소에 맞았습니다!", "Critical hit!"),
            ("|faint|p2a: X", "Theirs · 쓰러졌습니다.", "Theirs · fainted."),
            ("|win|p1", "Mine 승리 · 연습전을 마쳤습니다.", "Mine won · practice is over."),
            ("|tie|", "무승부 · 연습전을 마쳤습니다.", "Draw · practice is over."),
            ("|-weather|RainDance", "날씨 · RainDance", "Weather · RainDance"),
            ("|-start|p1a: X|confusion", "Mine · confusion 발동", "Mine · confusion activated"),
            ("|-activate|p1a: X|protect", "Mine · protect 발동", "Mine · protect activated"),
            ("|-end|p1a: X|confusion", "Mine · confusion 종료", "Mine · confusion ended"),
            ("|-future|p1a: X|effect", "전투 기록 · p1a: X · effect", "Battle log · p1a: X · effect"),
        ]
        for (raw, korean, english) in table {
            XCTAssertEqual(PracticeText.log(raw, names: names, l: L(.ko)), korean, raw)
            XCTAssertEqual(PracticeText.log(raw, names: names, l: L(.en)), english, raw)
            for language in otherLanguages {
                XCTAssertFalse(hasHangul(PracticeText.log(raw, names: names, l: L(language)) ?? "한"), "\(language) \(raw)")
            }
        }
    }
    func testRecordedLinesFollowTheAppLanguage() {
        let table: [(PracticeLogEntry, String, String)] = [
            (.opening(hasStakes: false), "연습전을 시작합니다. 성장과 보유 상태는 바뀌지 않습니다.", "Practice battle started. Growth and ownership stay as they are."),
            (.opening(hasStakes: true), "연습전을 시작합니다. 깎인 체력은 배틀이 끝나도 남습니다.", "Practice battle started. HP lost stays after the battle."),
            (.timedOut, "시간 초과 · 이번 턴은 자동으로 선택합니다.", "Time's up · a move is picked for you this turn."),
            (.abilityRevealed(name: "Mine", ability: "pressure"), "Mine · 특성 공개: pressure", "Mine · ability revealed: pressure"),
        ]
        for (entry, korean, english) in table {
            XCTAssertEqual(PracticeText.line(entry, names: [:], l: L(.ko)), korean)
            XCTAssertEqual(PracticeText.line(entry, names: [:], l: L(.en)), english)
        }
    }
    func testNoticeFollowsTheAppLanguage() {
        XCTAssertEqual(PracticeNotice.moveUnavailable.text(L(.en)), "That move can't be used right now. Pick another.")
        XCTAssertEqual(PracticeNotice.moveUnavailable.text(L(.ko)), "지금은 사용할 수 없는 기술입니다. 다른 기술을 골라 주세요.")
        XCTAssertEqual(PracticeNotice.failure(BattleEngine.Failure.missingBundle).text(L(.en)), "The battle engine is missing. Run the complete app bundle.")
    }

    /// A real battle read in both languages. The language is no input of the battle: one battle gives both logs, and a
    /// second one given the same seed reaches the same hash, input log and result whichever language it was read in.
    func testOneBattleReadsInEitherLanguageAndItsResultIgnoresThem() throws {
        let engine = try engine()
        func played(reading language: AppLanguage) throws -> PracticeBattle {
            let battle = PracticeBattle(engine: engine)
            battle.start(player: try candidate("a", "Pikachu", species: 25, moves: ["thunderbolt"], engine: engine),
                         opponent: try candidate("b", "Magikarp", species: 129, moves: ["splash"], engine: engine),
                         mode: .automatic, seed: [1, 2, 3, 4])
            _ = battle.messages(L(language))   // Reading mid-battle changes nothing.
            battle.runToEnd()
            XCTAssertEqual(battle.phase, .finished)
            return battle
        }
        let english = try played(reading: .en), korean = try played(reading: .ko)
        let englishLines = english.messages(L(.en)), koreanLines = english.messages(L(.ko))
        XCTAssertEqual(englishLines.filter(hasHangul), [])
        XCTAssertEqual(englishLines.count, koreanLines.count)
        XCTAssertFalse(koreanLines.filter(hasHangul).isEmpty)
        XCTAssertEqual(englishLines.first, "Practice battle started. Growth and ownership stay as they are.")
        XCTAssertTrue(englishLines.contains("Pikachu · used Thunderbolt"), "\(englishLines)")
        let first = try XCTUnwrap(english.result), second = try XCTUnwrap(korean.result)
        XCTAssertEqual(first.logHash, second.logHash)
        XCTAssertEqual(first.winner, second.winner)
        XCTAssertEqual(try BattleJSON.encode(first.inputLog), try BattleJSON.encode(second.inputLog))
        XCTAssertFalse(try BattleJSON.encode(first.inputLog).contains("Practice battle"))
    }
    func testRecentMessagesAreNewestFirstWithoutTurnSeparators() throws {
        let engine = try engine()
        let battle = PracticeBattle(engine: engine)
        battle.start(player: try candidate("a", "Pikachu", species: 25, moves: ["thunderbolt"], engine: engine),
                     opponent: try candidate("b", "Magikarp", species: 129, moves: ["splash"], engine: engine),
                     mode: .automatic, seed: [1, 2, 3, 4])
        battle.runToEnd()
        let expected = Array(battle.messages(L(.en)).filter { !$0.hasPrefix("──") }.suffix(3).reversed())
        XCTAssertEqual(expected.count, 3)
        XCTAssertEqual(battle.recentMessages(L(.en), limit: 3), expected)
        XCTAssertEqual(battle.recentMessages(L(.en), limit: 1000).count, battle.messages(L(.en)).filter { !$0.hasPrefix("──") }.count)
    }

    // MARK: Online log

    func testEveryOnlineLogLineFollowsTheAppLanguage() {
        let table: [(String, String)] = [
            ("|tie", "Draw · the battle is over."),
            ("|turn|3", "── Turn 3 ──"),
            ("|win|p1", "Your Pokémon won · the battle is over."),
            ("|win|p2", "Opposing Pokémon won · the battle is over."),
            ("|-weather|RainDance", "Weather · Rain"),
            ("|-weather|none", "Weather · ended"),
            ("|-weather|<bad>", "Weather · Unknown weather"),
            ("|move|p1a: X|Quick Attack", "Your Pokémon · used Quick Attack"),
            ("|move|p2a: X|<bad>", "Opposing Pokémon · used Unknown move"),
            ("|-ability|p1a: X|Static", "Your Pokémon · ability Static revealed"),
            ("|-ability|p1a: X|<bad>", "Your Pokémon · ability Unknown ability revealed"),
            ("|-damage|p2a: X|32/100", "Opposing Pokémon · took damage (HP 32/100)."),
            ("|-heal|p1a: X|100/120", "Your Pokémon · recovered HP (HP 100/120)."),
            ("|switch|p1a: X|details", "Your Pokémon · entered the battle."),
            ("|faint|p2a: X", "Opposing Pokémon · fainted."),
            ("|-miss|p1a: X", "Your Pokémon · missed."),
            ("|-immune|p2a: X", "Opposing Pokémon · no effect."),
            ("|-fail|p1a: X", "Your Pokémon · the move failed."),
            ("|-status|p2a: X|par", "Opposing Pokémon · is now paralyzed."),
            ("|-status|p2a: X|new-status", "Opposing Pokémon · has a new status."),
            ("|-curestatus|p2a: X|par", "Opposing Pokémon · status cured."),
            ("|cant|p1a: X|flinch", "Your Pokémon · can't act."),
            ("|-boost|p1a: X|atk|2", "Your Pokémon · Attack up"),
            ("|-unboost|p2a: X|spe|1", "Opposing Pokémon · Speed down"),
            ("|-boost|p1a: X|new-stat|1", "Your Pokémon · Stats up"),
            ("|-supereffective|p2a: X", "Super effective!"),
            ("|-resisted|p2a: X", "Not very effective."),
            ("|-crit|p2a: X", "Critical hit!"),
            ("|-start|p1a: X|confusion", "Your Pokémon · confusion activated"),
            ("|-start|p1a: X|ability: Static", "Your Pokémon · Static activated"),
            ("|-end|p1a: X|move: Substitute", "Your Pokémon · Substitute ended"),
            ("|-start|p1a: X|<bad>", "Your Pokémon · Unknown effect activated"),
            ("|-future-private-tag|p1a: X|SECRET", "A battle effect took place."),
        ]
        for (raw, english) in table {
            XCTAssertEqual(OnlineBattleHistoryText.logs([raw], localSide: .p1, l: L(.en)), [english], raw)
            for language in otherLanguages {
                XCTAssertFalse(hasHangul(OnlineBattleHistoryText.logs([raw], localSide: .p1, l: L(language)).joined()), "\(language) \(raw)")
            }
        }
    }
    /// The filter of what may reach the screen holds in every language, not only in Korean.
    func testEnglishOnlineLogKeepsTheProtocolAndPayloadsOut() {
        let raw = ["|player|p1|private@example.com", "|-unknown|p1a: private@example.com|SECRET", "|raw|<script>SECRET</script>",
                   "|move|p1a: name|<script>SECRET</script>", "|metadata|p1a: private|secret"]
        let text = OnlineBattleHistoryText.logs(raw, localSide: .p1, l: L(.en)).joined()
        for leaked in ["SECRET", "secret", "private@", "<script>", "p1a"] { XCTAssertFalse(text.contains(leaked), leaked) }
    }
}
