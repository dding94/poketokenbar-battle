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
    private var publicForm: (form: PokemonForm?, suffix: String)? {
        guard let english = displayStore.names[speciesResource]?["en"],
              publicName.lowercased().hasPrefix(english.lowercased() + "-") else { return nil }
        let suffix = String(publicName.dropFirst(english.count + 1))
        let key = suffix.filter { $0.isLetter || $0.isNumber }.lowercased()
        let form = PokemonForm.forms(speciesID: speciesNum).first {
            $0.rawValue.filter { $0.isLetter || $0.isNumber }.lowercased() == key
        }
        return (form, suffix)
    }
    private var formResource: PokemonNameResource? {
        guard let form = publicForm?.form else { return nil }
        return PokemonForm.nameResource(speciesID: speciesNum, form: form)
    }
    var displayName: String {
        guard let names = displayStore.names[speciesResource], let localized = language.resolveName(names) else {
            return publicName
        }
        guard let publicForm else { return localized }
        if let form = publicForm.form {
            return PokemonForm.displayName(localized, speciesID: speciesNum, form: form,
                                           label: PokemonForm.label(speciesID: speciesNum, form: form, language: language, names: displayStore))
        }
        return "\(localized) [\(PokemonNameLocalization.identifier(publicForm.suffix))]"
    }
    /// Fills the shared name cache for this species and its public form; `displayName` reads it.
    func load() async {
        guard loadsNames else { return }
        _ = await displayStore.load(speciesResource, provider: provider)
        if let formResource { _ = await displayStore.load(formResource, provider: provider) }
    }
    var body: some View {
        PracticeNameLevel(name: displayName, level: level)
            .task(id: [speciesResource.cacheKey, publicName]) { await load() }
    }
}
