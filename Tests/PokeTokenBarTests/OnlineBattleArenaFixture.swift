import XCTest
@testable import PokeTokenBar

/// A live online arena built from the golden battles and the real engine: a resolver seated as one of the two
/// players, its staging and a presentation model that reads them the way the session publishes them. Synthetic
/// data only; nothing touches the network, Keychain or a save.
@MainActor
enum OnlineBattleArenaFixture {
    private struct Golden: Decodable { let name: String; let battle: OnlineBattleView }
    final class Clock { var now = 100.0 }

    @MainActor struct Arena {
        let model: OnlineBattlePresentation
        let staging: OnlineBattleStaging
        let resolver: OnlineBattleResolver
        let clock: Clock
        let battle: OnlineBattleView
        func close() { resolver.close() }
        /// Hands the next `count` journal rounds to the resolver and stages them as a visible manual round would.
        func play(rounds count: Int, mode: OnlineBattleMode? = nil, secondsLeft: TimeInterval? = 30) throws {
            let target = min(battle.journal.count, resolver.journal.count + count)
            try resolver.consume(journal: Array(battle.journal.prefix(target)))
            staging.ingest(resolver, mode: mode ?? battle.mode, visible: true, secondsLeft: secondsLeft)
            publish()
        }
        /// Copies what `OnlineBattleSession.publish` copies for the arena.
        func publish() {
            model.stage = staging
            model.arena = resolver.view ?? staging.lastView
            model.request = resolver.request
            model.liveLogs = OnlineBattleHistoryText.logs(resolver.logs, localSide: model.localSide)
        }
    }

    static var engineURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("engine/dist/battle-engine.js")
    }

    static func golden(_ name: String) throws -> OnlineBattleView {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "golden", withExtension: "json", subdirectory: "OnlineBattle"))
        return try XCTUnwrap(JSONDecoder().decode([Golden].self, from: Data(contentsOf: url)).first { $0.name == name }).battle
    }

    /// The golden battle as a live room: running, no result, and the other seat's frozen set hidden as the server does.
    static func liveRoom(_ name: String, seat: OnlineBattleSide, deadline: Double?, ownChoice: Bool = false) throws -> OnlineBattleView {
        let archived = try golden(name)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: BattleJSON.encoder().encode(archived)) as? [String: Any])
        json["state"] = "RUNNING"; json["result"] = NSNull(); json["reason"] = NSNull()
        json["createdAt"] = 1_793_683_500_000
        json["deadline"] = deadline.map { $0 as Any } ?? NSNull()
        json["ownChoice"] = ownChoice ? "move" : NSNull()
        let other = seat == .p1 ? "p2" : "p1"
        var hidden = try XCTUnwrap(json[other] as? [String: Any])
        hidden["snapshot"] = NSNull()
        json[other] = hidden
        return try JSONDecoder().decode(OnlineBattleView.self, from: JSONSerialization.data(withJSONObject: json))
    }

    static func arena(seat: OnlineBattleSide = .p1, name: String = "manual", mode: OnlineBattleMode? = nil,
                      ownChoice: Bool = false) throws -> Arena {
        let battle = try golden(name)
        let trainer = seat == .p1 ? "trainer-one" : "trainer-two"
        let resolver = try OnlineBattleResolver(battle: battle, localTrainerID: trainer, engine: BattleEngine(url: engineURL))
        let clock = Clock()
        let staging = OnlineBattleStaging(resolver: resolver, clock: { clock.now })
        staging.ingest(resolver, mode: mode ?? battle.mode, visible: true, secondsLeft: 30)
        let model = OnlineBattleScreenRenderingTests.model()
        let room = try liveRoom(name, seat: seat, deadline: (Date().timeIntervalSince1970 + 30) * 1000, ownChoice: ownChoice)
        model.phase = .arena; model.room = room; model.localSide = seat
        model.deadline = Date().addingTimeInterval(30)
        model.choiceSubmitted = ownChoice
        let own = (seat == .p1 ? battle.p1 : battle.p2).snapshot
        if let own {
            model.moveSlugs[seat] = Dictionary(uniqueKeysWithValues: own.set.moves.map { (normalized($0), $0) })
            model.abilitySlugs[seat] = [normalized(own.set.ability): own.set.ability]
        }
        let arena = Arena(model: model, staging: staging, resolver: resolver, clock: clock, battle: battle)
        arena.publish()
        return arena
    }

    static func normalized(_ value: String) -> String { value.lowercased().filter { $0.isLetter || $0.isNumber } }
}
