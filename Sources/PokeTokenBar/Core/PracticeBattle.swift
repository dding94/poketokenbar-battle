import Foundation
import Observation

struct PracticeCandidate: Identifiable {
    let id: String
    let name: String
    let snapshot: BattleSnapshot?
    let blockedReason: String?
}
struct PracticeRoster {
    let candidates: [PracticeCandidate]
    var eligible: [PracticeCandidate] { candidates.filter { $0.snapshot != nil } }
    @MainActor init(state: CompanionState, activeName: String? = nil, engine: BattleEngine) {
        candidates = []
    }
}
struct BattleMove: Decodable, Identifiable {
    let slot: Int
    let id: String
    let name: String
    let type: String
    let pp: Int
    let maxpp: Int
    let disabled: Bool
}
struct BattleRequest: Decodable {
    let kind: String
    let moves: [BattleMove]
}
struct BattleView: Decodable {
    struct Pokemon: Decodable {
        let speciesNum: Int
        let species: String
        let level: Int
        let types: [String]
        let hp: Int
        let maxhp: Int
        let status: String
        let moves: [String]
        let ability: String?
    }
    let turn: Int
    let ended: Bool
    let p1: Pokemon
    let p2: Pokemon
}
struct BattleConfig: Codable {
    struct Player: Codable { let name: String; let set: BattleSet }
    let seed: [UInt32]
    let policySeed: UInt32
    let p1: Player
    let p2: Player
}
struct BattleInputLog: Codable {
    struct Choice: Codable { let type: String; let slot: Int }
    struct Token: Codable { let side: String; let choice: Choice }
    let version: Int
    let policyVersion: String
    let config: BattleConfig
    let choices: [Token]
}
struct BattleResult: Decodable {
    let ended: Bool
    let winner: String?
    let turns: Int
    let logHash: String
    let inputLog: BattleInputLog
}

/// Owns only immutable snapshots and an isolated engine; no store or persistence dependency.
@MainActor @Observable
final class PracticeBattle {
    enum Mode: String, CaseIterable { case manual, automatic }
    enum Phase: Equatable { case ready, running, finished, failed, cancelled }
    private(set) var phase: Phase = .ready
    private(set) var view: BattleView?
    private(set) var request = BattleRequest(kind: "none", moves: [])
    private(set) var result: BattleResult?
    private(set) var messages: [String] = []
    private(set) var notice: String?
    private(set) var remainingSeconds = 30
    var mode: Mode = .manual
    private let engine: BattleEngine
    private let clock: () -> TimeInterval
    init(engine: BattleEngine, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.engine = engine; self.clock = clock
    }
    func start(player: PracticeCandidate, opponent: PracticeCandidate, mode: Mode,
               seed: [UInt32] = (0..<4).map { _ in UInt32.random(in: 0...65535) }) {
        phase = .failed; notice = "아직 구현하지 않았습니다."
    }
    func choose(slot: Int) {}
    func tick() {}
    func cancel() {}
}
