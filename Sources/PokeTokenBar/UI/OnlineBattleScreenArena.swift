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
                OnlineBattleCombatantCard(side: foe, own: false, l: l, artwork: artwork,
                                          moveSlugs: model.moveSlugs[model.localSide == .p1 ? .p2 : .p1] ?? [:],
                                          abilitySlugs: model.abilitySlugs[model.localSide == .p1 ? .p2 : .p1] ?? [:],
                                          speciesNameProvider: speciesNameProvider, speciesNameStore: speciesNameStore)
                OnlineBattleCombatantCard(side: own, own: true, l: l, artwork: artwork,
                                          moveSlugs: model.moveSlugs[model.localSide] ?? [:],
                                          abilitySlugs: model.abilitySlugs[model.localSide] ?? [:],
                                          speciesNameProvider: speciesNameProvider, speciesNameStore: speciesNameStore)
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
                OnlineBattleLogCard(logs: model.liveLogs, l: l)
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

}
