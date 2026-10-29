import XCTest
@testable import PokeTokenBar

@MainActor
final class PracticeHintsTests: XCTestCase {
    private final class Clock { var now = 0.0 }
    private var engineURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("engine/dist/battle-engine.js")
    }

    /// One individual of a synthetic save: id, species number, ability, level and moves (PokéAPI slugs).
    private struct Spec {
        let id: String
        let species: Int
        let moves: [String]
        var ability = "pressure"
        var level = 50
    }
    private func state(_ specs: [Spec]) -> CompanionState {
        var state = CompanionState()
        state.dex = specs.map { spec in
            var profile = PokemonProfile.generate(seed: 42, instanceID: spec.id)
            profile.level = spec.level; profile.gender = .male; profile.abilityName = spec.ability
            profile.moves = spec.moves.map { PokemonKnownMove(name: $0, learnedAtLevel: 1) }
            return DexEntry(baseID: spec.species, finalID: spec.species, chainOrder: [spec.species], rarity: .common,
                            caughtAt: nil, nature: .hardy, profile: profile)
        }
        return state
    }
    private func pikachu(_ id: String = "p", moves: [String] = ["thunderbolt", "quick-attack", "iron-tail", "volt-tackle"],
                         level: Int = 50) -> Spec {
        Spec(id: id, species: 25, moves: moves, ability: "static", level: level)
    }
    private func magikarp(_ id: String = "m", level: Int = 50) -> Spec {
        Spec(id: id, species: 129, moves: ["splash", "tackle", "flail", "bounce"], ability: "swift-swim", level: level)
    }
    private func blissey(_ id: String) -> Spec { Spec(id: id, species: 242, moves: ["tackle"]) }

    private func makeSession(_ clock: Clock, _ specs: [Spec], player: String? = nil, opponent: String? = nil,
                             mode: PracticeBattle.Mode = .manual) -> PracticeSession {
        let session = PracticeSession(engineURL: engineURL, clock: { clock.now }, drivesAutomatically: false)
        session.prepare(state: state(specs), activeName: nil)
        if let player { session.playerID = player }
        if let opponent { session.opponentID = opponent }
        session.mode = mode
        return session
    }
    private func matchup(_ session: PracticeSession) throws -> PracticeMatchup { try XCTUnwrap(session.matchup) }
    private func expectedOrder(_ player: Int, _ opponent: Int) -> PracticeMatchup.Order {
        player > opponent ? .playerFirst : player < opponent ? .opponentFirst : .speedTie
    }
    private func speed(_ candidate: PracticeCandidate?) throws -> Int {
        try XCTUnwrap(candidate?.snapshot?.publicInfo.stats["spe"])
    }
    private func chart() throws -> PracticeTypeChart {
        let engine = try BattleEngine(url: engineURL)
        return try BattleJSON.decode(engine.call(.typeChart))
    }
    /// Turn 1: the player's Tackle, then a poison tick (an action beat of 0.9 s and a residual beat of 0.6 s).
    private let tackleTurn: [PracticeEvent] = [
        .switchIn(.player, hp: 100, maxHP: 100), .switchIn(.opponent, hp: 100, maxHP: 100), .turn(1),
        .move(.player, moveID: "tackle"), .damage(.opponent, hp: 80, maxHP: 100, cause: nil),
        .damage(.player, hp: 90, maxHP: 100, cause: "psn"),
    ]

    // MARK: type chart

    func testChartSingleTypeMultipliers() throws {
        let chart = try chart()
        XCTAssertEqual(chart.multiplier(attack: "Electric", defenders: ["Water"]), 2)
        XCTAssertEqual(chart.multiplier(attack: "Steel", defenders: ["Water"]), 0.5)
        XCTAssertEqual(chart.multiplier(attack: "Normal", defenders: ["Normal"]), 1)
        XCTAssertEqual(chart.types.count, 18)
    }

    func testChartMultipliesAcrossDualTypes() throws {
        let chart = try chart()
        XCTAssertEqual(chart.multiplier(attack: "Electric", defenders: ["Water", "Flying"]), 4)
        XCTAssertEqual(chart.multiplier(attack: "Grass", defenders: ["Water", "Ground"]), 4)
        XCTAssertEqual(chart.multiplier(attack: "Water", defenders: ["Water", "Grass"]), 0.25)
        XCTAssertEqual(chart.multiplier(attack: "Fire", defenders: ["Water", "Grass"]), 1, "x0.5 and x2 cancel out")
    }

    func testChartImmunityWinsOverEveryOtherType() throws {
        let chart = try chart()
        XCTAssertEqual(chart.multiplier(attack: "Electric", defenders: ["Ground"]), 0)
        XCTAssertEqual(chart.multiplier(attack: "Electric", defenders: ["Water", "Ground"]), 0)
        XCTAssertEqual(chart.multiplier(attack: "Ground", defenders: ["Flying", "Steel"]), 0)
    }

    func testChartIsNilForUnknownTypesAndEmptyDefenders() throws {
        let chart = try chart()
        XCTAssertNil(chart.multiplier(attack: "Shadow", defenders: ["Water"]))
        XCTAssertNil(chart.multiplier(attack: "Electric", defenders: ["Bogus"]))
        XCTAssertNil(chart.multiplier(attack: "Electric", defenders: ["Water", "Bogus"]))
        XCTAssertNil(chart.multiplier(attack: "Electric", defenders: []))
        XCTAssertNil(chart.multiplier(attack: "electric", defenders: ["Water"]), "type names are matched as the engine spells them")
    }

    // MARK: prepare

    func testPrepareLoadsTheChartAndMoveInfoKeyedByShowdownId() throws {
        let session = makeSession(Clock(), [pikachu(), magikarp()])
        XCTAssertEqual(session.typeChart?.types.count, 18)
        XCTAssertEqual(session.typeChart?.multiplier(attack: "Electric", defenders: ["Water"]), 2)
        let bolt = try XCTUnwrap(session.moveInfo["thunderbolt"])
        XCTAssertEqual(bolt.name, "Thunderbolt"); XCTAssertEqual(bolt.type, "Electric")
        XCTAssertEqual(bolt.category, "Special"); XCTAssertEqual(bolt.basePower, 90); XCTAssertEqual(bolt.accuracy, 100)
        XCTAssertFalse(bolt.isStatus)
        let tackle = try XCTUnwrap(session.moveInfo["volttackle"], "the slug volt-tackle is keyed by its Showdown id")
        XCTAssertEqual(tackle.name, "Volt Tackle"); XCTAssertEqual(tackle.basePower, 120)
        XCTAssertEqual(session.moveInfo["quickattack"]?.priority, 1)
        XCTAssertEqual(session.moveInfo["irontail"]?.type, "Steel")
        let splash = try XCTUnwrap(session.moveInfo["splash"])
        XCTAssertTrue(splash.isStatus); XCTAssertNil(splash.accuracy, "a move that never misses has no accuracy")
        XCTAssertEqual(Set(session.moveInfo.keys),
                       ["thunderbolt", "quickattack", "irontail", "volttackle", "splash", "tackle", "flail", "bounce"])
    }

    func testPrepareKeepsTheLoadedDataAndReleaseIfIdleDropsItWithTheEngine() throws {
        let session = makeSession(Clock(), [pikachu(), magikarp()])
        let chart = session.typeChart, info = session.moveInfo
        XCTAssertNotNil(chart); XCTAssertFalse(info.isEmpty)
        session.prepare(state: state([pikachu(), magikarp()]), activeName: nil)
        XCTAssertEqual(session.typeChart, chart); XCTAssertEqual(session.moveInfo, info)
        session.releaseIfIdle()
        XCTAssertNil(session.typeChart); XCTAssertTrue(session.moveInfo.isEmpty); XCTAssertNil(session.matchup)
        session.prepare(state: state([pikachu(), magikarp()]), activeName: nil)
        XCTAssertEqual(session.typeChart, chart); XCTAssertEqual(session.moveInfo, info)
    }

    func testReleaseIfIdleKeepsTheDataOfARunningBattle() throws {
        let session = makeSession(Clock(), [pikachu(), magikarp()], player: "p", opponent: "m")
        session.start(); session.releaseIfIdle()
        XCTAssertNotNil(session.typeChart); XCTAssertFalse(session.moveInfo.isEmpty)
        XCTAssertNotNil(session.moveHint("thunderbolt"))
    }

    // MARK: matchup

    func testMatchupPikachuAgainstMagikarp() throws {
        let session = makeSession(Clock(), [pikachu(), magikarp()], player: "p", opponent: "m")
        let found = try matchup(session)
        XCTAssertEqual(found.bestOffense, 2)
        XCTAssertEqual(found.bestMoveIDs, ["thunderbolt", "volttackle"], "Electric moves, in the player's move order")
        XCTAssertEqual(found.threat, 1, "Water against Electric is neutral; it is Electric that beats Water")
        let playerSpeed = try speed(session.player), opponentSpeed = try speed(session.opponent)
        XCTAssertEqual(found.playerSpeed, playerSpeed); XCTAssertEqual(found.opponentSpeed, opponentSpeed)
        XCTAssertEqual(found.order, expectedOrder(playerSpeed, opponentSpeed))
        XCTAssertEqual(found.levelGap, 0)
    }

    func testMatchupSwappedSidesFlipsOrderAndThreat() throws {
        let session = makeSession(Clock(), [pikachu(), magikarp()], player: "m", opponent: "p")
        let found = try matchup(session)
        XCTAssertEqual(found.threat, 2, "Electric against Water")
        XCTAssertEqual(found.bestOffense, 1, "Normal x1, Flying against Electric x0.5, the rest are status")
        XCTAssertEqual(found.bestMoveIDs, [], "nothing beats x1, so nothing is recommended")
        let playerSpeed = try speed(session.player), opponentSpeed = try speed(session.opponent)
        XCTAssertEqual(found.order, expectedOrder(playerSpeed, opponentSpeed))
    }

    func testMatchupLevelGapIsOpponentMinusPlayer() throws {
        let weaker = makeSession(Clock(), [pikachu(), magikarp(level: 30)], player: "p", opponent: "m")
        XCTAssertEqual(try matchup(weaker).levelGap, -20)
        let stronger = makeSession(Clock(), [pikachu(level: 20), magikarp()], player: "p", opponent: "m")
        let found = try matchup(stronger)
        XCTAssertEqual(found.levelGap, 30)
        let playerSpeed = try speed(stronger.player), opponentSpeed = try speed(stronger.opponent)
        XCTAssertEqual(found.order, expectedOrder(playerSpeed, opponentSpeed))
        XCTAssertEqual(found.order, .opponentFirst, "a level 50 Magikarp outspeeds a level 20 Pikachu")
    }

    func testMatchupEqualSpeedsAreATie() throws {
        let session = makeSession(Clock(), [blissey("a"), blissey("b")], player: "a", opponent: "b")
        let found = try matchup(session)
        XCTAssertEqual(found.playerSpeed, found.opponentSpeed)
        XCTAssertEqual(found.order, .speedTie)
    }

    func testMatchupResistedOnlyOffenseNamesTheLeastBadMoves() throws {
        let session = makeSession(Clock(), [pikachu(moves: ["iron-tail"]), magikarp()], player: "p", opponent: "m")
        let found = try matchup(session)
        XCTAssertEqual(found.bestOffense, 0.5); XCTAssertEqual(found.bestMoveIDs, ["irontail"], "below 1 is worth a warning too")
    }

    func testMatchupWhereEveryDamagingMoveIsImmuneNamesThemAtZero() throws {
        let geodude = Spec(id: "g", species: 74, moves: ["rock-throw"], ability: "sturdy")
        let found = try matchup(makeSession(Clock(), [pikachu(moves: ["thunderbolt", "volt-tackle"]), geodude], player: "p", opponent: "g"))
        XCTAssertEqual(found.bestOffense, 0); XCTAssertEqual(found.bestMoveIDs, ["thunderbolt", "volttackle"])
    }

    func testMatchupWithOnlyStatusMovesHasNoOffenseAtAll() throws {
        let splasher = Spec(id: "s", species: 129, moves: ["splash"], ability: "swift-swim")
        let found = try matchup(makeSession(Clock(), [splasher, pikachu()], player: "s", opponent: "p"))
        XCTAssertEqual(found.bestOffense, 0, "no damaging move is different from a neutral one")
        XCTAssertEqual(found.bestMoveIDs, [])
    }

    func testMatchupNeutralBestKeepsTheMoveListEmpty() throws {
        let found = try matchup(makeSession(Clock(), [pikachu(moves: ["quick-attack", "iron-tail"]), magikarp()], player: "p", opponent: "m"))
        XCTAssertEqual(found.bestOffense, 1); XCTAssertEqual(found.bestMoveIDs, [])
    }

    // MARK: matchup: fixed-damage and variable-type moves

    /// Fixed-damage moves (levels, set amounts, HP, one-hit KOs) ignore effectiveness except immunity. Each row is a move
    /// and a target that the move's listed type would hit super effectively.
    func testFixedDamageMovesNeverCountAsSuperEffectiveInTheMatchup() throws {
        let rows: [(String, Int)] = [
            ("night-shade", 65), ("seismic-toss", 242), ("counter", 242), ("fissure", 25), ("dragon-rage", 149),
            ("sheer-cold", 149), ("psywave", 68), ("mirror-coat", 68),
        ]
        for (move, target) in rows {
            let player = Spec(id: "x", species: 94, moves: [move])
            let found = try matchup(makeSession(Clock(), [player, Spec(id: "t", species: target, moves: ["tackle"])], player: "x", opponent: "t"))
            XCTAssertEqual(found.bestOffense, 1, "\(move) against species \(target)")
            XCTAssertEqual(found.bestMoveIDs, [], move)
        }
    }

    func testFixedDamageMovesStillRespectImmunityInTheMatchup() throws {
        let rows: [(String, Int)] = [
            ("night-shade", 242), ("seismic-toss", 94), ("horn-drill", 94), ("guillotine", 94), ("sonic-boom", 94),
            ("super-fang", 94), ("endeavor", 94), ("fissure", 18), ("dragon-rage", 36), ("mirror-coat", 197),
        ]
        for (move, target) in rows {
            let player = Spec(id: "x", species: 25, moves: [move])
            let found = try matchup(makeSession(Clock(), [player, Spec(id: "t", species: target, moves: ["tackle"])], player: "x", opponent: "t"))
            XCTAssertEqual(found.bestOffense, 0, "\(move) against species \(target)")
            XCTAssertEqual(found.bestMoveIDs, [move.replacingOccurrences(of: "-", with: "")], move)
        }
    }

    func testFixedDamageMoveDoesNotHideARealWeakSpot() throws {
        let gengar = Spec(id: "g", species: 94, moves: ["night-shade", "shadow-ball"])
        let alakazam = Spec(id: "a", species: 65, moves: ["psychic"])
        let found = try matchup(makeSession(Clock(), [gengar, alakazam], player: "g", opponent: "a"))
        XCTAssertEqual(found.bestOffense, 2); XCTAssertEqual(found.bestMoveIDs, ["shadowball"])
    }

    func testVariableTypeMovesCountAsNeutralInTheMatchup() throws {
        // Hidden Power is never Normal, so a Ghost target is not immune to it; Weather Ball changes with the weather.
        let rows: [(Int, String, Int)] = [(201, "hidden-power", 94), (351, "weather-ball", 94), (201, "hidden-power", 65)]
        for (species, move, target) in rows {
            let player = Spec(id: "x", species: species, moves: [move], ability: "levitate")
            let found = try matchup(makeSession(Clock(), [player, Spec(id: "t", species: target, moves: ["tackle"])], player: "x", opponent: "t"))
            XCTAssertEqual(found.bestOffense, 1, "\(move) against species \(target)")
            XCTAssertEqual(found.bestMoveIDs, [], move)
        }
    }

    func testMoveInfoIsFoundUnderTheSlugAliasAndTheCanonicalId() throws {
        // "vice-grip" is an alias; the engine answers with its own id, "visegrip".
        let machop = Spec(id: "m", species: 66, moves: ["vice-grip"])
        let session = makeSession(Clock(), [machop, pikachu()], player: "m", opponent: "p")
        XCTAssertEqual(session.moveInfo["visegrip"]?.name, "Vise Grip")
        XCTAssertEqual(session.moveInfo["vicegrip"], session.moveInfo["visegrip"])
        XCTAssertNotNil(session.moveInfo["visegrip"])
        let found = try matchup(session)
        XCTAssertEqual(found.bestOffense, 1, "the alias move is a damaging move, not a missing one")
        session.start()
        XCTAssertNotNil(session.moveHint("visegrip"))
    }

    func testMatchupUsesBothTypesOfTheOpponentAndTheThreatOfEachOfItsTypes() throws {
        // Rhydon (Ground/Rock) against Gyarados (Water/Flying): Rock Slide is x2, Earthquake misses a Flying type.
        let rhydon = Spec(id: "r", species: 112, moves: ["earthquake", "rock-slide"], ability: "rock-head")
        let gyarados = Spec(id: "g", species: 130, moves: ["tackle"], ability: "intimidate")
        let found = try matchup(makeSession(Clock(), [rhydon, gyarados], player: "r", opponent: "g"))
        XCTAssertEqual(found.bestOffense, 2); XCTAssertEqual(found.bestMoveIDs, ["rockslide"])
        XCTAssertEqual(found.threat, 4, "Water against Ground/Rock beats Flying against it")
    }

    func testMatchupThreatCanBeAnImmunity() throws {
        let geodude = Spec(id: "g", species: 74, moves: ["rock-throw"], ability: "sturdy")
        let found = try matchup(makeSession(Clock(), [geodude, pikachu()], player: "g", opponent: "p"))
        XCTAssertEqual(found.threat, 0, "Electric cannot hurt Rock/Ground")
        XCTAssertEqual(found.bestOffense, 1, "Rock against Electric")
    }

    func testMatchupNeedsBothSidesAndTheChart() throws {
        let solo = makeSession(Clock(), [pikachu()])
        XCTAssertNil(solo.opponent); XCTAssertNil(solo.matchup)
        let session = makeSession(Clock(), [pikachu(), magikarp()], player: "p", opponent: "m")
        XCTAssertNotNil(session.matchup)
        session.opponentID = nil
        XCTAssertNil(session.matchup)
    }

    // MARK: move hints

    private func runningSession(_ clock: Clock = Clock()) throws -> PracticeSession {
        let player = pikachu(moves: ["thunderbolt", "quick-attack", "iron-tail", "thunder-wave"])
        let session = makeSession(clock, [player, magikarp()], player: "p", opponent: "m")
        session.start()
        XCTAssertEqual(session.battle?.phase, .running)
        return session
    }

    func testMoveHintShowsMultiplierStabAndInfo() throws {
        let session = try runningSession()
        let bolt = try XCTUnwrap(session.moveHint("thunderbolt"))
        XCTAssertEqual(bolt.multiplier, 2); XCTAssertTrue(bolt.stab)
        XCTAssertEqual(bolt.info.basePower, 90); XCTAssertEqual(bolt.info.name, "Thunderbolt")
        let quick = try XCTUnwrap(session.moveHint("quickattack"))
        XCTAssertEqual(quick.multiplier, 1); XCTAssertFalse(quick.stab); XCTAssertEqual(quick.info.priority, 1)
        let tail = try XCTUnwrap(session.moveHint("irontail"))
        XCTAssertEqual(tail.multiplier, 0.5, "Steel against Water"); XCTAssertFalse(tail.stab)
    }

    func testMoveHintHasNoMultiplierForStatusMoves() throws {
        let session = try runningSession()
        let wave = try XCTUnwrap(session.moveHint("thunderwave"))
        XCTAssertTrue(wave.info.isStatus); XCTAssertNil(wave.multiplier)
    }

    func testMoveHintIsNilForMovesTheRosterNeverHad() throws {
        let session = try runningSession()
        XCTAssertNil(session.moveHint("recharge")); XCTAssertNil(session.moveHint("struggle"))
        XCTAssertNil(session.moveHint("nosuchmove")); XCTAssertNil(session.moveHint(""))
    }

    func testMoveHintOutsideABattleHasInfoButNoMultiplierOrStab() throws {
        let session = makeSession(Clock(), [pikachu(), magikarp()], player: "p", opponent: "m")
        XCTAssertNil(session.battle)
        let bolt = try XCTUnwrap(session.moveHint("thunderbolt"))
        XCTAssertNil(bolt.multiplier); XCTAssertFalse(bolt.stab)
    }

    private func hintSession(_ player: Spec, against opponent: Int) -> PracticeSession {
        let session = makeSession(Clock(), [player, Spec(id: "t", species: opponent, moves: ["tackle"])], player: player.id, opponent: "t")
        session.start()
        return session
    }

    func testFixedDamageMoveHintsShowNeutralWithoutStabAndImmunityAsZero() throws {
        let gengar = Spec(id: "g", species: 94, moves: ["night-shade", "shadow-ball"])
        let weak = hintSession(gengar, against: 65)
        let shade = try XCTUnwrap(weak.moveHint("nightshade"))
        XCTAssertTrue(shade.info.fixedDamage)
        XCTAssertEqual(shade.multiplier, 1, "Night Shade ignores the Psychic weakness"); XCTAssertFalse(shade.stab, "no STAB on fixed damage")
        let ball = try XCTUnwrap(weak.moveHint("shadowball"))
        XCTAssertEqual(ball.multiplier, 2); XCTAssertTrue(ball.stab)
        let immune = hintSession(gengar, against: 242)
        XCTAssertEqual(immune.moveHint("nightshade")?.multiplier, 0); XCTAssertEqual(immune.moveHint("nightshade")?.stab, false)
        let toss = hintSession(Spec(id: "b", species: 242, moves: ["seismic-toss"]), against: 94)
        XCTAssertEqual(toss.moveHint("seismictoss")?.multiplier, 0, "Fighting cannot touch a Ghost")
        let normalTarget = hintSession(Spec(id: "b", species: 242, moves: ["seismic-toss"]), against: 242)
        XCTAssertEqual(normalTarget.moveHint("seismictoss")?.multiplier, 1, "Fighting is x2 on Normal, but the damage is fixed")
        XCTAssertEqual(normalTarget.moveHint("seismictoss")?.stab, false)
    }

    func testVariableTypeMoveHintsHaveNeitherMultiplierNorStab() throws {
        // The engine lists all of these as Normal; Castform and Arceus are Normal themselves, so STAB would show without the guard.
        let rows: [(Int, String)] = [(201, "hidden-power"), (351, "weather-ball"), (493, "judgment"), (649, "techno-blast")]
        for (species, move) in rows {
            let session = hintSession(Spec(id: "x", species: species, moves: [move], ability: "levitate"), against: 65)
            let hint = try XCTUnwrap(session.moveHint(move.replacingOccurrences(of: "-", with: "")), move)
            XCTAssertTrue(hint.info.variableType, move)
            XCTAssertNil(hint.multiplier, move); XCTAssertFalse(hint.stab, move)
        }
    }

    // MARK: playback speed

    func testSpeedTimeScales() {
        XCTAssertEqual(PracticePlaybackSpeed.normal.timeScale, 1)
        XCTAssertEqual(PracticePlaybackSpeed.fast.timeScale, 0.5)
        XCTAssertEqual(PracticePlaybackSpeed.instant.timeScale, 0)
    }

    func testPlaybackTimeScaleShortensEveryBeat() {
        let clock = Clock(); let playback = PracticePlayback(clock: { clock.now })
        playback.timeScale = 0.5
        playback.enqueue(tackleTurn)
        XCTAssertNotNil(playback.beat)
        clock.now = 0.44; playback.advance()
        XCTAssertEqual(playback.beat?.moveID, "tackle", "an action beat lasts 0.45 s at half scale")
        clock.now = 0.45; playback.advance()
        XCTAssertEqual(playback.history.count, 1)
        XCTAssertNotNil(playback.beat, "the residual beat started at 0.45")
        clock.now = 0.74; playback.advance()
        XCTAssertEqual(playback.history.count, 1, "a residual beat lasts 0.3 s at half scale")
        clock.now = 0.76; playback.advance()
        XCTAssertEqual(playback.history.count, 2); XCTAssertFalse(playback.isPlaying)
    }

    func testPlaybackAtNormalScaleStillTakesFullBeats() {
        let clock = Clock(); let playback = PracticePlayback(clock: { clock.now })
        playback.enqueue(tackleTurn)
        clock.now = 0.89; playback.advance(); XCTAssertEqual(playback.history.count, 0)
        clock.now = 0.9; playback.advance(); XCTAssertEqual(playback.history.count, 1)
    }

    func testChangingTheScaleMidBeatRecomputesTheEndFromItsStart() {
        let clock = Clock(); let playback = PracticePlayback(clock: { clock.now })
        playback.enqueue(tackleTurn)
        clock.now = 0.3; playback.timeScale = 0.5
        clock.now = 0.44; playback.advance(); XCTAssertEqual(playback.history.count, 0)
        clock.now = 0.45; playback.advance(); XCTAssertEqual(playback.history.count, 1, "0 + 0.9 x 0.5, not 0.3 + 0.45")

        let slower = Clock(); let other = PracticePlayback(clock: { slower.now })
        other.enqueue(tackleTurn)
        slower.now = 0.5; other.timeScale = 2
        slower.now = 1.79; other.advance(); XCTAssertEqual(other.history.count, 0)
        slower.now = 1.8; other.advance(); XCTAssertEqual(other.history.count, 1)
    }

    func testShrinkingTheScalePastTheElapsedTimeEndsTheBeatOnTheNextAdvance() {
        let clock = Clock(); let playback = PracticePlayback(clock: { clock.now })
        playback.enqueue(tackleTurn)
        clock.now = 0.8; playback.timeScale = 0.5
        playback.advance()
        XCTAssertEqual(playback.history.count, 1)
    }

    func testSessionFastSpeedHalvesTheBeatOnScreen() throws {
        let clock = Clock()
        let session = makeSession(clock, [blissey("a"), blissey("b")], mode: .automatic)
        session.start()
        let playback = try XCTUnwrap(session.playback)
        session.playbackSpeed = .fast
        XCTAssertEqual(playback.timeScale, 0.5)
        clock.now = 1; session.tick()
        XCTAssertEqual(session.battle?.view?.turn, 2); XCTAssertEqual(playback.history.count, 0)
        clock.now = 1.44; session.tick(); XCTAssertEqual(playback.history.count, 0)
        clock.now = 1.46; session.tick(); XCTAssertEqual(playback.history.count, 1)
        session.start()
        XCTAssertEqual(session.playback?.timeScale, 0.5, "a new battle plays at the chosen speed")
        session.playbackSpeed = .normal
        XCTAssertEqual(session.playback?.timeScale, 1)
    }

    func testSessionSpeedChangeMidBeatShortensTheBeatOnScreen() throws {
        let clock = Clock()
        let session = makeSession(clock, [blissey("a"), blissey("b")], mode: .automatic)
        session.start()
        let playback = try XCTUnwrap(session.playback)
        clock.now = 1; session.tick()
        XCTAssertNotNil(playback.beat); XCTAssertEqual(playback.history.count, 0)
        clock.now = 1.3; session.playbackSpeed = .fast
        clock.now = 1.44; session.tick(); XCTAssertEqual(playback.history.count, 0)
        clock.now = 1.46; session.tick(); XCTAssertEqual(playback.history.count, 1)
    }

    func testInstantSpeedSkipsStagingAndNeverHoldsTheBattle() throws {
        let clock = Clock()
        let session = makeSession(clock, [blissey("a"), blissey("b")], mode: .automatic)
        session.playbackSpeed = .instant
        session.start()
        let playback = try XCTUnwrap(session.playback)
        clock.now = 1; session.tick()
        XCTAssertEqual(session.battle?.view?.turn, 2)
        XCTAssertFalse(playback.isPlaying); XCTAssertFalse(session.pauseReasons.contains(.playback))
        XCTAssertFalse(playback.history.isEmpty, "skipped beats still reach the history")
        XCTAssertEqual(session.battle?.isPaused, false)
        let played = playback.history.count
        clock.now = 2; session.tick()
        XCTAssertEqual(session.battle?.view?.turn, 3, "no turn waits for a beat nobody sees")
        XCTAssertGreaterThan(playback.history.count, played)
    }

    func testSwitchingToInstantMidPlaybackFlushesTheQueueAndReleasesTheHold() throws {
        let clock = Clock()
        let session = makeSession(clock, [blissey("a"), blissey("b")], mode: .automatic)
        session.start()
        let playback = try XCTUnwrap(session.playback)
        clock.now = 1; session.tick()
        XCTAssertTrue(playback.isPlaying); XCTAssertTrue(session.pauseReasons.contains(.playback))
        XCTAssertEqual(session.battle?.isPaused, true)
        session.playbackSpeed = .instant
        XCTAssertFalse(playback.isPlaying); XCTAssertNil(playback.beat)
        XCTAssertFalse(session.pauseReasons.contains(.playback)); XCTAssertEqual(session.battle?.isPaused, false)
        XCTAssertFalse(playback.history.isEmpty)
        XCTAssertEqual(playback.display[.opponent]?.hp, playback.history.last?.after[.opponent]?.hp)
    }

    // MARK: skipToResult

    func testSkipToResultFinishesAnAutomaticBattleAtOnceWithACompleteHistory() throws {
        let clock = Clock()
        let session = makeSession(clock, [pikachu(moves: ["thunderbolt"]), magikarp()], player: "p", opponent: "m", mode: .automatic)
        session.start()
        let playback = try XCTUnwrap(session.playback)
        session.skipToResult()
        XCTAssertEqual(session.battle?.phase, .finished)
        XCTAssertFalse(session.resultSeen); XCTAssertTrue(session.isActive)
        XCTAssertFalse(playback.isPlaying); XCTAssertNil(playback.beat)
        XCTAssertFalse(session.pauseReasons.contains(.playback))
        XCTAssertGreaterThan(playback.summary.turns, 0)
        XCTAssertEqual(playback.summary.finishingMoveID, "thunderbolt")
        XCTAssertEqual(playback.display[.opponent]?.fainted, true)
        XCTAssertTrue(playback.history.contains { $0.callouts.contains(.fainted(.opponent)) })
        XCTAssertEqual(session.battle?.events.last, .end(winner: .player))
        XCTAssertEqual(session.statusBadge, "\u{2691}")
    }

    func testSkipToResultMidPlaybackKeepsEveryEarlierBeatInOrder() throws {
        let clock = Clock()
        let session = makeSession(clock, [blissey("a"), blissey("b")], mode: .automatic)
        session.start()
        let playback = try XCTUnwrap(session.playback)
        clock.now = 1; session.tick()
        XCTAssertTrue(playback.isPlaying); XCTAssertEqual(session.battle?.isPaused, true)
        session.skipToResult()
        XCTAssertTrue(session.battle?.phase != .running,"the 200-turn cap ends even a stalemate")
        XCTAssertFalse(playback.isPlaying); XCTAssertFalse(session.pauseReasons.contains(.playback))
        XCTAssertEqual(session.battle?.isPaused, false)
        XCTAssertGreaterThan(playback.summary.turns, 2)
        XCTAssertEqual(playback.history.map(\.id), Array(0..<playback.history.count), "ids run on without gaps or repeats")
        XCTAssertEqual(playback.history.map(\.turn), playback.history.map(\.turn).sorted())
        XCTAssertEqual(playback.history.first?.turn, 1)
        XCTAssertEqual(playback.history.filter { $0.actor != nil }.count,
                       session.battle?.events.filter { if case .move = $0 { return true } else { return false } }.count,
                       "every move of the battle became a beat")
    }

    func testSkipToResultDoesNothingInManualMode() throws {
        let clock = Clock()
        let session = makeSession(clock, [pikachu(moves: ["thunderbolt"]), magikarp()], player: "p", opponent: "m")
        session.start()
        let playback = try XCTUnwrap(session.playback)
        session.skipToResult()
        XCTAssertEqual(session.battle?.phase, .running); XCTAssertEqual(session.battle?.view?.turn, 1)
        XCTAssertTrue(session.resultSeen); XCTAssertTrue(playback.history.isEmpty)
        XCTAssertEqual(session.battle?.mode, .manual)
    }

    func testSkipToResultNeedsARunningBattle() throws {
        let clock = Clock()
        let session = makeSession(clock, [pikachu(moves: ["thunderbolt"]), magikarp()], player: "p", opponent: "m", mode: .automatic)
        session.skipToResult()
        XCTAssertNil(session.battle); XCTAssertTrue(session.resultSeen)
        session.start(); session.skipToResult()
        let history = session.playback?.history.count
        session.markResultSeen(); session.skipToResult()
        XCTAssertTrue(session.resultSeen, "a finished battle is not played again")
        XCTAssertEqual(session.playback?.history.count, history)
    }
}
