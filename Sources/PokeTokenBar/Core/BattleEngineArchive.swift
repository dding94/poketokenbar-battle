import Foundation

/// Only locally shipped, explicitly pinned code may replay historical input.
enum BattleEngineArchive {
    struct Entry: Equatable {
        let hash: String
        let engineVersion: String
        let adapterVersion: String
        let rulesVersion: String
        let policyVersion: String
        let relayVersion: String
    }
    static let entries: [Entry] = []
    static func entry(for hash: String) -> Entry? { entries.first { $0.hash == hash } }
    @MainActor static func engine(hash: String, resources: URL? = Bundle.main.resourceURL) throws -> BattleEngine {
        throw OnlineBattleReplay.Failure.unavailableEngine
    }
}
