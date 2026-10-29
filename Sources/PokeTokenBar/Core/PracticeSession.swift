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
    var playerID: String? { didSet { if playerID != oldValue { dropIdleBattle() } } }
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

    /// `drivesAutomatically: false` leaves `tick()` to the caller (tests with an injected clock).
    init(engineURL: URL?, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         drivesAutomatically: Bool = true) {
        self.engineURL = engineURL; self.clock = clock; self.drivesAutomatically = drivesAutomatically
    }

    var player: PracticeCandidate? { candidate(playerID) }
    var opponent: PracticeCandidate? { candidate(opponentID) }
    /// A running battle or an unseen result: the popover reopens on the practice screen.
    var isActive: Bool { battle?.phase == .running || (battle?.phase == .finished && !resultSeen) }
    /// Menu bar suffix for the current state (`PracticeStatusBadge`).
    var statusBadge: String? { PracticeStatusBadge.text(phase: battle?.phase, resultSeen: resultSeen) }

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
        let ids = roster.eligible.map(\.id)
        let player = playerID.flatMap { ids.contains($0) ? $0 : nil } ?? ids.first
        let opponent = opponentID.flatMap { ids.contains($0) && $0 != player ? $0 : nil } ?? ids.first { $0 != player }
        playerID = player; opponentID = opponent
    }
    /// Starts a battle with the current selection and mode; a rematch is the same call.
    func start() {
        guard let engine, let player, let opponent, player.id != opponent.id else { return }
        stopDriver(); battle?.cancel(); dropPlayback()
        let next = PracticeBattle(engine: engine, clock: clock)
        battle = next
        next.start(player: player, opponent: opponent, mode: mode)
        playback = PracticePlayback(clock: clock)
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
        roster = nil; engine = nil
    }

    private func candidate(_ id: String?) -> PracticeCandidate? {
        guard let id else { return nil }
        return roster?.eligible.first { $0.id == id }
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
    private func skipPlaybackIfHidden() {
        if !pauseReasons.isDisjoint(with: [.popoverClosed, .screenHidden]) { playback?.skipToEnd() }
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
