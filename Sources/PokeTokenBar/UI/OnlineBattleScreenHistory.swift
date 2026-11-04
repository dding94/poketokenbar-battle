import SwiftUI

/// Past matches stay separate from the live room, choice and result state.
@MainActor
struct OnlineBattleHistory: View {
    let model: OnlineBattlePresentation
    let l: L
    let artwork: Bool
    var speciesNameProvider: any PokemonNameProviding = PokemonNameClient.shared
    var speciesNameStore: PokemonNameDisplayStore = .shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(l.onlineHistory).font(.headline)
                Spacer(minLength: 4)
                Button { model.send(.refresh) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).accessibilityLabel(l.onlineRefresh).disabled(model.isBusy || model.historyBusy)
            }
            if let battle = model.selectedHistoryBattle {
                detail(battle)
            } else if model.historyBattles.isEmpty {
                Text(l.onlineNoHistory).font(.caption).foregroundStyle(.secondary).practiceCard()
            } else {
                ForEach(model.historyBattles, id: \.battleId) { battle in
                    Button { model.send(.openReplay(battle.battleId)) } label: {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(opponentName(battle)).font(.callout).lineLimit(1).truncationMode(.middle)
                                Text(l.onlineHistoryOutcome(battle, localTrainerID: model.account?.trainer.trainerId))
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(Date(timeIntervalSince1970: battle.createdAt / 1000).formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(model.historyBusy)
                        .practiceCard(padding: 8)
                }
            }
            Button(l.onlineDone) { model.send(.backToLobby) }
                .disabled(model.isBusy || model.historyBusy)
                .accessibilityIdentifier("online.history.done")
        }
    }

    private func detail(_ battle: OnlineBattleView) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { model.send(.closeReplay) } label: { Label(l.onlineBackToHistory, systemImage: "chevron.left") }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("online.replay.close")
            VStack(alignment: .leading, spacing: 6) {
                Text(opponentName(battle)).font(.subheadline.bold())
                Text(l.onlineHistoryOutcome(battle, localTrainerID: model.account?.trainer.trainerId))
                    .font(.caption).foregroundStyle(.secondary)
                Text(Date(timeIntervalSince1970: battle.createdAt / 1000).formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2).foregroundStyle(.secondary)
            }.practiceCard()
            if let replay = model.replay, replay.frames.indices.contains(model.replayFrameIndex) {
                replayView(replay)
            } else if model.historyBusy {
                Label(l.onlineReplayLoading, systemImage: "hourglass").font(.caption).practiceCard()
            } else {
                Text(model.historyError ?? l.onlineReplayUnavailable)
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .practiceCard()
            }
        }
    }

    private func replayView(_ replay: OnlineBattleReplay) -> some View {
        let frame = replay.frames[model.replayFrameIndex]
        let own = replay.localSide == .p1 ? frame.view.p1 : frame.view.p2
        let foe = replay.localSide == .p1 ? frame.view.p2 : frame.view.p1
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(l.onlineReplay).font(.subheadline.bold())
                Spacer(minLength: 4)
                Text(l.onlineReplayStep(model.replayFrameIndex + 1, total: replay.frames.count))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            OnlineBattleCombatantCard(side: foe, own: false, l: l, artwork: artwork,
                                      speciesNameProvider: speciesNameProvider, speciesNameStore: speciesNameStore)
            OnlineBattleCombatantCard(side: own, own: true, l: l, artwork: artwork,
                                      speciesNameProvider: speciesNameProvider, speciesNameStore: speciesNameStore)
            HStack(spacing: 7) {
                stepButton(l.onlineReplayFirst, symbol: "backward.end.fill", index: 0)
                stepButton(l.onlineReplayPrevious, symbol: "chevron.left", index: model.replayFrameIndex - 1)
                stepButton(l.onlineReplayNext, symbol: "chevron.right", index: model.replayFrameIndex + 1)
                stepButton(l.onlineReplayLast, symbol: "forward.end.fill", index: replay.frames.count - 1)
            }
            OnlineBattleLogCard(logs: frame.logs, l: l)
        }
    }

    private func stepButton(_ title: String, symbol: String, index: Int) -> some View {
        Button { model.send(.seekReplay(index)) } label: { Image(systemName: symbol) }
            .buttonStyle(.bordered).frame(maxWidth: .infinity)
            .disabled(model.replay?.frames.indices.contains(index) != true || index == model.replayFrameIndex)
            .accessibilityLabel(title)
    }

    private func opponentName(_ battle: OnlineBattleView) -> String {
        let id = battle.p1.trainerId == model.account?.trainer.trainerId ? battle.p2.trainerId : battle.p1.trainerId
        return model.members.first { $0.trainerId == id }?.displayEmail ?? l.onlineAnonymous
    }
}
