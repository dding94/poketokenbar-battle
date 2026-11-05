import CryptoKit
import Foundation

/// Owns one isolated deterministic engine. No server text is ever passed to the simulator.
@MainActor
final class OnlineBattleResolver {
    enum Failure: Error, Equatable {
        case invalidConfiguration, needsRefetch, invalidJournal, resolutionFailed, resultMismatch
    }
    /// Only this file can create proof that a completed server result matches a local full replay.
    struct VerifiedCompletion {
        let battleID: String
        let resultHash: String
        let localInstanceID: String
        let remainingHPShare: Double
        let winner: OnlineBattleWinner
        let localSide: OnlineBattleSide
        fileprivate init(battleID: String, resultHash: String, localInstanceID: String,
                         remainingHPShare: Double, winner: OnlineBattleWinner, localSide: OnlineBattleSide) {
            self.battleID = battleID; self.resultHash = resultHash; self.localInstanceID = localInstanceID
            self.remainingHPShare = remainingHPShare; self.winner = winner; self.localSide = localSide
        }
    }
    let localSide: OnlineBattleSide
    private(set) var view: BattleView?
    private(set) var request = BattleRequest(kind: "none", moves: [])
    private(set) var result: BattleResult?
    private(set) var logs: [String] = []
    /// For the display only: `logs.count` after the opening and after each round, so
    /// `roundLogEnds.count == journal.count + 1`. Segment 0 is the opening.
    private(set) var roundLogEnds: [Int] = []
    /// The reveals of each `roundLogEnds` segment. Empty for a completed proof, which has nothing to stage.
    private(set) var roundReveals: [[BattleLogReveal]] = []
    private let capturesReveals: Bool
    private(set) var journal: [OnlineBattlePair] = []
    /// For the display only: what my request was when each journal round opened. A "timeout" on a forced round says nothing.
    private(set) var roundOpeningKinds: [String] = []
    var processedRoundSeq: Int { journal.count }
    private let initial: OnlineBattleView
    private let config: OnlineBattleConfig
    private let engine: BattleEngine
    private var engineID: String?
    private var invalidated = false
    /// Loaded on the first `moveHints()` and kept, whether or not it succeeded.
    private var hintData: HintData?

    /// Live matches continue to require the current engine; archived pins never broaden this entry point.
    convenience init(battle: OnlineBattleView, localTrainerID: String, engine: BattleEngine) throws {
        guard battle.config?.engineHash == BattleEngineManifest.sha256,
              let entry = BattleEngineArchive.entry(for: BattleEngineManifest.sha256) else { throw Failure.invalidConfiguration }
        try self.init(battle: battle, localTrainerID: localTrainerID, engine: engine, entry: entry, capturesReveals: true)
    }

    /// Completed-only verification for replay or normal reconciliation. Live matches keep the strict initializer.
    static func completedResolver(battle: OnlineBattleView, localTrainerID: String, engine: BattleEngine) throws -> OnlineBattleResolver {
        guard battle.state == .completed, let hash = battle.config?.engineHash,
              let entry = BattleEngineArchive.entry(for: hash) else { throw Failure.invalidConfiguration }
        return try OnlineBattleResolver(battle: battle, localTrainerID: localTrainerID, engine: engine, entry: entry, capturesReveals: false)
    }

    private init(battle: OnlineBattleView, localTrainerID: String, engine: BattleEngine,
                 entry: BattleEngineArchive.Entry, capturesReveals: Bool) throws {
        guard let localSide = battle.side(for: localTrainerID), battle.p1.trainerId != battle.p2.trainerId,
              !battle.battleId.isEmpty, let config = battle.config,
              [.ready, .running, .reported, .completed].contains(battle.state),
              !config.readyToken.isEmpty, entry.accepts(config), engine.verifiedHash == entry.hash,
              config.seed.count == 4, config.seed.allSatisfy({ $0 <= 65535 }) else {
            throw Failure.invalidConfiguration
        }
        self.initial = battle; self.config = config; self.localSide = localSide; self.engine = engine
        self.capturesReveals = capturesReveals
        struct Version: Decodable { let engine: String; let adapter: String; let rules: String }
        let version: Version = try BattleJSON.decode(engine.call(.version))
        guard version.engine == entry.engineVersion, version.adapter == entry.adapterVersion, version.rules == entry.rulesVersion else {
            throw Failure.invalidConfiguration
        }
        for (name, player, supplied) in [("p1", config.p1, battle.p1.snapshot), ("p2", config.p2, battle.p2.snapshot)] {
            guard let supplied, !supplied.instanceId.isEmpty, player.name == name, player.policy == "standard",
                  player.set == supplied.set, player.hp == supplied.hp else { throw Failure.invalidConfiguration }
            let actual: BattlePublicInfo = try BattleJSON.decode(engine.call(.describeSet, arguments: [BattleJSON.encode(player.set)]))
            guard actual == supplied.publicInfo, let maxHP = actual.stats["hp"], (1...maxHP).contains(player.hp) else {
                throw Failure.invalidConfiguration
            }
        }
        struct Created: Decodable { let id: String }
        // Frozen metadata must never leak into the engine's closed configuration schema.
        let created: Created = try BattleJSON.decode(engine.call(.createBattle, arguments: [BattleJSON.encode(config.engineConfig)]))
        engineID = created.id
        do { try refresh() } catch { close(); throw error }
    }

    /// Receives the complete journal from GET. Duplicate prefixes are no-ops; a changed/missing prefix poisons
    /// this instance so no partially applied pair can be reused. The session must GET and construct a fresh owner.
    func consume(journal incoming: [OnlineBattlePair]) throws {
        guard !invalidated, engineID != nil else { throw Failure.needsRefetch }
        do {
            guard incoming.count >= journal.count, Array(incoming.prefix(journal.count)) == journal else {
                throw Failure.needsRefetch
            }
            guard incoming.count <= 200 else { throw Failure.invalidJournal }
            for (index, pair) in incoming.enumerated() {
                guard pair.roundSeq == index + 1 else { throw Failure.needsRefetch }
                for token in [pair.p1, pair.p2] {
                    if case .move(let slot) = token, !(1...4).contains(slot) { throw Failure.invalidJournal }
                    if initial.mode == .auto, token != .policy { throw Failure.invalidJournal }
                    if initial.mode == .manual, token == .policy { throw Failure.invalidJournal }
                }
            }
            for pair in incoming.dropFirst(journal.count) {
                guard result?.ended != true else { throw Failure.invalidJournal }
                roundOpeningKinds.append(request.kind)
                try apply(pair.p1, side: .p1)
                try apply(pair.p2, side: .p2)
                journal.append(pair)
                try refresh()
            }
        } catch {
            close()
            throw error
        }
    }

    func terminalReport() throws -> OnlineBattleReport? {
        guard !invalidated, engineID != nil else { throw Failure.needsRefetch }
        guard let result, result.ended else { return nil }
        guard !journal.isEmpty, let winner = OnlineBattleWinner(rawValue: result.winner ?? "draw") else {
            throw Failure.resolutionFailed
        }
        // Opponent HP in a view is a percentage. Query each owner's view separately for exact integer HP.
        let p1 = try state(.p1).p1, p2 = try state(.p2).p2
        guard p1.hp >= 0, p1.hp <= p1.maxhp, p2.hp >= 0, p2.hp <= p2.maxhp else { throw Failure.resolutionFailed }
        return OnlineBattleReport(readyToken: config.readyToken, engineHash: config.engineHash,
                                  terminalSeq: processedRoundSeq, winner: winner, logHash: result.logHash,
                                  journalHash: Self.hash(try Self.journalBytes(battleID: initial.battleId, readyToken: config.readyToken, journal: journal)),
                                  finalHp: .init(p1: p1.hp, p2: p2.hp))
    }

    func verifyCompleted(_ battle: OnlineBattleView) throws -> VerifiedCompletion {
        guard battle.state == .completed, battle.battleId == initial.battleId, battle.config == config,
              battle.mode == initial.mode, battle.revision == initial.revision,
              battle.p1 == initial.p1, battle.p2 == initial.p2 else { throw Failure.resultMismatch }
        try consume(journal: battle.journal)
        guard let report = try terminalReport(), report == battle.result, report.terminalSeq == battle.roundSeq else {
            throw Failure.resultMismatch
        }
        let own = localSide == .p1 ? battle.p1.snapshot! : battle.p2.snapshot!
        let hp = localSide == .p1 ? report.finalHp.p1 : report.finalHp.p2
        return VerifiedCompletion(battleID: battle.battleId, resultHash: Self.hash(try BattleJSON.encode(report)),
                                  localInstanceID: own.instanceId, remainingHPShare: Double(hp) / Double(own.publicInfo.stats["hp"]!),
                                  winner: report.winner, localSide: localSide)
    }

    // MARK: Move hints

    /// What a move card needs to hint at a choice: the engine's type chart and the public data of my own moves.
    struct HintData: Equatable {
        var chart: PracticeTypeChart?
        /// Keyed by the engine's move id, which is what a request lists.
        var moves: [String: PracticeMoveInfo] = [:]
    }

    /// Both calls are pure lookups (no battle state, no RNG). A failure leaves that part empty and never throws:
    /// the hints simply stay out and the battle goes on, as on the practice screen.
    static func loadHintData(engine: BattleEngine, ownMoves: [String]) -> HintData {
        var data = HintData()
        if let text = try? engine.call(.typeChart) { data.chart = try? BattleJSON.decode(text) }
        struct Described: Decodable { let moves: [PracticeMoveInfo] }
        if !ownMoves.isEmpty, let arguments = try? BattleJSON.encode(ownMoves),
           let text = try? engine.call(.describeMoves, arguments: [arguments]),
           let described: Described = try? BattleJSON.decode(text) {
            for info in described.moves { data.moves[info.id] = info }
        }
        return data
    }

    /// Moves whose real effectiveness is not the plain type chart (Freeze-Dry is super effective on Water, Flying
    /// Press adds Flying, Thousand Arrows hits Flying types). Their card shows power and accuracy, no matchup.
    private static let chartBreakingMoves: Set<String> = ["freezedry", "flyingpress", "thousandarrows"]

    /// Card hints for the moves of my current move request, by slot. They use only what a player may know: my own
    /// set (the data of my own four moves), my own and the foe's current types from the engine's view, and the
    /// engine's chart. The foe's set, ability and choice are never read. Empty for any other kind of request, so a
    /// forced Struggle or Recharge has none, and for a closed resolver.
    func moveHints() -> [Int: PracticeMoveHint] {
        guard !invalidated, engineID != nil, request.kind == "move", let view else { return [:] }
        let data = hintData ?? Self.loadHintData(engine: engine, ownMoves: (localSide == .p1 ? config.p1 : config.p2).set.moves)
        hintData = data
        let own = localSide == .p1 ? view.p1 : view.p2, foe = localSide == .p1 ? view.p2 : view.p1
        var hints: [Int: PracticeMoveHint] = [:]
        for move in request.moves {
            guard let info = data.moves[move.id] else { continue }
            let chart = Self.chartBreakingMoves.contains(info.id) ? nil : data.chart
            // STAB is a damage bonus, so a status move never shows it (the practice board still does, unchanged).
            hints[move.slot] = PracticeMoveHint(info: info, chart: chart, attackerTypes: info.isStatus ? nil : own.types,
                                                defenderTypes: foe.types)
        }
        return hints
    }

    /// Explicitly release on navigation/session replacement. No further reports can be produced afterwards.
    func close() {
        if let engineID { _ = try? engine.call(.destroy, arguments: [BattleJSON.encode(engineID)]) }
        engineID = nil; invalidated = true
    }

    /// Exact Appendix D arrays, encoded without slash escaping just like JSON.stringify. Timestamps are excluded.
    static func journalBytes(battleID: String, readyToken: String, journal: [OnlineBattlePair]) throws -> String {
        func token(_ token: OnlineBattleRelayToken) -> [Any] {
            switch token {
            case .move(let slot): return ["move", slot]
            case .timeout: return ["timeout"]
            case .policy: return ["policy"]
            }
        }
        let rows: [[Any]] = journal.map { [$0.roundSeq, token($0.p1), token($0.p2)] }
        let data = try JSONSerialization.data(withJSONObject: ["relay-v1", battleID, readyToken, rows], options: [.withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    private func apply(_ token: OnlineBattleRelayToken, side: OnlineBattleSide) throws {
        var request = try engineRequest(side)
        if request.kind == "wait" || request.kind == "none" { return }
        guard request.kind == "move" || request.kind == "forced" else { throw Failure.resolutionFailed }
        if request.kind != "forced", case .move(let slot) = token {
            do { try choose(slot, side: side); return }
            catch BattleEngine.Failure.engine("rejected") { request = try engineRequest(side) }
        }
        // Hidden Imprison updates the request only after rejection. Retry from the refreshed request/policy;
        // five attempts cover the four move slots and the engine's forced Struggle/recharge action.
        for _ in 0..<5 {
            guard request.kind == "move" || request.kind == "forced" else { throw Failure.resolutionFailed }
            do {
                struct Pick: Decodable { let slot: Int }
                let pick: Pick = try BattleJSON.decode(call(.autoChoice, side: side))
                try choose(pick.slot, side: side)
                return
            } catch BattleEngine.Failure.engine("rejected") {
                request = try engineRequest(side)
            }
        }
        throw Failure.resolutionFailed
    }
    private func choose(_ slot: Int, side: OnlineBattleSide) throws {
        guard (1...4).contains(slot) else { throw Failure.invalidJournal }
        struct Choice: Encodable { let type = "move"; let slot: Int }
        _ = try call(.choose, side: side, extra: [BattleJSON.encode(Choice(slot: slot))])
    }
    private func engineRequest(_ side: OnlineBattleSide) throws -> BattleRequest { try BattleJSON.decode(call(.request, side: side)) }
    private func state(_ side: OnlineBattleSide) throws -> BattleView { try BattleJSON.decode(call(.state, side: side)) }
    private func refresh() throws {
        view = try state(localSide)
        request = try engineRequest(localSide)
        result = try BattleJSON.decode(call(.result))
        let fresh: [String] = try BattleJSON.decode(call(.drainLog, side: localSide))
        logs += fresh
        roundLogEnds.append(logs.count)
        // Reveals use their own cursor and never touch the battle log, so the log hash cannot see this. It is
        // display data: if it ever failed, the round must still count.
        var reveals: [BattleLogReveal] = []
        if capturesReveals {
            do { reveals = try BattleJSON.decode(call(.drainEvents, side: localSide)) } catch { reveals = [] }
        }
        roundReveals.append(reveals)
    }
    private func call(_ method: BattleEngine.Method, side: OnlineBattleSide? = nil, extra: [String] = []) throws -> String {
        guard let engineID else { throw Failure.needsRefetch }
        var arguments = [try BattleJSON.encode(engineID)]
        if let side { arguments.append(try BattleJSON.encode(side.rawValue)) }
        return try engine.call(method, arguments: arguments + extra)
    }
    private static func hash(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
