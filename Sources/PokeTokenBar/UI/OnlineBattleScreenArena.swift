import SwiftUI

@MainActor
struct OnlineBattleArena: View {
    let model: OnlineBattlePresentation
    let l: L
    let artwork: Bool
    var speciesNameProvider: any PokemonNameProviding = PokemonNameClient.shared
    var speciesNameStore: PokemonNameDisplayStore = .shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let view = model.arena {
                HStack {
                    Text(model.room?.mode == .auto ? l.onlineAutomatic : l.onlineManual).font(.subheadline.bold())
                    Spacer(minLength: 4)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let remaining = Self.remainingSeconds(deadline: model.deadline, now: context.date)
                        Text(l.onlineTurn(view.turn, seconds: remaining)).font(.caption).monospacedDigit()
                            .foregroundStyle(remaining <= 5 ? Color.orange : Color.secondary)
                    }
                }
                // p1 is always the challenger; account identity determines which side is mine.
                let own = model.localSide == .p1 ? view.p1 : view.p2
                let foe = model.localSide == .p1 ? view.p2 : view.p1
                sideCard(foe, own: false)
                sideCard(own, own: true)
                if model.room?.mode == .auto {
                    Label(l.onlineAutomatic, systemImage: "play.fill").font(.caption).foregroundStyle(.secondary)
                } else if model.choiceSubmitted {
                    Label(l.onlineChoiceSent, systemImage: "checkmark.circle").font(.callout)
                } else if model.request?.kind == "move" {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        ForEach(model.request?.moves ?? []) { move in
                            PracticeMoveCard(move: namedMove(move), key: move.slot, snapshot: nil,
                                             l: l, artwork: artwork, locked: !model.canChooseMove(move.slot)) {
                                model.send(.chooseMove(move.slot))
                            }
                            .accessibilityIdentifier("online.move.\(move.slot)")
                        }
                    }
                } else {
                    Text(l.onlineForced).font(.caption).foregroundStyle(.secondary)
                }
                Text(l.onlineTurnHint).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
    }

    /// Dates come from the server's millisecond deadline via the session; hiding the screen never pauses it.
    static func remainingSeconds(deadline: Date?, now: Date) -> Int {
        guard let deadline else { return 0 }
        return max(0, Int(ceil(deadline.timeIntervalSince(now))))
    }

    private func metadataSlug(_ kind: PokemonNameResource.Kind, _ id: String, own: Bool) -> String {
        let side: OnlineBattleSide = own ? model.localSide : (model.localSide == .p1 ? .p2 : .p1)
        return (kind == .move ? model.moveSlugs[side]?[id] : model.abilitySlugs[side]?[id]) ?? id
    }

    private func namedMove(_ move: BattleMove) -> BattleMove {
        .init(slot: move.slot, id: metadataSlug(.move, move.id, own: true), name: move.name, type: move.type,
              pp: move.pp, maxpp: move.maxpp, disabled: move.disabled)
    }

    private func sideCard(_ side: BattleView.Pokemon, own: Bool) -> some View {
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
            // The resolver view is the sole source of revealed metadata. Never read frozen opponent config.
            HStack(alignment: .top, spacing: 4) {
                Text(l.practiceAbility).foregroundStyle(.secondary)
                if let ability = side.ability {
                    PracticeMetadataName(kind: .ability, id: metadataSlug(.ability, ability, own: own), snapshot: nil,
                                         l: l, artwork: artwork)
                } else { Text("?") }
            }.font(.caption2)
            WrappingHStack(spacing: 4, lineSpacing: 4) {
                ForEach(Array(side.moves.prefix(4)), id: \.self) { move in
                    PracticeChip {
                        if move == "recharge" { Text(l.practiceRecharge) }
                        else if move == "struggle" { Text(l.practiceStruggle) }
                        else {
                            PracticeMetadataName(kind: .move, id: metadataSlug(.move, move, own: own), snapshot: nil,
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
