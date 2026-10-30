import SwiftUI

// Practice progress on the popover screens (03B-5): the record line, today's opponent with its three goals, the
// opponent temperament tag and what a finished battle did to the record. Every view takes plain values, so it
// renders the same from the session or from test data; none of them reads or writes the record file.

/// What the selection screen shows about practice progress: the record line and today's opponent. The screen
/// reads these values only through this snapshot (`init(_:)` takes them off the session).
struct PracticeSelectionProgress {
    var records = PracticeRecords()
    /// Today's opponent (`PracticeSession.dailyCandidate`); nil while it is searched or could not be made.
    var daily: PracticeCandidate?
    var dailyState: PracticeWildState = .idle
}

extension PracticeSelectionProgress {
    @MainActor init(_ session: PracticeSession) {
        self.init(records: session.records, daily: session.dailyCandidate, dailyState: session.dailyState)
    }
}

/// Earned stars are gold; open ones are a secondary outline.
enum PracticeStarStyle {
    static let gold = Color(red: 0.96, green: 0.69, blue: 0.0)
}

/// The practice record in one line: "12승 5패 1무 · 3연승 (최고 7)", or a first-time line before any battle.
/// The flame lights up while a streak runs.
@MainActor
struct PracticeRecordsLine: View {
    let records: PracticeRecords
    let l: L

    private var played: Bool { records.wins + records.losses + records.draws > 0 }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: records.streak > 0 ? "flame.fill" : "chart.bar.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(records.streak > 0 ? Color.orange : Color.secondary)
                .frame(width: 14)
            line
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 0)
        }
        .font(.caption.weight(.medium))
        .monospacedDigit()
        .accessibilityElement(children: .combine)
    }

    /// The totals stay quiet and a running streak reads in full strength: it is the number worth keeping.
    private var line: Text {
        guard played else { return Text(l.practiceRecordEmpty).foregroundStyle(.secondary) }
        let totals = Text(l.practiceRecordTotals(wins: records.wins, losses: records.losses, draws: records.draws))
            .foregroundStyle(.secondary)
        guard let streak = l.practiceRecordStreak(streak: records.streak, best: records.bestStreak) else { return totals }
        let running = records.streak > 0
        return totals + Text(l.practiceSeparator).foregroundStyle(.tertiary)
            + Text(streak).fontWeight(running ? .semibold : .medium)
                .foregroundStyle(running ? Color.primary : Color.secondary)
    }
}

/// How the opponent picks its moves, as a small tag next to its types: a symbol and a short word in the
/// temperament's tint, the way the wild tag reads. Nothing without a temperament. The tooltip says what it means.
@MainActor
struct PracticeTemperamentTag: View {
    let temperament: PracticeTemperament?
    let l: L
    /// The symbol alone, for a row that runs out of room; the tooltip and VoiceOver keep the word.
    var compact = false

    var body: some View {
        if let temperament {
            let tint = Self.tint(temperament)
            HStack(spacing: 2) {
                Image(systemName: Self.symbol(temperament)).font(.system(size: 7, weight: .bold))
                if !compact { Text(l.practiceTemperament(temperament)) }
            }
            .font(.system(size: 9, weight: .bold))
            .lineLimit(1)
            .foregroundStyle(tint)
            .padding(.horizontal, compact ? 4 : 5).padding(.vertical, 1)
            .background(tint.opacity(0.14), in: Capsule())
            .fixedSize()
            .help(l.practiceTemperamentHint(temperament))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(l.practiceTemperament(temperament))
            .accessibilityHint(l.practiceTemperamentHint(temperament))
        }
    }

    static func symbol(_ temperament: PracticeTemperament) -> String {
        switch temperament {
        case .standard: "scope"
        case .aggressive: "flame.fill"
        case .tactical: "shield.lefthalf.filled"
        case .erratic: "shuffle"
        }
    }

    static func tint(_ temperament: PracticeTemperament) -> Color {
        switch temperament {
        case .standard: .gray
        case .aggressive: .red
        case .tactical: .indigo
        case .erratic: .purple
        }
    }
}

/// Today's three goals, each with a gold star once earned today; the words come from the goals' numbers.
@MainActor
struct PracticeDailyGoalList: View {
    let stars: Set<PracticeDailyGoal>
    let l: L

    /// The goals in order with whether each is earned; the list draws exactly these rows.
    static func rows(stars: Set<PracticeDailyGoal>) -> [(goal: PracticeDailyGoal, earned: Bool)] {
        PracticeDailyGoal.allCases.sorted().map { (goal: $0, earned: stars.contains($0)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Self.rows(stars: stars), id: \.goal) { row in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: row.earned ? "star.fill" : "star")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(row.earned ? PracticeStarStyle.gold : Color.secondary)
                        .frame(width: 14)
                    Text(l.practiceDailyGoal(row.goal))
                        .foregroundStyle(row.earned ? Color.primary : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .font(.caption)
    }
}

/// Today's opponent above the wild ones: a header with today's star count, the three goals, then the opponent
/// row (`row`) — or, while the opponent is missing, the search state with a retry worded like the wild notice.
/// The goals stay in every state, so today's stars never vanish with the network.
@MainActor
struct PracticeDailyCard<Row: View>: View {
    let candidate: PracticeCandidate?
    let state: PracticeWildState
    let stars: Set<PracticeDailyGoal>
    let l: L
    let onRetry: () -> Void
    @ViewBuilder let row: (PracticeCandidate) -> Row

    private var total: Int { PracticeDailyGoal.allCases.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            header
            PracticeDailyGoalList(stars: stars, l: l)
            if let candidate {
                row(candidate)
            } else if let notice = PracticeDailyNotice(candidate: candidate, state: state) {
                noticeRow(notice)
            }
        }
        .padding(8)
        .background(PracticeStarStyle.gold.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PracticeStarStyle.gold.opacity(0.35)))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Label {
                Text(l.practiceDailyTitle)
            } icon: {
                Image(systemName: "sun.max.fill").foregroundStyle(.orange)
            }
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            Spacer(minLength: 4)
            HStack(spacing: 3) {
                Image(systemName: "star.fill")
                    .foregroundStyle(stars.isEmpty ? Color.secondary : PracticeStarStyle.gold)
                Text("\(stars.count)/\(total)")
            }
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(l.practiceDailyStarsSpoken(earned: stars.count, total: total))
        }
    }

    /// One row in the opponent's place, styled like the wild section's notice. No spinner: the wild section right
    /// below already shows the one search both come from.
    private func noticeRow(_ notice: PracticeDailyNotice) -> some View {
        HStack(spacing: 8) {
            switch notice {
            case .idle, .searching:
                Image(systemName: "hourglass").foregroundStyle(.secondary)
                Text(l.practiceDailySearching).foregroundStyle(.secondary)
            case .unavailable:
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(l.practiceDailyUnavailable).foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(l.practiceDailyUnavailable)
                Spacer(minLength: 4)
                Button(l.retry, action: onRetry)
                    .buttonStyle(.borderless)
                    .fixedSize()
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .padding(.horizontal, 8).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// What takes today's opponent's row while it is missing.
enum PracticeDailyNotice: Equatable {
    case idle, searching, unavailable

    /// nil when the opponent is there: a candidate always shows, whatever a newer search is doing. A finished
    /// search that made no daily opponent reads as unavailable, so it offers the retry.
    init?(candidate: PracticeCandidate?, state: PracticeWildState) {
        guard candidate == nil else { return nil }
        switch state {
        case .idle: self = .idle
        case .searching: self = .searching
        case .ready, .unavailable: self = .unavailable
        }
    }
}

/// What the battle that just ended did to the record (`PracticeRecordUpdate`): the streak change with a mark at
/// the personal best and, after today's opponent, today's three stars with the ones this battle earned
/// highlighted. The result screen leaves it out when there is neither (`isEmpty`).
@MainActor
struct PracticeResultRecord: View {
    let update: PracticeRecordUpdate
    let l: L

    enum Streak: Equatable {
        /// A win after a loss, a draw or nothing.
        case started
        case continued(Int)
        case ended(Int)

        var isEnded: Bool {
            if case .ended = self { return true }
            return false
        }
    }

    /// A goal's star on the result: earned by this battle, earlier today, or not yet.
    enum Star: Equatable { case new, earned, open }

    static func streak(_ update: PracticeRecordUpdate) -> Streak? {
        switch update.outcome {
        case .win: return update.streak >= 2 ? .continued(update.streak) : .started
        case .loss, .draw: return update.endedStreak.flatMap { $0 >= 1 ? .ended($0) : nil }
        }
    }

    /// A win of at least two in a row that reaches the best streak. The update carries the best after the battle,
    /// so a streak that ties an older best reads the same as a new one; "personal best" is true of both.
    static func atBest(_ update: PracticeRecordUpdate) -> Bool {
        update.outcome == .win && update.streak >= 2 && update.streak >= update.bestStreak
    }

    static func star(_ goal: PracticeDailyGoal, in update: PracticeRecordUpdate) -> Star {
        update.newStars.contains(goal) ? .new : update.stars.contains(goal) ? .earned : .open
    }

    /// Neither a streak change nor today's opponent: the result screen leaves the card out.
    static func isEmpty(_ update: PracticeRecordUpdate) -> Bool { streak(update) == nil && !update.daily }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let streak = Self.streak(update) { streakRow(streak) }
            if update.daily { starsRow }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .practiceCard(padding: 8)
    }

    private func streakRow(_ streak: Streak) -> some View {
        let ended = streak.isEnded
        return HStack(spacing: 6) {
            Image(systemName: ended ? "flame" : "flame.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ended ? Color.secondary : Color.orange)
            Text(words(streak))
                .font(.callout.weight(.semibold))
                .foregroundStyle(ended ? Color.secondary : Color.primary)
                .lineLimit(1)
            if Self.atBest(update) { bestMark }
            Spacer(minLength: 0)
        }
    }

    private func words(_ streak: Streak) -> String {
        switch streak {
        case .started: l.practiceStreakStarted
        case .continued(let count): l.practiceStreakContinued(count)
        case .ended(let count): l.practiceStreakEnded(count)
        }
    }

    private var bestMark: some View {
        HStack(spacing: 3) {
            Image(systemName: "crown.fill").font(.system(size: 8, weight: .bold))
            Text(l.practiceBestStreak)
        }
        .font(.caption2.weight(.bold))
        .lineLimit(1)
        .foregroundStyle(.primary)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(PracticeStarStyle.gold.opacity(0.3), in: Capsule())
        .fixedSize()
    }

    /// "오늘의 별" and one chip per goal: a gold star once earned, a gold capsule for the ones this battle earned.
    private var starsRow: some View {
        HStack(spacing: 5) {
            Text(l.practiceTodayStars).font(.caption).foregroundStyle(.secondary).fixedSize()
            ForEach(PracticeDailyGoal.allCases.sorted(), id: \.self) { goal in starChip(goal) }
            Spacer(minLength: 0)
        }
    }

    private func starChip(_ goal: PracticeDailyGoal) -> some View {
        let star = Self.star(goal, in: update)
        return HStack(spacing: 3) {
            Image(systemName: star == .open ? "star" : "star.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(star == .open ? Color.secondary : PracticeStarStyle.gold)
            Text(l.practiceDailyGoalShort(goal))
                .foregroundStyle(star == .open ? Color.secondary : Color.primary)
        }
        .font(.caption2.weight(star == .new ? .bold : .medium))
        .lineLimit(1)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(star == .new ? PracticeStarStyle.gold.opacity(0.28) : Color.secondary.opacity(0.08), in: Capsule())
        .overlay(Capsule().strokeBorder(star == .new ? PracticeStarStyle.gold : Color.clear))
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}
