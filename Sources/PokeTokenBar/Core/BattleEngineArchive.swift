import Foundation

/// Only locally shipped, explicitly pinned code may replay historical input.
/// Append entries when upgrading the live engine. Never replace an existing entry or its archived bytes.
enum BattleEngineArchive {
    struct Entry: Equatable {
        let hash: String
        let engineVersion: String
        let adapterVersion: String
        let rulesVersion: String
        let policyVersion: String
        let relayVersion: String

        func accepts(_ config: OnlineBattleConfig) -> Bool {
            config.engineHash == hash && config.rulesVersion == rulesVersion &&
            config.policyVersion == policyVersion && config.relayVersion == relayVersion
        }
    }
    // Literal pins, independent of the generated live manifest. Packaging reads these Entry(hash:) lines.
    static let entries: [Entry] = [
        Entry(hash: "67830fb8fcf452b71bb460562e3bc91a091ee3124a33ce23c558877bc01b2760",
              engineVersion: "@pkmn/sim@0.10.12", adapterVersion: "1", rulesVersion: "gen9-notera-noitems-v1",
              policyVersion: "auto-v2", relayVersion: "relay-v1"),
    ]
    static func entry(for hash: String) -> Entry? { entries.first { $0.hash == hash } }

    /// Hashes choose only fixed names under the app's resources, never a supplied path or remote URL.
    @MainActor static func engine(hash: String, resources: URL? = Bundle.main.resourceURL) throws -> BattleEngine {
        guard entry(for: hash) != nil else { throw OnlineBattleReplay.Failure.unavailableEngine }
        guard let resources else { throw BattleEngine.Failure.missingBundle }
        let archived = resources.appendingPathComponent("battle-engines/\(hash).js")
        // The current engine can be shipped once. Older hashes must have their own immutable resource.
        let current = resources.appendingPathComponent("battle-engine.js")
        let url = hash == BattleEngineManifest.sha256 && FileManager.default.fileExists(atPath: current.path) ? current : archived
        return try BattleEngine(url: url, expectedHash: hash)
    }
}
