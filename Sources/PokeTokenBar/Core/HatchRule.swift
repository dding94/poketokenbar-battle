import Foundation

/// The app's hatch rule, shared by eggs (`CompanionStore.chooseBase`) and practice wild opponents.
enum HatchRule {
    /// One weighted roll over the base-species index: a species weighs its capture rate, halved once its
    /// line is collected (`CollectionWeight.adjusted`). `roll` is a single `next()` of the caller's RNG, so
    /// eggs consume randomness exactly as before. nil for an empty index.
    static func pickBase(from index: [BaseSpecies], isCollected: (Int) -> Bool, roll: UInt64) -> Int? { nil }
}
