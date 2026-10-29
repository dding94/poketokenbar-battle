import XCTest
@testable import PokeTokenBar

final class BattleEngineTests: XCTestCase {
    private var engineURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("engine/dist/battle-engine.js")
    }
    private var expectedHash: String {
        get throws {
            try String(contentsOf: engineURL.deletingLastPathComponent().appendingPathComponent("battle-engine.sha256"), encoding: .utf8)
                .split(separator: " ")[0].description
        }
    }
    @MainActor func testLoadsVersionThroughJSONBoundary() throws {
        let engine = try BattleEngine(url: engineURL, expectedHash: expectedHash)
        let data = Data(try engine.call(.version).utf8)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(value["engine"], "@pkmn/sim@0.10.12")
        XCTAssertEqual(value["rules"], "gen9-notera-noitems-v1")
    }
    @MainActor func testMissingBundleIsAnExplicitError() {
        XCTAssertThrowsError(try BattleEngine(url: nil, expectedHash: "")) {
            XCTAssertEqual($0 as? BattleEngine.Failure, .missingBundle)
        }
    }
    @MainActor func testModifiedBundleIsRejectedBeforeEvaluation() {
        XCTAssertThrowsError(try BattleEngine(url: engineURL, expectedHash: String(repeating: "0", count: 64))) {
            XCTAssertEqual($0 as? BattleEngine.Failure, .checksumMismatch)
        }
    }
    @MainActor func testUntrustedJSONNeverBecomesJavaScriptSource() throws {
        let engine = try BattleEngine(url: engineURL, expectedHash: expectedHash)
        XCTAssertThrowsError(try engine.call(.createBattle, arguments: [">eval globalThis.hacked=true"])) {
            XCTAssertEqual($0 as? BattleEngine.Failure, .engine("invalid_json"))
        }
        XCTAssertNoThrow(try engine.call(.version))
    }
}
