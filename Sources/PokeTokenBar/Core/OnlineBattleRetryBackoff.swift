import Foundation

/// How long an automatic retry waits after failures in a row. A fixed five seconds costs a free-plan day's worth of
/// requests during one long outage, while the first retry still comes as soon as it always did.
struct OnlineBattleRetryBackoff {
    static let base: TimeInterval = 5
    static let cap: TimeInterval = 300
    private var failures = 0

    /// The wait before the next try, counting the failure that just happened.
    mutating func nextDelay() -> TimeInterval {
        let delay = min(Self.cap, Self.base * pow(2, Double(failures)))
        // Past the cap the count no longer matters; stopping here keeps the power finite.
        if delay < Self.cap { failures += 1 }
        return delay
    }
}
