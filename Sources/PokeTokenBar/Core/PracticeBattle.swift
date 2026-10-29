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
        var rows: [PracticeCandidate] = []
        func append(_ fallback: String, _ name: String?, _ build: () throws -> BattleSnapshot) {
            do {
                let snapshot = try build()
                rows.append(PracticeCandidate(id: snapshot.instanceID, name: name ?? snapshot.publicInfo.species,
                                              snapshot: snapshot, blockedReason: nil))
            } catch {
                rows.append(PracticeCandidate(id: fallback, name: name ?? "개체", snapshot: nil,
                                              blockedReason: PracticeText.failure(error)))
            }
        }
        if let active = state.active {
            append("blocked-active", activeName) { try BattleSnapshot.from(active, using: engine) }
        }
        for (index, entry) in state.dex.filter({ !$0.isReleased }).enumerated() {
            append("blocked-\(index)", entry.names?[entry.finalID]?["ko"]) {
                try BattleSnapshot.make(speciesID: entry.finalID,
                                        form: PokemonForm.resolved(speciesID: entry.finalID, form: entry.form),
                                        shiny: entry.isShiny, nature: entry.nature, profile: entry.profile, using: engine)
            }
        }
        candidates = rows
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
    /// Typed form of the same log for staging (`PracticePlayback`), plus reveals, timeouts and the end.
    private(set) var events: [PracticeEvent] = []
    private(set) var notice: String?
    private(set) var remainingSeconds = 30
    /// True while `pause()` holds the battle; `tick()` and `choose` do nothing then.
    private(set) var isPaused = false
    var mode: Mode = .manual
    private var battleID: String?
    private var deadline = 0.0
    private var nextAutomaticTurn = 0.0
    private var remainingManual = 0.0
    private var remainingAuto = 0.0
    private var names: [String: String] = [:]
    private var parser = PracticeEventParser()
    private let engine: BattleEngine
    private let clock: () -> TimeInterval
    init(engine: BattleEngine, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.engine = engine; self.clock = clock
    }
    func start(player: PracticeCandidate, opponent: PracticeCandidate, mode: Mode,
               seed: [UInt32] = (0..<4).map { _ in UInt32.random(in: 0...65535) }) {
        release()
        view = nil; result = nil; messages = []; events = []; parser = PracticeEventParser()
        notice = nil; remainingSeconds = 30
        request = BattleRequest(kind: "none", moves: []); self.mode = mode
        do {
            guard let p1 = player.snapshot, let p2 = opponent.snapshot else {
                throw BattleSnapshot.Failure.missingProfile
            }
            guard p1.instanceID != p2.instanceID else {
                throw BattleEngine.Failure.engine("same_individual")
            }
            try p1.validate(using: engine); try p2.validate(using: engine)
            names = ["p1": player.name, "p2": opponent.name]
            let config = BattleConfig(seed: seed, policySeed: seed.reduce(0x505442) { ($0 &* 31) ^ $1 },
                                      p1: .init(name: "p1", set: p1.set), p2: .init(name: "p2", set: p2.set))
            struct Created: Decodable { let id: String }
            let created: Created = try BattleJSON.decode(engine.call(.createBattle, arguments: [BattleJSON.encode(config)]))
            battleID = created.id; phase = .running
            messages = ["연습전을 시작합니다. 성장과 보유 상태는 바뀌지 않습니다."]
            try refresh()
        } catch { fail(error) }
    }
    func choose(slot: Int) {
        guard phase == .running, !isPaused else { return }
        if clock() >= deadline { tick(); return }
        advance(slot: slot)
    }
    func tick() {
        guard phase == .running, !isPaused else { return }
        remainingSeconds = max(0, Int(ceil(deadline - clock())))
        if mode == .automatic {
            if clock() >= nextAutomaticTurn { advance(slot: nil) }
        } else if clock() >= deadline {
            messages.append("시간 초과 · 이번 턴은 자동으로 선택합니다.")
            events.append(.timedOut)
            advance(slot: nil)
        }
    }
    func prepareSelection() {
        release(); phase = .ready; view = nil; result = nil; messages = []; events = []; parser = PracticeEventParser()
        notice = nil
        request = BattleRequest(kind: "none", moves: []); remainingSeconds = 30
    }
    func cancel() {
        release()
        if phase != .finished { phase = .cancelled }
    }
    /// Freezes the manual deadline and the automatic step, keeping the remaining time.
    func pause() {
        guard phase == .running, !isPaused else { return }
        let now = clock()
        remainingManual = max(0, deadline - now); remainingAuto = max(0, nextAutomaticTurn - now)
        remainingSeconds = Int(ceil(remainingManual)); isPaused = true
    }
    /// Restores the deadline as `clock() + remaining`, so reopening never times out instantly.
    func resume() {
        guard isPaused else { return }
        isPaused = false
        guard phase == .running else { return }
        let now = clock()
        deadline = now + remainingManual; nextAutomaticTurn = now + remainingAuto
    }
    private func advance(slot: Int?) {
        guard phase == .running else { return }
        notice = nil
        do {
            if let slot {
                do { try submit("p1", choice: ["type": "move", "slot": slot]) }
                catch BattleEngine.Failure.engine("rejected") {
                    notice = "지금은 사용할 수 없는 기술입니다. 다른 기술을 골라 주세요."
                    try refresh(); return
                }
            } else { try automatic("p1") }
            try automatic("p2")
            try refresh()
        } catch { fail(error) }
    }
    private func submit(_ side: String, choice: [String: Any]) throws {
        guard let battleID else { throw BattleEngine.Failure.engine("unknown_battle") }
        let text = String(decoding: try JSONSerialization.data(withJSONObject: choice), as: UTF8.self)
        _ = try engine.call(.choose, arguments: [BattleJSON.encode(battleID), BattleJSON.encode(side), text])
    }
    private func automatic(_ side: String) throws {
        guard let battleID else { throw BattleEngine.Failure.engine("unknown_battle") }
        let req: BattleRequest = try BattleJSON.decode(engine.call(.request, arguments: [BattleJSON.encode(battleID), BattleJSON.encode(side)]))
        if req.kind == "none" || req.kind == "wait" { return }
        // Imprison can reveal a restriction only on submission; the engine then updates the request.
        for _ in 0..<5 {
            do { try submit(side, choice: ["type": "auto"]); return }
            catch BattleEngine.Failure.engine("rejected") { continue }
        }
        throw BattleEngine.Failure.engine("rejected")
    }
    private func refresh() throws {
        guard let battleID else { throw BattleEngine.Failure.engine("unknown_battle") }
        let id = try BattleJSON.encode(battleID), viewer = try BattleJSON.encode("p1")
        let previousTurn = view?.turn
        view = try BattleJSON.decode(engine.call(.state, arguments: [id, viewer]))
        request = try BattleJSON.decode(engine.call(.request, arguments: [id, viewer]))
        let lines: [String] = try BattleJSON.decode(engine.call(.drainLog, arguments: [id, viewer]))
        messages += lines.compactMap { PracticeText.log($0, names: names) }
        var parsed = parser.parse(lines)
        struct Reveal: Decodable { let kind: String; let side: String; let id: String; let turn: Int }
        let reveals: [Reveal] = try BattleJSON.decode(engine.call(.drainEvents, arguments: [id, viewer]))
        for reveal in reveals where reveal.kind == "ability" {
            messages.append("\(names[reveal.side] ?? reveal.side) · 특성 공개: \(reveal.id)")
            guard let side = PracticeSide(rawValue: reveal.side) else { continue }
            let event = PracticeEvent.abilityRevealed(side, abilityID: reveal.id)
            // A reveal during turn N belongs before the `|turn|N+1` that closes the step; turn 0 is the start.
            if reveal.turn >= 1, case .turn? = parsed.last { parsed.insert(event, at: parsed.count - 1) } else { parsed.append(event) }
        }
        events += parsed
        if view?.ended == true {
            result = try BattleJSON.decode(engine.call(.result, arguments: [id]))
            phase = .finished; remainingSeconds = 0; release()
        } else if previousTurn != view?.turn {
            deadline = clock() + 30; remainingSeconds = 30
            nextAutomaticTurn = clock() + 0.6
        }
    }
    private func release() {
        isPaused = false
        if let battleID { _ = try? engine.call(.destroy, arguments: [BattleJSON.encode(battleID)]) }
        battleID = nil
    }
    private func fail(_ error: Error) {
        release(); phase = .failed; result = nil; notice = PracticeText.failure(error)
    }
}
