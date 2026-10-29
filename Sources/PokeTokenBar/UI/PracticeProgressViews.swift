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

/// The practice record in one line: "12승 5패 1무 · 3연승 (최고 7)", or a first-time line before any battle.
@MainActor
struct PracticeRecordsLine: View {
    let records: PracticeRecords
    let l: L

    var body: some View { EmptyView() }   // RED stub
}

/// How the opponent picks its moves, as a small tag next to its types. Nothing without a temperament.
@MainActor
struct PracticeTemperamentTag: View {
    let temperament: PracticeTemperament?
    let l: L
    /// The symbol alone, for a row that runs out of room; the tooltip and VoiceOver keep the word.
    var compact = false

    var body: some View { EmptyView() }   // RED stub
}

/// Today's three goals, each with a filled star once earned today.
@MainActor
struct PracticeDailyGoalList: View {
    let stars: Set<PracticeDailyGoal>
    let l: L

    /// The goals in order with whether each is earned; the list draws exactly these rows.
    static func rows(stars: Set<PracticeDailyGoal>) -> [(goal: PracticeDailyGoal, earned: Bool)] { [] }   // RED stub

    var body: some View { EmptyView() }   // RED stub
}

/// Today's opponent above the wild ones: a header with today's star count, the three goals, then the opponent
/// row (`row`) — or, while the opponent is missing, the search state with a retry worded like the wild notice.
@MainActor
struct PracticeDailyCard<Row: View>: View {
    let candidate: PracticeCandidate?
    let state: PracticeWildState
    let stars: Set<PracticeDailyGoal>
    let l: L
    let onRetry: () -> Void
    @ViewBuilder let row: (PracticeCandidate) -> Row

    var body: some View { EmptyView() }   // RED stub
}

/// What takes today's opponent's row while it is missing.
enum PracticeDailyNotice: Equatable {
    case idle, searching, unavailable

    /// nil when the opponent is there: a candidate always shows, whatever a newer search is doing.
    init?(candidate: PracticeCandidate?, state: PracticeWildState) { return nil }   // RED stub
}

/// What the battle that just ended did to the record (`PracticeRecordUpdate`): the streak change and, after
/// today's opponent, today's three stars with the ones this battle earned highlighted.
@MainActor
struct PracticeResultRecord: View {
    let update: PracticeRecordUpdate
    let l: L

    enum Streak: Equatable {
        /// A win after a loss, a draw or nothing.
        case started
        case continued(Int)
        case ended(Int)
    }

    /// A goal's star on the result: earned by this battle, earlier today, or not yet.
    enum Star: Equatable { case new, earned, open }

    static func streak(_ update: PracticeRecordUpdate) -> Streak? { nil }   // RED stub
    static func atBest(_ update: PracticeRecordUpdate) -> Bool { false }   // RED stub
    static func star(_ goal: PracticeDailyGoal, in update: PracticeRecordUpdate) -> Star { .open }   // RED stub
    /// Neither a streak change nor today's opponent: the result screen leaves the card out.
    static func isEmpty(_ update: PracticeRecordUpdate) -> Bool { true }   // RED stub

    var body: some View { EmptyView() }   // RED stub
}
