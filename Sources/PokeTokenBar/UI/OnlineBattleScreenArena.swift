import SwiftUI

/// The live arena: the practice board's cards, beat lines and move picker, fed by the online battle's staged
/// display. Progress (advance, report, settlement) never waits for what is drawn here, so nothing in this view
/// locks a choice because a beat is playing. Both sides come through the seat frame and `OnlineBattleStaging`;
/// the engine view's `p1`/`p2` are never read directly.
@MainActor
struct OnlineBattleArena: View {
    let model: OnlineBattlePresentation
    let l: L
    let artwork: Bool
    var speciesNameProvider: any PokemonNameProviding = PokemonNameClient.shared
    var speciesNameStore: PokemonNameDisplayStore = .shared

    /// What fills the place under the beat lines.
    enum Footer: Equatable {
        /// The picker, open for a choice.
        case moves
        /// My choice is in; the picker stays but is locked.
        case sent
        /// Both sides play by policy.
        case automatic
        /// A terminal round's last beats play and the request is already gone.
        case waiting
        /// A required action the engine takes itself.
        case forced
    }

    /// The picker never waits for the beats: a move request shows moves while the turn plays.
    static func footer(mode: OnlineBattleMode, submitted: Bool, requestKind: String, playing: Bool) -> Footer {
        if mode == .auto { return .automatic }
        if submitted { return .sent }
        if requestKind == "move" { return .moves }
        return playing ? .waiting : .forced
    }

    static func showsSkipToResult(mode: OnlineBattleMode, playing: Bool) -> Bool { mode == .auto && playing }

    /// One height for every state, so the picker keeps its place and never drops out of the 520pt scroll area.
    /// The header, two cards (the foe's may wrap its chips to a second line), the beat lines, the prompt and the picker.
    static let boardHeight: CGFloat = 488
    private static let footerHeight: CGFloat = 122

    private var mode: OnlineBattleMode { model.room?.mode ?? .manual }
    private var playing: Bool { model.stage?.isPlaying ?? false }
    private var frame: BattleSeatFrame { model.stage?.frame ?? BattleSeatFrame(local: model.localSide) }
    private var footer: Footer {
        Self.footer(mode: mode, submitted: model.choiceSubmitted, requestKind: model.request?.kind ?? "none", playing: playing)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let view = model.arena {
                header(view)
                VStack(alignment: .leading, spacing: 6) {
                    sideCard(.opponent, view: view)
                    sideCard(.player, view: view)
                }
                beatLines(view)
                prompt(view)
                Spacer(minLength: 0)
                footerRegion
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, minHeight: Self.boardHeight, maxHeight: Self.boardHeight, alignment: .top)
        .task(id: nameKey) { await loadSpeciesNames() }
    }

    /// Fills the shared name cache for both species, so the cards and the beat lines speak the app's language.
    private func loadSpeciesNames() async {
        guard let view = model.arena else { return }
        await speciesName(.player, view: view).load()
        await speciesName(.opponent, view: view).load()
    }

    private var nameKey: [String] {
        guard let view = model.arena else { return [] }
        return [PracticeSide.player, .opponent].map { frame.pokemon($0, in: view).species }
    }

    // MARK: Header

    private func header(_ view: BattleView) -> some View {
        HStack {
            Text(mode == .auto ? l.onlineAutomatic : l.onlineManual).font(.subheadline.bold())
            Spacer(minLength: 4)
            // The server's clock keeps running while beats play; hiding the screen never pauses it.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = Self.remainingSeconds(deadline: model.deadline, now: context.date)
                Text(l.onlineTurn(shownTurn(view), seconds: remaining)).font(.caption).monospacedDigit()
                    .foregroundStyle(remaining <= 5 ? Color.orange : Color.secondary)
            }
        }
    }

    /// The turn of the beat on screen; the view is already at the next turn while its beats still play.
    func shownTurn(_ view: BattleView) -> Int { model.stage?.playback.beat?.turn ?? view.turn }

    /// Dates come from the server's millisecond deadline via the session; hiding the screen never pauses it.
    static func remainingSeconds(deadline: Date?, now: Date) -> Int {
        guard let deadline else { return 0 }
        return max(0, Int(ceil(deadline.timeIntervalSince(now))))
    }

    // MARK: Sides

    private var ownSnapshot: BattleSnapshot? {
        guard let room = model.room else { return nil }
        return (model.localSide == .p1 ? room.p1 : room.p2).snapshot?.displaySnapshot
    }

    private func speciesName(_ side: PracticeSide, view: BattleView) -> OnlineBattleSpeciesNameLevel {
        let pokemon = frame.pokemon(side, in: view)
        return OnlineBattleSpeciesNameLevel(speciesNum: pokemon.speciesNum, publicName: pokemon.species, level: pokemon.level,
                                            language: l.lang, provider: speciesNameProvider, displayStore: speciesNameStore,
                                            loadsNames: artwork)
    }

    /// The newest beat that hurt this side. It changes only when a new hit starts, so the sprite shakes once per hit.
    private func lastHit(_ side: PracticeSide) -> Int? {
        guard let playback = model.stage?.playback else { return nil }
        if let beat = playback.beat, (beat.hpDelta[side] ?? 0) < 0 { return beat.id }
        return playback.history.last { ($0.hpDelta[side] ?? 0) < 0 }?.id
    }

    /// Internal and concrete so tests can check which individual each side shows.
    func sideCard(_ side: PracticeSide, view: BattleView) -> PracticeSideCard {
        let own = side == .player, staging = model.stage, seat = frame.seat(side)
        let pokemon = frame.pokemon(side, in: view), beat = staging?.playback.beat
        // The view is ahead of the beats on screen, so while they play the opponent shows only what they showed.
        let reveal: PracticeReveal? = own || staging?.isPlaying != true ? nil : staging.map { PracticeReveal(staged: $0.playback) }
        return PracticeSideCard(side: pokemon, own: own, name: speciesName(side, view: view).displayName,
                                snapshot: own ? ownSnapshot : nil, l: l, artwork: artwork,
                                display: staging?.shown(side) ?? OnlineBattleStaging.resting(pokemon),
                                beatID: beat?.id, delta: beat?.hpDelta[side], hitTrigger: lastHit(side), reveal: reveal,
                                moveSlugs: model.moveSlugs[seat] ?? [:], abilitySlugs: model.abilitySlugs[seat] ?? [:],
                                spriteSpecies: pokemon.speciesNum)
    }

    /// Names and slugs the beat lines speak with; the opponent's set is never part of it.
    var wording: PracticeWording {
        let view = model.arena
        let own = frame.seat(.player), other = frame.seat(.opponent)
        return PracticeWording(l: l,
                               playerName: view.map { speciesName(.player, view: $0).displayName } ?? "",
                               opponentName: view.map { speciesName(.opponent, view: $0).displayName } ?? "",
                               playerSnapshot: ownSnapshot,
                               moveSlugs: [.player: model.moveSlugs[own] ?? [:], .opponent: model.moveSlugs[other] ?? [:]],
                               abilitySlugs: [.player: model.abilitySlugs[own] ?? [:], .opponent: model.abilitySlugs[other] ?? [:]])
    }

    // MARK: Beat lines

    /// The beat on screen over the newest finished ones, newest first. The card takes the room the board has left
    /// (three finished lines at least, five at most), so the picker below it keeps its place.
    private func beatLines(_ view: BattleView) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let playback = model.stage?.playback {
                let idle = playback.history.isEmpty && mode == .manual ? l.practiceBattleBegins : l.practiceTurn(shownTurn(view))
                ViewThatFits(in: .vertical) {
                    PracticeBeatLines(playback: playback, wording: wording, idle: idle, l: l, artwork: artwork, recentCount: 5)
                    PracticeBeatLines(playback: playback, wording: wording, idle: idle, l: l, artwork: artwork, recentCount: 4)
                    PracticeBeatLines(playback: playback, wording: wording, idle: idle, l: l, artwork: artwork, recentCount: 3)
                }
            } else {
                Text(mode == .manual ? l.practiceBattleBegins : l.practiceTurn(view.turn))
                    .font(.callout.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, minHeight: 92, maxHeight: .infinity, alignment: .topLeading)
        .practiceCard(padding: 8)
    }

    // MARK: Prompt and picker

    private func prompt(_ view: BattleView) -> some View {
        HStack(alignment: .firstTextBaseline) {
            switch footer {
            case .sent:
                Label(l.onlineChoiceSent, systemImage: "checkmark.circle").font(.callout.weight(.semibold))
            case .moves:
                Text(playing ? l.practicePlayingTurn : l.practiceWhatNext)
                    .font(.callout.weight(.semibold)).foregroundStyle(playing ? Color.secondary : Color.primary)
            case .automatic:
                Text(playing ? l.practicePlayingTurn : l.practiceAutoPlaying).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
            case .waiting:
                Text(l.practicePlayingTurn).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
            case .forced:
                Text(l.onlineForced).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 4)
            if playing {
                Button(l.practiceSkip) { model.send(.skipStage) }
                    .buttonStyle(.borderless).font(.caption)
                    .accessibilityIdentifier("online.skip")
            } else if footer == .moves {
                Text(l.practiceKeyHint).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 20)
    }

    private var footerRegion: some View {
        Group {
            switch footer {
            case .moves, .sent:
                if let moves = model.request?.moves.prefix(4), !moves.isEmpty { moveGrid(Array(moves)) } else { waitingCard }
            case .automatic:
                automaticCard
            case .waiting, .forced:
                waitingCard
            }
        }
        .frame(maxWidth: .infinity, minHeight: Self.footerHeight, maxHeight: Self.footerHeight, alignment: .top)
    }

    /// Only the battle's own rules lock a move card. A beat playing does not (D6): the server's clock keeps
    /// running and the choice may be made while the last turn is still on screen.
    func movesLocked(_ slot: Int) -> Bool { !model.canChooseMove(slot) }

    func moveChosen(_ slot: Int) -> Bool { false }

    private func moveGrid(_ moves: [BattleMove]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 6) {
            ForEach(moves) { move in
                PracticeMoveCard(move: namedMove(move), key: move.slot, snapshot: ownSnapshot, l: l, artwork: artwork,
                                 locked: movesLocked(move.slot)) {
                    model.send(.chooseMove(move.slot))
                }
                .accessibilityIdentifier("online.move.\(move.slot)")
            }
        }
    }

    private var waitingCard: some View {
        Text(footer == .forced ? l.onlineForced : l.practiceWaitingTurn)
            .font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .practiceCard()
            .frame(height: Self.footerHeight)
    }

    /// The result button keeps its place at rest, so the card never changes size when the beats end.
    private var automaticCard: some View {
        VStack(spacing: 10) {
            Label(l.onlineAutomatic, systemImage: "play.fill").font(.callout).foregroundStyle(.secondary)
            Button { model.send(.skipStage) } label: {
                Label(l.practiceSkipToResult, systemImage: "forward.end.fill").labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderless).font(.caption)
            .accessibilityIdentifier("online.skipToResult")
            .opacity(Self.showsSkipToResult(mode: mode, playing: playing) ? 1 : 0)
            .disabled(!Self.showsSkipToResult(mode: mode, playing: playing))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .practiceCard()
        .frame(height: Self.footerHeight)
    }

    private func metadataSlug(_ id: String) -> String { model.moveSlugs[model.localSide]?[id] ?? id }

    private func namedMove(_ move: BattleMove) -> BattleMove {
        .init(slot: move.slot, id: metadataSlug(move.id), name: move.name, type: move.type,
              pp: move.pp, maxpp: move.maxpp, disabled: move.disabled)
    }
}
