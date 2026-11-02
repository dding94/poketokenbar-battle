import XCTest
@testable import PokeTokenBar

final class OnlineBattleResolverTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private struct Fixture: Decodable {
        let name: String
        let battle: OnlineBattleView
        let journalBytes: String
        let inputLog: BattleInputLog
        let rejectionCount: Int
        let forcedCount: Int
    }
    private func fixtures() throws -> [Fixture] {
        try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: root.appendingPathComponent("Tests/PokeTokenBarTests/Fixtures/OnlineBattle/golden.json")))
    }
    @MainActor private func engine() throws -> BattleEngine {
        try BattleEngine(url: root.appendingPathComponent("engine/dist/battle-engine.js"))
    }
    @MainActor func testNodeCorpusProducesIdenticalTerminalReports() throws {
        for fixture in try fixtures() {
            let resolver = try OnlineBattleResolver(battle: fixture.battle, localTrainerID: "trainer-one", engine: engine())
            try resolver.consume(journal: fixture.battle.journal)
            XCTAssertEqual(try resolver.terminalReport(), fixture.battle.result, fixture.name)
        }
    }
}
