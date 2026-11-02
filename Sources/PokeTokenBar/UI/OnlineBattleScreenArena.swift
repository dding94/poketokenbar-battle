import SwiftUI

@MainActor
struct OnlineBattleArena: View {
    let model: OnlineBattlePresentation
    let l: L
    let artwork: Bool

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
                            PracticeMoveCard(move: move, key: move.slot, snapshot: model.selectedEntry?.snapshot,
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

    private func sideCard(_ side: BattleView.Pokemon, own: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Group {
                    if artwork { SpriteView(speciesID: side.speciesNum, size: 40) }
                    else { PracticeSpriteTile(set: nil, size: 40, artwork: false) }
                }.frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 5) {
                    Text(own ? l.practiceYou : l.practiceFoe).font(.caption2).foregroundStyle(.secondary)
                    PracticeNameLevel(name: side.species, level: side.level)
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
                Text(side.ability ?? "?").lineLimit(2)
            }.font(.caption2)
            Text(side.moves.isEmpty ? "? · ? · ? · ?" : side.moves.joined(separator: " · "))
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.practiceCard(padding: 8)
    }
}
