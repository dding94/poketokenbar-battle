import SwiftUI

@MainActor
struct OnlineBattleLobby: View {
    let model: OnlineBattlePresentation
    let l: L
    let artwork: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(model.account?.group.name ?? l.onlineTitle).font(.headline).lineLimit(2)
                Spacer(minLength: 4)
                Button { model.send(.refresh) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).accessibilityLabel(l.onlineRefresh).disabled(model.isBusy)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(l.onlineMembers).font(.subheadline.bold())
                ForEach(model.members.filter { $0.status == .active && $0.trainerId != model.account?.trainer.trainerId }, id: \.trainerId) { member in
                    Button { model.send(.selectOpponent(member.trainerId)) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: model.selectedOpponentID == member.trainerId ? "checkmark.circle.fill" : "circle")
                            Text(member.displayEmail ?? l.onlineAnonymous).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            Text(member.online ? l.onlineAvailable : l.onlineOffline).font(.caption2).foregroundStyle(.secondary)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    .accessibilityIdentifier("online.member.\(member.trainerId)")
                }
            }.practiceCard()
            OnlineBattleRoster(model: model, l: l, artwork: artwork)
            VStack(alignment: .leading, spacing: 7) {
                Picker(l.onlineMode, selection: Binding(get: { model.mode }, set: { model.send(.setMode($0)) })) {
                    Text(l.onlineManual).tag(OnlineBattleMode.manual)
                    Text(l.onlineAuto).tag(OnlineBattleMode.auto)
                }.pickerStyle(.segmented).disabled(model.isBusy)
                Text(l.onlineTurnHint).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(l.onlineStakesHint).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(l.onlineChallenge) { model.send(.challenge) }
                    .buttonStyle(.borderedProminent).disabled(!model.canChallenge)
                    .accessibilityIdentifier("online.challenge")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(l.onlineBattles).font(.subheadline.bold())
                if model.activeBattles.isEmpty { Text(l.onlineNoBattles).font(.caption).foregroundStyle(.secondary) }
                ForEach(model.activeBattles, id: \.battleId) { battle in
                    Button { model.send(.openBattle(battle.battleId)) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(opponentName(battle)).font(.callout).lineLimit(1).truncationMode(.middle)
                                Text(l.onlineState(battle.state)).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right").font(.caption)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(model.isBusy)
                }
            }.practiceCard()
            Button { model.send(.showHistory) } label: {
                HStack {
                    Label(l.onlineHistory, systemImage: "clock.arrow.circlepath")
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.caption)
                }
            }
            .buttonStyle(.plain).disabled(model.isBusy)
            .accessibilityIdentifier("online.history.open")
            .practiceCard()
        }
    }
    private func opponentName(_ battle: OnlineBattleView) -> String {
        let id = battle.p1.trainerId == model.account?.trainer.trainerId ? battle.p2.trainerId : battle.p1.trainerId
        return model.members.first { $0.trainerId == id }?.displayEmail ?? l.onlineAnonymous
    }

}

@MainActor
struct OnlineBattleRoster: View {
    let model: OnlineBattlePresentation
    let l: L
    let artwork: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(l.onlineOwnEntry).font(.subheadline.bold())
            if model.roster.isEmpty { Text(l.onlineNoEntries).font(.caption).foregroundStyle(.secondary) }
            ForEach(model.roster) { entry in
                Button { model.send(.selectEntry(entry.id)) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: model.selectedEntryID == entry.id ? "checkmark.circle.fill" : "circle")
                        PracticeSpriteTile(set: entry.snapshot?.set, size: 30, artwork: artwork)
                        VStack(alignment: .leading, spacing: 3) {
                            PracticeNameLevel(name: entry.name, level: entry.snapshot?.publicInfo.level ?? 0)
                            if let reason = blockedReason(entry) {
                                Text(reason).font(.caption2).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else if let info = entry.snapshot?.publicInfo {
                                HStack(spacing: 4) {
                                    PracticeTypeBadges(types: info.types, l: l, artwork: artwork)
                                    Text(l.onlineHP(Self.hpPercent(model.entryHP[entry.id] ?? 0, max: info.stats["hp"] ?? 1)))
                                        .font(.caption2).monospacedDigit()
                                }
                            }
                        }
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(model.isBusy || !model.entryIsEligible(entry))
                .accessibilityIdentifier("online.entry.\(entry.id)")
            }
        }.practiceCard()
    }
    private func blockedReason(_ entry: PracticeCandidate) -> String? {
        if let reason = entry.blockedReason { return reason }
        if model.blockedEntryIDs.contains(entry.id) { return l.onlineHeld }
        if (model.entryHP[entry.id] ?? 0) <= 0 { return l.onlineFainted }
        return nil
    }
    static func hpPercent(_ hp: Int, max maxHP: Int) -> Int { maxHP > 0 ? min(100, max(0, Int((Double(hp) / Double(maxHP) * 100).rounded()))) : 0 }
}

@MainActor
struct OnlineBattleRoom: View {
    let model: OnlineBattlePresentation
    let l: L
    let artwork: Bool
    var speciesNameProvider: any PokemonNameProviding = PokemonNameClient.shared
    var speciesNameStore: PokemonNameDisplayStore = .shared
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let room = model.room {
                Text(l.onlineState(room.state)).font(.headline)
                Text(room.mode == .manual ? l.onlineManual : l.onlineAuto).font(.caption).foregroundStyle(.secondary)
                publicEntry(room.p1, own: model.localSide == .p1)
                publicEntry(room.p2, own: model.localSide == .p2)
                if room.state == .pending && model.localSide == .p2 {
                    OnlineBattleRoster(model: model, l: l, artwork: artwork)
                }
                Text(l.onlineNoLevelLimit).font(.caption).foregroundStyle(.secondary)
                Text(l.onlineHidden).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(l.onlineStakesHint).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if room.state == .pending && model.localSide == .p2 {
                    HStack {
                        Button(l.onlineAccept) { model.send(.accept) }.buttonStyle(.borderedProminent).disabled(!model.canAccept)
                        Button(l.onlineDecline) { model.send(.decline) }.disabled(model.isBusy)
                    }
                } else if room.state == .accepted && model.localSide == .p1 && !room.confirmed {
                    Button(l.onlineConfirm) { model.send(.confirm) }.buttonStyle(.borderedProminent).disabled(!model.canConfirm)
                } else if room.confirmed && [.accepted, .ready].contains(room.state) {
                    Button(l.onlinePrepare) { model.send(.prepareBattle) }.buttonStyle(.borderedProminent).disabled(!model.canPrepare)
                } else {
                    Text(l.onlineWaiting).font(.caption).foregroundStyle(.secondary)
                }
                if [.pending, .accepted, .ready].contains(room.state) {
                    Button(l.onlineCancel) { model.send(.cancel) }.disabled(model.isBusy)
                }
            }
        }
    }
    @ViewBuilder private func publicEntry(_ player: OnlineBattlePlayer, own: Bool) -> some View {
        if let info = player.publicInfo ?? player.snapshot?.publicInfo {
            let percent = player.hpPercent ?? player.snapshot.map { Double($0.hp) / Double(max(1, info.stats["hp"] ?? 1)) * 100 } ?? 0
            VStack(alignment: .leading, spacing: 7) {
                Text(own ? l.practiceYou : l.practiceFoe).font(.caption2).foregroundStyle(.secondary)
                OnlineBattleSpeciesNameLevel(speciesNum: info.speciesNum, publicName: info.species, level: info.level, language: l.lang,
                                           provider: speciesNameProvider, displayStore: speciesNameStore, loadsNames: artwork)
                HStack {
                    PracticeTypeBadges(types: info.types, l: l, artwork: artwork)
                    Spacer(minLength: 4)
                    Text(l.onlineHP(Int(percent.rounded()))).font(.caption).monospacedDigit()
                }
                PracticeHPBar(hp: Int(percent.rounded()), maxHP: 100)
                // Only the server's public shape is consumed here. Never snapshot.set or config.
                Text(["hp", "atk", "def", "spa", "spd", "spe"].compactMap { key in
                    info.stats[key].map { "\(l.practiceStatName(key)) \($0)" }
                }.joined(separator: " · "))
                .font(.system(size: 10)).monospacedDigit().fixedSize(horizontal: false, vertical: true)
            }.practiceCard()
        }
    }
}
