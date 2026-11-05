import SwiftUI

/// The turn bar's cases. It only reads the server's deadline: nothing here starts, pauses or moves a clock, so a beat
/// playing on screen (D6) cannot change what the bar says.
enum OnlineBattleTurnClock {
    static let turnSeconds: TimeInterval = 30
    static let urgentSeconds = 5
    /// A deadline further away than this many whole seconds is not ticked toward; the bar is full until then.
    private static let scheduleSeconds = 30

    enum State: Equatable, Sendable {
        /// Nobody is waited on: an automatic battle, a forced action, or the last beats of a finished round.
        case idle
        /// A manual round with no deadline yet (right after a round, until the next one opens). Not zero seconds.
        case preparing
        /// Seconds left to the server's deadline. `mine` is true while I am the one still choosing; after my choice
        /// the clock runs for the other side and the last seconds are no alarm.
        case counting(remaining: Int, fraction: Double, mine: Bool)

        /// The last five seconds of my own choice, the bar's orange pulse and the auto-pick notice.
        var isUrgent: Bool {
            guard case .counting(let remaining, _, true) = self else { return false }
            return remaining <= OnlineBattleTurnClock.urgentSeconds
        }

        /// Only a bar with seconds left to count needs a timeline.
        var ticks: Bool {
            guard case .counting(let remaining, _, _) = self else { return false }
            return remaining > 0
        }

        /// The fill swaps between full and dim every second while urgent; reduced motion keeps it steady.
        func pulseDim(reduceMotion: Bool) -> Bool {
            guard isUrgent, !reduceMotion, case .counting(let remaining, _, _) = self else { return false }
            return remaining % 2 == 1
        }
    }

    /// `playing` is taken so a caller cannot forget it exists, and is never read: beats do not touch the clock.
    static func state(mode: OnlineBattleMode, footer: OnlineBattleArena.Footer, deadline: Date?, playing: Bool, now: Date) -> State {
        guard mode == .manual, footer == .moves || footer == .sent else { return .idle }
        guard let deadline else { return .preparing }
        let left = deadline.timeIntervalSince(now)
        return .counting(remaining: max(0, Int(ceil(left))), fraction: min(1, max(0, left / turnSeconds)), mine: footer == .moves)
    }

    /// Now, then the instant each whole second left runs out, ending at the deadline: a finite schedule, so the bar
    /// stops waking up when time is up. At most the last 30 seconds; a farther deadline starts ticking when it is that near.
    static func tickDates(deadline: Date, now: Date) -> [Date] {
        var dates = [now]
        for second in stride(from: scheduleSeconds, through: 0, by: -1) {
            let date = deadline.addingTimeInterval(-TimeInterval(second))
            if date > now { dates.append(date) }
        }
        return dates
    }
}

/// The arena's header: the mode, the turn and the seconds over the thin bar. The one timeline in the arena lives
/// here, and only while there are seconds to count.
@MainActor
struct OnlineBattleClockBand: View {
    let title: String
    let l: L
    let mode: OnlineBattleMode
    let footer: OnlineBattleArena.Footer
    let deadline: Date?
    let playing: Bool
    /// The turn of the beat on screen, and the turn the engine is at (the one being chosen).
    let stagedTurn: Int
    let viewTurn: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func state(at date: Date) -> OnlineBattleTurnClock.State {
        OnlineBattleTurnClock.state(mode: mode, footer: footer, deadline: deadline, playing: playing, now: date)
    }

    var body: some View {
        let first = state(at: .now)
        if first.ticks, let deadline {
            TimelineView(.explicit(OnlineBattleTurnClock.tickDates(deadline: deadline, now: .now))) { context in
                band(state(at: context.date))
            }
        } else {
            band(first)
        }
    }

    private func band(_ state: OnlineBattleTurnClock.State) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.subheadline.bold())
                Spacer(minLength: 4)
                Text(l.onlineClockText(state, turn: state == .idle ? stagedTurn : viewTurn))
                    .font(.caption).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
                    .foregroundStyle(state.isUrgent ? Color.orange : Color.secondary)
            }
            OnlineBattleTurnBar(state: state, dim: state.pulseDim(reduceMotion: reduceMotion))
        }
        // One element: the mode as its name, the turn and the seconds as its value. It changes with the clock but
        // VoiceOver only reads it when asked, so the seconds never interrupt anything.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(OnlineBattleSpoken.clock(l: l, state: state, turn: state == .idle ? stagedTurn : viewTurn))
    }
}

/// A 4pt capsule track with the fill scaled from its left edge. The fill moves by one linear second per tick, so it
/// drains steadily; nothing here repeats on its own.
@MainActor
struct OnlineBattleTurnBar: View {
    let state: OnlineBattleTurnClock.State
    var dim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fraction: Double {
        guard case .counting(_, let fraction, _) = state else { return 0 }
        return fraction
    }
    private var tint: Color {
        guard case .counting(_, _, let mine) = state else { return .clear }
        if state.isUrgent { return .orange }
        return mine ? .accentColor : Color.accentColor.opacity(0.5)
    }

    var body: some View {
        Capsule().fill(Color.secondary.opacity(state == .idle ? 0 : 0.18))
            .frame(height: 4)
            .overlay {
                Capsule().fill(tint.opacity(dim ? 0.55 : 1))
                    .scaleEffect(x: max(fraction, 0.0001), y: 1, anchor: .leading)
                    .opacity(fraction > 0 ? 1 : 0)
                    .animation(reduceMotion ? nil : .linear(duration: 1), value: fraction)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: dim)
            }
            .accessibilityHidden(true)
    }
}
