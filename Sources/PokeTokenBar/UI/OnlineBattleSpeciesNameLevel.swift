import SwiftUI

/// Localized public species name. No frozen set, move or ability data enters this view.
@MainActor
struct OnlineBattleSpeciesNameLevel: View {
    let speciesNum: Int
    let publicName: String
    let level: Int
    let language: AppLanguage
    var provider: any PokemonNameProviding = PokemonNameClient.shared
    var displayStore: PokemonNameDisplayStore = .shared
    var loadsNames = true

    var speciesResource: PokemonNameResource { .init(kind: .pokemonSpecies, name: String(speciesNum)) }
    var displayName: String { publicName }
    var body: some View { PracticeNameLevel(name: displayName, level: level) }
}
