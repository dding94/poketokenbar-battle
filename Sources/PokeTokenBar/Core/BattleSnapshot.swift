import CryptoKit
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
    static let rules = "gen9-notera-noitems-v1"
    static let policy = "auto-v1"
    // This closed schema contains only finite integers, strings, arrays and dictionaries.
    var hash: String {
        let bytes = try! BattleJSON.encoder().encode(self)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    @MainActor static func make(speciesID: Int, form: PokemonForm? = nil, shiny: Bool = false,
                                nature: PokemonNature?, profile: PokemonProfile?, using engine: BattleEngine) throws -> BattleSnapshot {
        guard let profile else { throw Failure.missingProfile }
        guard let nature else { throw Failure.missingNature }
        guard let gender = profile.gender else { throw Failure.missingGender }
        guard let ability = profile.abilityName, !ability.isEmpty else { throw Failure.missingAbility }
        guard !profile.moves.isEmpty else { throw Failure.missingMoves }
        guard validIdentity(profile.instanceID) else { throw Failure.invalidIdentity }
        let input = BattleSet(speciesNum: speciesID, form: form?.rawValue, level: profile.level,
                              gender: gender, nature: nature.rawValue, ability: ability,
                              moves: profile.moves.map(\.name),
                              ivs: Dictionary(uniqueKeysWithValues: ["hp", "attack", "defense", "special-attack", "special-defense", "speed"].map {
                                  ($0, profile.ivs[$0])
                              }), shiny: shiny)
        let info: BattlePublicInfo = try BattleJSON.decode(engine.call(.describeSet, arguments: [BattleJSON.encode(input)]))
        return BattleSnapshot(schemaVersion: 1, instanceID: profile.instanceID, engineHash: BattleEngineManifest.sha256,
                              rulesVersion: rules, policyVersion: policy, set: input, publicInfo: info)
    }
    @MainActor static func from(_ active: MonState, using engine: BattleEngine) throws -> BattleSnapshot {
        guard active.pathIDs.indices.contains(active.stageIndex) else { throw Failure.invalidSchema }
        let speciesID = active.pathIDs[active.stageIndex]
        return try make(speciesID: speciesID, form: PokemonForm.resolved(speciesID: speciesID, form: active.form),
                        shiny: active.displaysShiny, nature: active.nature, profile: active.profile, using: engine)
    }
    @MainActor func validate(using engine: BattleEngine) throws {
        guard schemaVersion == 1, engineHash == BattleEngineManifest.sha256,
              rulesVersion == Self.rules, policyVersion == Self.policy, Self.validIdentity(instanceID) else {
            throw Failure.invalidSchema
        }
        let actual: BattlePublicInfo = try BattleJSON.decode(engine.call(.describeSet, arguments: [BattleJSON.encode(set)]))
        guard actual == publicInfo else { throw Failure.invalidSchema }
    }
    private static func validIdentity(_ id: String) -> Bool {
        !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && id.utf8.count <= 128
    }
}

/// A stable encoding shared by snapshots and the JavaScript JSON boundary.
enum BattleJSON {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
    static func encode<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encoder().encode(value), as: UTF8.self)
    }
    static func decode<T: Decodable>(_ text: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(text.utf8))
    }
}
