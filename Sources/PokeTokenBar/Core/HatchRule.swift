import Foundation

/// The app's hatch rule, shared by eggs (`CompanionStore.chooseBase`) and practice wild opponents.
enum HatchRule {
    /// One weighted roll over the base-species index: a species weighs its capture rate, halved once its
    /// line is collected (`CollectionWeight.adjusted`). `roll` is a single `next()` of the caller's RNG, so
    /// eggs consume randomness exactly as before. nil for an empty index.
    static func pickBase(from index: [BaseSpecies], isCollected: (Int) -> Bool, roll: UInt64) -> Int? {
        guard !index.isEmpty else { return nil }
        let weights = index.map { CollectionWeight.adjusted($0.captureRate, isCollected: isCollected($0.id)) }
        let total = weights.reduce(0, +)
        var r = Int(roll % UInt64(total))
        for (i, w) in weights.enumerated() {
            r -= w
            if r < 0 { return index[i].id }
        }
        return index.last?.id   // unreachable (defensive)
    }
}
