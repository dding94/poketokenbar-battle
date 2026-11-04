import SwiftUI

/// Renders only the side's viewer state. A replay never reads its saved private snapshot here.
@MainActor
struct OnlineBattleCombatantCard: View {
    let side: BattleView.Pokemon
    let own: Bool
    let l: L
    let artwork: Bool
    var moveSlugs: [String: String] = [:]
    var abilitySlugs: [String: String] = [:]
    var speciesNameProvider: any PokemonNameProviding = PokemonNameClient.shared
    var speciesNameStore: PokemonNameDisplayStore = .shared

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Group {
                    if artwork { SpriteView(speciesID: side.speciesNum, size: 40) }
                    else { PracticeSpriteTile(set: nil, size: 40, artwork: false) }
                }.frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 5) {
                    Text(own ? l.practiceYou : l.practiceFoe).font(.caption2).foregroundStyle(.secondary)
                    OnlineBattleSpeciesNameLevel(speciesNum: side.speciesNum, publicName: side.species, level: side.level, language: l.lang,
                                                 provider: speciesNameProvider, displayStore: speciesNameStore, loadsNames: artwork)
                    PracticeTypeBadges(types: side.types, l: l, artwork: artwork)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                PracticeHPBar(hp: side.hp, maxHP: side.maxhp)
                Text(own ? "\(side.hp)/\(side.maxhp)" : l.onlineHP(side.hp))
                    .font(.caption).monospacedDigit().frame(minWidth: 50, alignment: .trailing)
            }
            if !side.status.isEmpty {
                Text(l.practiceStatusName(side.status)).font(.caption2).foregroundStyle(.orange)
            }
            HStack(alignment: .top, spacing: 4) {
                Text(l.practiceAbility).foregroundStyle(.secondary)
                if let ability = side.ability {
                    PracticeMetadataName(kind: .ability, id: abilitySlugs[ability] ?? ability, snapshot: nil,
                                         l: l, artwork: artwork)
                } else { Text("?") }
            }.font(.caption2)
            WrappingHStack(spacing: 4, lineSpacing: 4) {
                ForEach(Array(side.moves.prefix(4)), id: \.self) { move in
                    PracticeChip {
                        if move == "recharge" { Text(l.practiceRecharge) }
                        else if move == "struggle" { Text(l.practiceStruggle) }
                        else {
                            PracticeMetadataName(kind: .move, id: moveSlugs[move] ?? move, snapshot: nil,
                                                 l: l, artwork: artwork)
                        }
                    }
                }
                ForEach(0..<max(0, own ? 0 : 4 - side.moves.count), id: \.self) { _ in
                    PracticeChip(dimmed: true) { Text("?") }
                }
            }
        }.practiceCard(padding: 8)
    }
}

@MainActor
struct OnlineBattleLogCard: View {
    let logs: [String]
    let l: L

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(l.onlineBattleLog).font(.subheadline.bold())
            if logs.isEmpty {
                Text(l.onlineNoLog).font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(Array(logs.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }.practiceCard(padding: 8)
    }
}
