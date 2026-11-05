import SwiftUI

@MainActor
struct OnlineBattleLobby: View {
    let model: OnlineBattlePresentation
    let l: L
    let artwork: Bool
    /// Row badges to draw instead of the ones read from the model; tests pin them here.
    var badges: [String: OnlineLobbyRowBadge]? = nil
    /// Carries the facts the presentation lacks (readiness is bound to the connection), so a row and the menu mark agree.
    @Environment(OnlineAttentionSource.self) private var attention: OnlineAttentionSource?

    private var rowBadges: [String: OnlineLobbyRowBadge] {
        if let badges { return badges }
        let input = attention?.input()
            ?? OnlineAttentionInput(presentation: model, preparedBattleIDs: [], stagingHeldBattleIDs: [], now: Date())
        return OnlineLobbyRowBadge.badges(input)
    }
    /// The peer the challenge button would send to, if one is chosen.
    private var chosenPeer: OnlineBattleMember? { model.lobbyPeers.first { $0.trainerId == model.selectedOpponentID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let steps = model.firstSteps {
                OnlineBattleFirstStepsCard(steps: steps, l: l) { model.send(.dismissFirstSteps) }
            }
            HStack {
                Text(model.account?.group.name ?? l.onlineTitle).font(.headline).lineLimit(2)
                Spacer(minLength: 4)
                Button { model.send(.refresh) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).accessibilityLabel(l.onlineRefresh).disabled(model.isBusy)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(l.onlineMembers).font(.subheadline.bold())
                if model.lobbyPeers.isEmpty {
                    Text(l.onlineNoPeers(isHost: model.isHost)).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("online.members.empty")
                }
                ForEach(model.lobbyPeers, id: \.trainerId) { member in
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
                if let peer = chosenPeer {
                    // The whole name, wrapped: the list row above may cut a long one, this line must not.
                    Text(l.onlineChallengeConfirm(opponent: peer.displayEmail ?? l.onlineAnonymous))
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("online.challenge.confirm")
                }
                Button(l.onlineChallenge) { model.send(.challenge) }
                    .buttonStyle(.borderedProminent).disabled(!model.canChallenge)
                    .accessibilityIdentifier("online.challenge")
                OnlineBattleBlockReason(block: model.challengeBlock, l: l, identifier: "online.challenge.reason")
                if model.selectedOpponentOffline {
                    Label(l.onlineOpponentOffline(model.selectedOpponent?.displayEmail), systemImage: "moon.zzz")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("online.challenge.offline")
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(l.onlineBattles).font(.subheadline.bold())
                if model.activeBattles.isEmpty { Text(l.onlineNoBattles).font(.caption).foregroundStyle(.secondary) }
                ForEach(model.activeBattles, id: \.battleId) { battle in
                    battleRow(battle, badge: rowBadges[battle.battleId])
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
            Button { model.send(.showStandings) } label: {
                HStack {
                    Label(l.onlineStandings, systemImage: "list.number")
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.caption)
                }
            }
            .buttonStyle(.plain).disabled(model.isBusy)
            .accessibilityIdentifier("online.standings.open")
            .practiceCard()
        }
    }
    /// The row keeps one height with or without a badge: the badge sits on the state line, and only its tint is extra.
    private func battleRow(_ battle: OnlineBattleView, badge: OnlineLobbyRowBadge?) -> some View {
        Button { model.send(.openBattle(battle.battleId)) } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(opponentName(battle)).font(.callout).lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 6) {
                        if let badge {
                            Text(l.onlineLobbyBadge(badge)).font(.caption2.bold()).foregroundStyle(.white)
                                .lineLimit(1).padding(.horizontal, 6)
                                .background(Capsule().fill(Self.color(badge)))
                                .accessibilityIdentifier("online.battle.badge.\(battle.battleId)")
                        }
                        Text(l.onlineRoomState(battle)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption)
            }
            .padding(6).contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 8).fill(badge.map { Self.color($0).opacity(0.12) } ?? Color.clear))
        }.buttonStyle(.plain).disabled(model.isBusy)
        .accessibilityIdentifier("online.battle.\(battle.battleId)")
    }
    private static func color(_ badge: OnlineLobbyRowBadge) -> Color {
        switch badge {
        case .received: .blue
        case .sent: .gray
        case .myTurn: .orange
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
                if let progress = model.roomProgress {
                    OnlineBattleRoomGuide(model: model, l: l, progress: progress)
                } else {
                    Text(l.onlineState(room.state)).font(.headline)
                }
                Text(room.mode == .manual ? l.onlineManual : l.onlineAuto).font(.caption).foregroundStyle(.secondary)
                // The step's button sits right under the guide so it is never below the scroll fold.
                if room.state == .pending && model.localSide == .p2 {
                    OnlineBattleRoster(model: model, l: l, artwork: artwork)
                }
                actions(room)
                publicEntry(room.p1, own: model.localSide == .p1)
                publicEntry(room.p2, own: model.localSide == .p2)
                Text(l.onlineNoLevelLimit).font(.caption).foregroundStyle(.secondary)
                Text(l.onlineHidden).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(l.onlineStakesHint).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    @ViewBuilder private func actions(_ room: OnlineBattleView) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if room.state == .pending && model.localSide == .p2 {
                HStack {
                    Button(l.onlineAccept) { model.send(.accept(room.battleId)) }.buttonStyle(.borderedProminent).disabled(!model.canAccept)
                        .accessibilityIdentifier("online.accept")
                    if model.roomExits.contains(.decline) {
                        Button(l.onlineDecline) { model.send(.decline(room.battleId)) }.disabled(model.isBusy)
                            .accessibilityIdentifier("online.decline")
                    }
                }
                OnlineBattleBlockReason(block: model.acceptBlock, l: l, identifier: "online.accept.reason")
            } else if room.state == .accepted && model.localSide == .p1 && !room.confirmed {
                Button(l.onlineConfirm) { model.send(.confirm(room.battleId)) }.buttonStyle(.borderedProminent).disabled(!model.canConfirm)
                    .accessibilityIdentifier("online.confirm")
                OnlineBattleBlockReason(block: model.isBusy ? .busy : nil, l: l, identifier: "online.confirm.reason")
            } else if room.confirmed && [.accepted, .ready].contains(room.state) {
                Button(model.localReady ? l.onlineOwnReady : l.onlinePrepare) { model.send(.prepareBattle(room.battleId)) }
                    .buttonStyle(.borderedProminent).disabled(!model.canPrepare)
                    .accessibilityIdentifier("online.prepare")
                OnlineBattleBlockReason(block: model.prepareBlock, l: l, identifier: "online.prepare.reason")
            } else if model.roomProgress == nil {
                Text(l.onlineWaiting).font(.caption).foregroundStyle(.secondary)
            }
            // Only the challenger sees "cancel request"; the receiver declines, or cancels the battle after accepting.
            if model.roomExits.contains(.cancelRequest) {
                Button(l.onlineCancel) { model.send(.cancel(room.battleId)) }.disabled(model.isBusy)
                    .accessibilityIdentifier("online.cancel")
            }
            if model.roomExits.contains(.cancelBattle) {
                Button(l.onlineCancelBattle) { model.send(.cancel(room.battleId)) }.disabled(model.isBusy)
                    .accessibilityIdentifier("online.cancelBattle")
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
