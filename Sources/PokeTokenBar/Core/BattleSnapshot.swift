import Foundation

struct BattleSet: Codable, Equatable, Sendable {
    let speciesNum: Int
    let form: String?
    let level: Int
    let gender: PokemonGender
    let nature: String
    let ability: String
    let moves: [String]
    let ivs: [String: Int]
    let shiny: Bool
}
struct BattlePublicInfo: Codable, Equatable, Sendable {
    let speciesNum: Int
    let species: String
    let level: Int
    let types: [String]
    let stats: [String: Int]
}
struct BattleSnapshot: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let instanceID: String
    let engineHash: String
    let rulesVersion: String
    let policyVersion: String
    let set: BattleSet
    let publicInfo: BattlePublicInfo
    enum Failure: Error, Equatable { case missingProfile, missingNature, missingGender, missingAbility, missingMoves, invalidIdentity, invalidSchema }
    var hash: String { "not_implemented" }
    @MainActor static func make(speciesID: Int, form: PokemonForm? = nil, shiny: Bool = false,
                                nature: PokemonNature?, profile: PokemonProfile?, using engine: BattleEngine) throws -> BattleSnapshot {
        throw Failure.missingProfile
    }
    @MainActor static func from(_ active: MonState, using engine: BattleEngine) throws -> BattleSnapshot {
        throw Failure.missingProfile
    }
    @MainActor func validate(using engine: BattleEngine) throws { throw Failure.invalidSchema }
}
