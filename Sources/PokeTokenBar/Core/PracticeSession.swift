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
    var playerID: String?
    var opponentID: String?
    /// Applies to the next `start()`; while a battle runs it switches that battle immediately.
    var mode: PracticeBattle.Mode = .manual

    private let engineURL: URL?
    private let clock: () -> TimeInterval
    private let drivesAutomatically: Bool

    /// `drivesAutomatically: false` leaves `tick()` to the caller (tests with an injected clock).
    init(engineURL: URL?, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         drivesAutomatically: Bool = true) {
        self.engineURL = engineURL; self.clock = clock; self.drivesAutomatically = drivesAutomatically
    }

    var player: PracticeCandidate? { nil }
    var opponent: PracticeCandidate? { nil }
    /// A running battle or an unseen result: the popover reopens on the practice screen.
    var isActive: Bool { false }
    /// Menu bar suffix for the current state (`PracticeStatusBadge`).
    var statusBadge: String? { nil }

    /// Creates the engine once and rebuilds the roster from `state`. Keeps a still-eligible selection,
    /// otherwise defaults to the first eligible candidate (player) and the next one (opponent). Leaves a
    /// running battle untouched. Failures land in `loadError`.
    func prepare(state: CompanionState, activeName: String?) {}
    /// Starts a battle with the current selection and mode; a rematch is the same call.
    func start() {}
    /// Manual move choice for the player; ignored while paused or in automatic mode.
    func choose(slot: Int) {}
    /// Gives up the running battle and returns to the selection screen.
    func forfeit() {}
    /// Leaves a finished battle for the selection screen (to pick another opponent).
    func backToSelection() {}
    /// The result screen calls this when it is shown.
    func markResultSeen() {}
    /// Adds or removes a pause reason, then holds or resumes the battle per `PracticePauseReason`.
    func setPaused(_ paused: Bool, reason: PracticePauseReason) {}
    /// Advances deadlines and automatic turns at `clock()`. The internal driver calls it while a battle
    /// runs; with `drivesAutomatically: false` the caller does.
    func tick() {}
    /// Drops the engine and roster when no battle is active (popover closed, practice screen left).
    func releaseIfIdle() {}
}

/// One-glyph menu bar suffix: a running battle shows "⚔︎", a finished and unseen one "⚑", otherwise nil.
enum PracticeStatusBadge {
    static func text(phase: PracticeBattle.Phase?, resultSeen: Bool) -> String? { nil }
}
