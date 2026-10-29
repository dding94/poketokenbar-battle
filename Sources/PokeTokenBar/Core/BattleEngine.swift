import Foundation

/// Owns one synchronous JavaScriptCore engine on the main actor.
@MainActor
final class BattleEngine {
    enum Failure: Error, Equatable { case missingBundle, checksumMismatch, invalidBundle, engine(String) }
    enum Method: String { case version, createBattle, request, choose, autoChoice, state, drainLog, result, replay, destroy }
    init(url: URL?, expectedHash: String) throws { throw Failure.invalidBundle }
    func call(_ method: Method, arguments: [String] = []) throws -> String { throw Failure.invalidBundle }
}
