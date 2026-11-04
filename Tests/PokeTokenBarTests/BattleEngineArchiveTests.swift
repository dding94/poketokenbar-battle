import CryptoKit
import XCTest
@testable import PokeTokenBar

final class BattleEngineArchiveTests: XCTestCase {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    @MainActor func testCurrentEngineIsPinnedAndArchivedBytesMatchEveryTrustedEntry() throws {
        XCTAssertNotNil(BattleEngineArchive.entry(for: BattleEngineManifest.sha256))
        XCTAssertFalse(BattleEngineArchive.entries.isEmpty)
        for entry in BattleEngineArchive.entries {
            let url = root.appendingPathComponent("engine/archive/\(entry.hash).js")
            let data = try Data(contentsOf: url)
            XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), entry.hash)
            let engine = try BattleEngine(url: url, expectedHash: entry.hash)
            struct Version: Decodable { let engine: String; let adapter: String; let rules: String }
            let version: Version = try BattleJSON.decode(engine.call(.version))
            XCTAssertEqual(version.engine, entry.engineVersion)
            XCTAssertEqual(version.adapter, entry.adapterVersion)
            XCTAssertEqual(version.rules, entry.rulesVersion)
        }
    }
    @MainActor func testResourceLookupLoadsPinnedHistoricalPathAndRejectsMissingCorruptUnknown() throws {
        let resources = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: resources.appendingPathComponent("battle-engines"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: resources) }
        let hash = BattleEngineManifest.sha256
        XCTAssertThrowsError(try BattleEngineArchive.engine(hash: hash, resources: resources))
        let archive = resources.appendingPathComponent("battle-engines/\(hash).js")
        try FileManager.default.copyItem(at: root.appendingPathComponent("engine/dist/battle-engine.js"), to: archive)
        XCTAssertNoThrow(try BattleEngineArchive.engine(hash: hash, resources: resources))
        XCTAssertThrowsError(try BattleEngineArchive.engine(hash: String(repeating: "a", count: 64), resources: resources))
        try Data("globalThis.PTBEngine = {};".utf8).write(to: archive)
        XCTAssertThrowsError(try BattleEngineArchive.engine(hash: hash, resources: resources))
        XCTAssertThrowsError(try BattleEngineArchive.engine(hash: "../../battle-engine", resources: resources))
    }
    @MainActor func testCurrentResourceIsAcceptedWithoutDuplicatingArchiveResource() throws {
        let resources = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: resources) }
        try FileManager.default.copyItem(at: root.appendingPathComponent("engine/dist/battle-engine.js"), to: resources.appendingPathComponent("battle-engine.js"))
        XCTAssertNoThrow(try BattleEngineArchive.engine(hash: BattleEngineManifest.sha256, resources: resources))
    }
}
