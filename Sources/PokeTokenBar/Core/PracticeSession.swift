import Foundation
import Observation

/// Why a practice battle is held. Manual turns wait while any reason is present (the 30 s deadline
/// freezes and resumes with the remaining time); automatic play keeps going in the background and
/// only waits for display sleep and for the turn on screen.
enum PracticePauseReason: Hashable, CaseIterable, Sendable {
    /// The popover closed; its hosting tree is gone (`AppDelegate.popoverDidClose`).
    case popoverClosed
    /// The popover is open but shows another screen (Home, Settings, …).
    case screenHidden
    /// The display slept (`AppDelegate.setDisplayAwake(false)`).
    case displayAsleep
    /// The last engine step is still being staged on screen (`PracticePlayback`). Holds both modes,
    /// so the manual 30 s starts after the turn has played and automatic turns do not overlap.
    case playback
}

/// App-lifetime owner of the local practice battle.
///
/// The popover discards its hosting tree on every close, so view `@State` and `.task` loops cannot hold
/// a battle. The selection, the battle and its driver live here; `AppDelegate` owns one instance and
/// injects it into the popover environment. Read-only like `PracticeBattle`: it never writes the save,
/// growth or ownership.
@MainActor @Observable
final class PracticeSession {
    /// Built by `prepare` from a value copy of the save; nil until then or after `releaseIfIdle`.
    private(set) var roster: PracticeRoster?
    /// Reason the engine or roster could not be prepared, shown inline (the popover has no alerts).
    private(set) var loadError: String?
    /// The current battle; nil on the selection screen.
    private(set) var battle: PracticeBattle?
    /// Stages the current battle's events on screen; created with the battle, dropped with it.
    private(set) var playback: PracticePlayback?
    private(set) var pauseReasons: Set<PracticePauseReason> = []
    /// False from the moment a battle finishes until the result screen reports it was shown.
    private(set) var resultSeen = true
    /// Chosen individuals (`PracticeCandidate.id`). Changing either drops a ready or finished battle.
    var playerID: String? { didSet { if playerID != oldValue { dropIdleBattle(); resetWild() } } }
    var opponentID: String? { didSet { if opponentID != oldValue { dropIdleBattle() } } }
    /// Applies to the next `start()`; while a battle runs it switches that battle immediately.
    var mode: PracticeBattle.Mode = .manual {
        didSet {
            guard mode != oldValue, let battle, battle.phase == .running else { return }
            battle.mode = mode; applyPause()
        }
    }

    private let engineURL: URL?
    private let clock: () -> TimeInterval
    private let drivesAutomatically: Bool
    private var engine: BattleEngine?
    private var driver: Task<Void, Never>?
    /// Bumped on every driver start and stop; a task whose captured value is stale must not tick.
    private var driverGeneration = 0
    /// How many of `battle.events` the playback has been given.
    private var stagedEvents = 0
    private let wildSource: PracticeWildSource
    private let wildSeed: () -> UInt64

    /// Level-matched wild opponents for the current player (`findWildOpponents`); never saved.
    private(set) var wildCandidates: [PracticeCandidate] = []
    private(set) var wildState: PracticeWildState = .idle
    private var wildTask: Task<Void, Never>?
    /// Bumped on every search start and every reset, before the first await; a result whose captured value is
    /// stale (a newer search, or another player) must not land.
    private var wildGeneration = 0

    /// `drivesAutomatically: false` leaves `tick()` to the caller (tests with an injected clock). Tests also
    /// inject `wildSource` stubs and a fixed `wildSeed`, so wild opponents never reach the network there.
    init(engineURL: URL?, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         drivesAutomatically: Bool = true, wildSource: PracticeWildSource = .live,
         wildSeed: @escaping () -> UInt64 = { UInt64.random(in: .min ... .max) }) {
        self.engineURL = engineURL; self.clock = clock; self.drivesAutomatically = drivesAutomatically
        self.wildSource = wildSource; self.wildSeed = wildSeed
    }

    /// Searches three wild opponents within ±3 levels of the current player, replacing the previous ones
    /// with a new seed; a search in flight is cancelled. `opponentID` may then name a wild candidate, and
    /// `opponent` resolves it. Changing the player drops them (`wildState = .idle`) because their levels
    /// were matched to the old one. Needs a prepared engine; results land on the main actor.
    func findWildOpponents() {
        guard let engine, let level = player?.snapshot?.set.level else { return }
        wildTask?.cancel()
        wildGeneration &+= 1
        let generation = wildGeneration
        wildState = .searching
        let generator = PracticeWildGenerator(source: wildSource, engine: engine)
        let seed = wildSeed()
        wildTask = Task { [weak self] in
            let result: Result<[PracticeCandidate], Error>
            do { result = .success(try await generator.make(count: 3, around: level, seed: seed)) }
            catch { result = .failure(error) }
            guard let self, !Task.isCancelled, self.wildGeneration == generation else { return }
            self.finishWildSearch(result)
        }
    }
    private func finishWildSearch(_ result: Result<[PracticeCandidate], Error>) {
        wildTask = nil
        let opponentWasWild = wildCandidates.contains { $0.id == opponentID }
        switch result {
        case .success(let made):
            wildCandidates = made; wildState = .ready
        case .failure:
            wildCandidates = []; wildState = .unavailable(PracticeText.wildUnavailable)
        }
        // A wild opponent of the replaced batch no longer exists.
        if opponentWasWild, !wildCandidates.contains(where: { $0.id == opponentID }) { opponentID = defaultOpponentID() }
    }
    /// Wild opponents were matched to the player's level: another player (or none) drops them, cancels a search
    /// in flight, and moves a wild opponent selection back to an own individual.
    private func resetWild() {
        wildTask?.cancel(); wildTask = nil; wildGeneration &+= 1
        let opponentWasWild = wildCandidates.contains { $0.id == opponentID }
        wildCandidates = []; wildState = .idle
        if opponentWasWild { opponentID = defaultOpponentID() }
    }
    private func defaultOpponentID() -> String? { roster?.eligible.first { $0.id != playerID }?.id }

    var player: PracticeCandidate? { candidate(playerID) }
    var opponent: PracticeCandidate? { candidate(opponentID) }
    /// A running battle or an unseen result: the popover reopens on the practice screen.
    var isActive: Bool { battle?.phase == .running || (battle?.phase == .finished && !resultSeen) }
    /// Menu bar suffix for the current state (`PracticeStatusBadge`).
    var statusBadge: String? { PracticeStatusBadge.text(phase: battle?.phase, resultSeen: resultSeen) }

    /// Loaded with the engine in `prepare` (`typeChart`); nil until then or when the engine failed.
    private(set) var typeChart: PracticeTypeChart?
    /// Public data of the roster's moves keyed by Showdown id (`describeMoves`), filled in `prepare`.
    private(set) var moveInfo: [String: PracticeMoveInfo] = [:]
    /// Staging speed for turns; a change applies to the beat on screen at once (`PracticePlayback.timeScale`),
    /// and `instant` skips staging like a hidden screen does.
    var playbackSpeed: PracticePlaybackSpeed = .normal {
        didSet {
            guard playbackSpeed != oldValue else { return }
            playback?.timeScale = playbackSpeed.timeScale
            skipPlaybackIfHidden(); refreshHold()
        }
    }
    /// Pairing summary for the current selection from public information only; nil without both sides
    /// or a type chart.
    var matchup: PracticeMatchup? {
        guard let chart = typeChart, let player = player?.snapshot, let opponent = opponent?.snapshot else { return nil }
        let opponentTypes = opponent.publicInfo.types
        // `effectiveness` is nil for variable-type moves (real type unknown), which then count as neutral.
        let offense: [(id: String, multiplier: Double)] = player.set.moves.compactMap { slug in
            guard let info = moveInfo[Self.showdownID(slug)], !info.isStatus else { return nil }
            return (info.id, chart.effectiveness(of: info, against: opponentTypes) ?? 1)
        }
        let best = offense.map(\.multiplier).max() ?? 0
        let threat = opponentTypes.compactMap { chart.multiplier(attack: $0, defenders: player.publicInfo.types) }.max() ?? 1
        let playerSpeed = player.publicInfo.stats["spe"] ?? 0, opponentSpeed = opponent.publicInfo.stats["spe"] ?? 0
        return PracticeMatchup(
            bestOffense: best, bestMoveIDs: best != 1 && !offense.isEmpty ? offense.filter { $0.multiplier == best }.map(\.id) : [],
            threat: threat,
            order: playerSpeed > opponentSpeed ? .playerFirst : playerSpeed < opponentSpeed ? .opponentFirst : .speedTie,
            playerSpeed: playerSpeed, opponentSpeed: opponentSpeed,
            levelGap: opponent.publicInfo.level - player.publicInfo.level)
    }
    /// Card hint for one of the player's moves in the running battle, against the opponent's current
    /// public types (`battle.view`); nil for unknown moves such as recharge or Struggle.
    func moveHint(_ moveID: String) -> PracticeMoveHint? {
        guard let info = moveInfo[moveID] else { return nil }
        let multiplier = battle?.view.flatMap { view in typeChart?.effectiveness(of: info, against: view.p2.types) }
        // Fixed damage has no STAB, and a variable-type move's real type is hidden.
        let stab = !info.fixedDamage && !info.variableType && battle?.view?.p1.types.contains(info.type) == true
        return PracticeMoveHint(info: info, multiplier: multiplier, stab: stab)
    }
    /// Automatic battles only: plays the rest of the battle at once without staging, so the result shows
    /// next. The playback still receives every event (summary and log stay complete).
    func skipToResult() {
        guard let battle, battle.phase == .running, battle.mode == .automatic else { return }
        // Beats already queued come first, so the history keeps its order.
        playback?.skipToEnd()
        step { $0.runToEnd() }
        playback?.skipToEnd()
        refreshHold()
    }

    /// Creates the engine once and rebuilds the roster from `state`. Keeps a still-eligible selection,
    /// otherwise defaults to the first eligible candidate (player) and the next one (opponent). Leaves a
    /// running battle untouched. Failures land in `loadError`.
    func prepare(state: CompanionState, activeName: String?) {
        guard battle?.phase != .running else { return }
        let engine: BattleEngine
        do { engine = try self.engine ?? BattleEngine(url: engineURL) }
        catch { loadError = PracticeText.failure(error); roster = nil; return }
        self.engine = engine; loadError = nil
        let roster = PracticeRoster(state: state, activeName: activeName, engine: engine)
        self.roster = roster
        loadHints(engine: engine, roster: roster)
        let ids = roster.eligible.map(\.id)
        let player = playerID.flatMap { ids.contains($0) ? $0 : nil } ?? ids.first
        // A wild opponent stays selected only while the player it was matched to does.
        let wildKept = player == playerID
        let opponent = opponentID.flatMap { id in
            (ids.contains(id) && id != player) || (wildKept && wildCandidates.contains { $0.id == id }) ? id : nil
        } ?? ids.first { $0 != player }
        playerID = player; opponentID = opponent
    }
    /// Starts a battle with the current selection and mode; a rematch is the same call.
    func start() {
        guard let engine, let player, let opponent, player.id != opponent.id else { return }
        stopDriver(); battle?.cancel(); dropPlayback()
        let next = PracticeBattle(engine: engine, clock: clock)
        battle = next
        next.start(player: player, opponent: opponent, mode: mode)
        let staging = PracticePlayback(clock: clock)
        staging.timeScale = playbackSpeed.timeScale
        playback = staging
        stageEvents()
        resultSeen = true
        refreshHold()
    }
    /// Manual move choice for the player; ignored while paused or in automatic mode.
    func choose(slot: Int) {
        guard let battle, battle.phase == .running, battle.mode == .manual, !battle.isPaused else { return }
        step { $0.choose(slot: slot) }
        refreshHold()
    }
    /// Gives up the running battle and returns to the selection screen.
    func forfeit() {
        stopDriver(); battle?.cancel(); battle = nil; dropPlayback(); resultSeen = true
    }
    /// Leaves a finished battle for the selection screen (to pick another opponent).
    func backToSelection() {
        guard battle?.phase != .running else { return }
        battle = nil; dropPlayback(); resultSeen = true
    }
    /// The result screen calls this when it is shown.
    func markResultSeen() { resultSeen = true }
    /// Adds or removes a pause reason, then holds or resumes the battle per `PracticePauseReason`.
    func setPaused(_ paused: Bool, reason: PracticePauseReason) {
        if paused { pauseReasons.insert(reason) } else { pauseReasons.remove(reason) }
        if paused { skipPlaybackIfHidden() }
        refreshHold()
    }
    /// Advances the playback, then the deadlines and automatic turns, at `clock()`. The internal driver
    /// calls it while a battle runs or beats play; with `drivesAutomatically: false` the caller does.
    func tick() {
        guard battle != nil else { return }
        playback?.advance(); refreshHold()
        if !isHeld { step { $0.tick() } }
        refreshHold()
    }
    /// Drops the engine and roster when no battle is active (popover closed, practice screen left).
    func releaseIfIdle() {
        guard !isActive else { return }
        stopDriver(); battle?.cancel(); battle = nil; dropPlayback(); resultSeen = true
        roster = nil; engine = nil; typeChart = nil; moveInfo = [:]
        // The engine goes, so a search in flight stops; finished wild snapshots are plain data and stay.
        if wildState == .searching {
            wildTask?.cancel(); wildTask = nil; wildGeneration &+= 1
            wildState = wildCandidates.isEmpty ? .idle : .ready
        }
    }

    /// Loads the type chart once per engine and the public data of every roster move. A failure keeps
    /// what is already loaded and the hints simply stay out; it never blocks the practice screen.
    private func loadHints(engine: BattleEngine, roster: PracticeRoster) {
        if typeChart == nil, let text = try? engine.call(.typeChart) {
            typeChart = try? BattleJSON.decode(text)
        }
        struct Described: Decodable { let moves: [PracticeMoveInfo] }
        for candidate in roster.eligible {
            guard let moves = candidate.snapshot?.set.moves,
                  !moves.allSatisfy({ moveInfo[Self.showdownID($0)] != nil }),
                  let arguments = try? BattleJSON.encode(moves),
                  let text = try? engine.call(.describeMoves, arguments: [arguments]),
                  let described: Described = try? BattleJSON.decode(text) else { continue }
            // Aliases ("vice-grip" -> "visegrip") are looked up by the saved slug, battles by the canonical id.
            for (slug, info) in zip(moves, described.moves) {
                moveInfo[info.id] = info; moveInfo[Self.showdownID(slug)] = info
            }
        }
    }
    /// Showdown's id for a move slug or name: lowercase letters and digits only ("volt-tackle" -> "volttackle").
    private static func showdownID(_ text: String) -> String {
        String(text.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) })
    }
    private func candidate(_ id: String?) -> PracticeCandidate? {
        guard let id else { return nil }
        return roster?.eligible.first { $0.id == id } ?? wildCandidates.first { $0.id == id }
    }
    /// A ready, finished, failed or cancelled battle belongs to the old selection; a running one is never dropped.
    private func dropIdleBattle() {
        guard let battle, battle.phase != .running else { return }
        self.battle = nil; dropPlayback(); resultSeen = true
    }
    /// Manual turns wait on any reason; automatic play only on display sleep and while a turn plays.
    private var isHeld: Bool {
        battle?.mode == .automatic
            ? !pauseReasons.isDisjoint(with: [.displayAsleep, .playback]) : !pauseReasons.isEmpty
    }
    private func applyPause() {
        if let battle, battle.phase == .running { if isHeld { battle.pause() } else { battle.resume() } }
        syncDriver()
    }
    /// Runs one engine step of a running battle, stages what it produced and detects its end.
    private func step(_ body: (PracticeBattle) -> Void) {
        guard let battle, battle.phase == .running else { return }
        body(battle)
        stageEvents()
        if battle.phase == .finished { resultSeen = false }
    }
    /// Hands the playback the events the engine added since the last call. A hidden screen plays nothing.
    private func stageEvents() {
        guard let battle, let playback else { return }
        if stagedEvents > battle.events.count { stagedEvents = 0 }
        let fresh = Array(battle.events[stagedEvents...])
        stagedEvents = battle.events.count
        if !fresh.isEmpty { playback.enqueue(fresh) }
        skipPlaybackIfHidden()
    }
    /// Nobody watches a hidden screen, and `instant` asks for no staging: both play every beat at once.
    private func skipPlaybackIfHidden() {
        if playbackSpeed == .instant || !pauseReasons.isDisjoint(with: [.popoverClosed, .screenHidden]) {
            playback?.skipToEnd()
        }
    }
    /// Holds the battle while beats play and lets go when they are done, then re-applies the pause.
    private func refreshHold() {
        let playing = playback?.isPlaying == true
        if playing != pauseReasons.contains(.playback) {
            if playing { pauseReasons.insert(.playback) } else { pauseReasons.remove(.playback) }
        }
        applyPause()
    }
    private func dropPlayback() {
        playback = nil; stagedEvents = 0; pauseReasons.remove(.playback)
    }
    /// The driver runs while the battle can advance or beats are on screen; idle it stops.
    private func syncDriver() {
        let battleRuns = battle?.phase == .running && !isHeld
        let shouldDrive = drivesAutomatically && (battleRuns || playback?.isPlaying == true)
        if shouldDrive { if driver == nil { startDriver() } } else { stopDriver() }
    }
    private func startDriver() {
        driverGeneration &+= 1
        let generation = driverGeneration
        driver = Task { [weak self] in
            while !Task.isCancelled {
                let beatsPlaying = self?.playback?.isPlaying == true
                try? await Task.sleep(for: .milliseconds(beatsPlaying ? 100 : 250))
                guard let self, !Task.isCancelled, self.driverGeneration == generation else { return }
                self.tick()
            }
        }
    }
    private func stopDriver() {
        driverGeneration &+= 1
        driver?.cancel(); driver = nil
    }
}

/// One-glyph menu bar suffix: a running battle shows "⚔︎", a finished and unseen one "⚑", otherwise nil.
enum PracticeStatusBadge {
    static func text(phase: PracticeBattle.Phase?, resultSeen: Bool) -> String? {
        switch phase {
        case .running: return "\u{2694}\u{FE0E}"
        case .finished: return resultSeen ? nil : "\u{2691}"
        case .ready, .failed, .cancelled, nil: return nil
        }
    }
}
