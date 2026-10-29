import Foundation
import Observation

/// Why a practice battle is held. Manual turns wait while any reason is present (the 30 s deadline
/// freezes and resumes with the remaining time); automatic play keeps going in the background and
/// only waits for display sleep.
enum PracticePauseReason: Hashable, CaseIterable, Sendable {
    /// The popover closed; its hosting tree is gone (`AppDelegate.popoverDidClose`).
    case popoverClosed
    /// The popover is open but shows another screen (Home, Settings, …).
    case screenHidden
    /// The display slept (`AppDelegate.setDisplayAwake(false)`).
    case displayAsleep
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
        stopDriver(); battle?.cancel()
        let next = PracticeBattle(engine: engine, clock: clock)
        battle = next
        next.start(player: player, opponent: opponent, mode: mode)
        resultSeen = true
        applyPause()
    }
    /// Manual move choice for the player; ignored while paused or in automatic mode.
    func choose(slot: Int) {
        guard let battle, battle.phase == .running, battle.mode == .manual, !battle.isPaused else { return }
        battle.choose(slot: slot); afterStep()
    }
    /// Gives up the running battle and returns to the selection screen.
    func forfeit() {
        stopDriver(); battle?.cancel(); battle = nil; resultSeen = true
    }
    /// Leaves a finished battle for the selection screen (to pick another opponent).
    func backToSelection() {
        guard battle?.phase != .running else { return }
        battle = nil; resultSeen = true
    }
    /// The result screen calls this when it is shown.
    func markResultSeen() { resultSeen = true }
    /// Adds or removes a pause reason, then holds or resumes the battle per `PracticePauseReason`.
    func setPaused(_ paused: Bool, reason: PracticePauseReason) {
        if paused { pauseReasons.insert(reason) } else { pauseReasons.remove(reason) }
        applyPause()
    }
    /// Advances deadlines and automatic turns at `clock()`. The internal driver calls it while a battle
    /// runs; with `drivesAutomatically: false` the caller does.
    func tick() {
        guard let battle, battle.phase == .running else { return }
        battle.tick(); afterStep()
    }
    /// Drops the engine and roster when no battle is active (popover closed, practice screen left).
    func releaseIfIdle() {
        guard !isActive else { return }
        stopDriver(); battle?.cancel(); battle = nil; resultSeen = true
        roster = nil; engine = nil
    }

    private func candidate(_ id: String?) -> PracticeCandidate? {
        guard let id else { return nil }
        return roster?.eligible.first { $0.id == id }
    }
    /// A ready, finished, failed or cancelled battle belongs to the old selection; a running one is never dropped.
    private func dropIdleBattle() {
        guard let battle, battle.phase != .running else { return }
        self.battle = nil; resultSeen = true
    }
    /// Manual turns wait on any reason; automatic play only on display sleep.
    private var isHeld: Bool {
        battle?.mode == .automatic ? pauseReasons.contains(.displayAsleep) : !pauseReasons.isEmpty
    }
    private func applyPause() {
        if let battle, battle.phase == .running { if isHeld { battle.pause() } else { battle.resume() } }
        syncDriver()
    }
    /// Detects the end of the battle after the engine advanced it.
    private func afterStep() {
        if battle?.phase == .finished { resultSeen = false }
        syncDriver()
    }
    private func syncDriver() {
        let shouldDrive = drivesAutomatically && battle?.phase == .running && !isHeld
        if shouldDrive { if driver == nil { startDriver() } } else { stopDriver() }
    }
    private func startDriver() {
        driverGeneration &+= 1
        let generation = driverGeneration
        driver = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
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
