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
    /// Where VoiceOver announcements go; tests record them.
    var announce: @MainActor (String) -> Void = { AccessibilityNotification.Announcement($0).post() }

    /// Says the turn start when it is due (see `OnlineBattlePresentation.claimTurnAnnouncement`).
    func announceTurnIfDue(now: Date = .now) {
        guard let line = model.claimTurnAnnouncement(l: l, pickerOpen: turnIsOpen, playing: playing, now: now) else { return }
        announce(line)
    }

    /// Everything that can make a turn due or not: a new turn or room, the picker opening, the beats ending, the
    /// screen being shown. A deadline or an HP change is not among them.
    private struct TurnCue: Equatable {
        let battleID: String?
        let turn: Int?
        let open: Bool
        let playing: Bool
        let shown: Bool
    }
    private var turnCue: TurnCue {
        TurnCue(battleID: model.room?.battleId, turn: model.arena?.turn, open: turnIsOpen, playing: playing, shown: model.screenShown)
    }
    /// The picker is open and the server's clock runs for it. The picker alone is open between rounds too (D6).
    private var turnIsOpen: Bool { footer == .moves && model.roundIsOpen }

    /// What fills the place under the beat lines.
    enum Footer: Equatable {
        /// The picker, open for a choice.
        case moves
        /// My choice is in; the picker stays but is locked.
        case sent
        /// Both sides play by policy.
        case automatic
        /// Beats play and the live request has no moves (the last round's, or the round before a forced turn). The last
        /// move request stays on the cards, locked, so the picker does not tell what the beats have not shown yet.
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
    static let footerHeight: CGFloat = 122

    private var mode: OnlineBattleMode { model.room?.mode ?? .manual }
    private var playing: Bool { model.stage?.isPlaying ?? false }
    private var frame: BattleSeatFrame { model.stage?.frame ?? BattleSeatFrame(local: model.localSide) }
    private var footer: Footer {
        Self.footer(mode: mode, submitted: model.choiceSubmitted, requestKind: model.request?.kind ?? "none", playing: playing)
    }
    /// The opening mark is drawn state of this view; the staging remembers that it was shown.
    @State private var splash = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let view = model.arena {
                header(view)
                VStack(alignment: .leading, spacing: 6) {
                    sideCard(.opponent, view: view)
                    sideCard(.player, view: view)
                }
                .overlay {
                    if splash {
                        OnlineBattleVersus(l: l, nickname: model.opponentNickname) { dismissSplash() }
                            .transition(.scale(scale: 1.15).combined(with: .opacity))
                    }
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
        .task(id: model.arena != nil) { await playSplash() }
        // A choice, or a beat starting, means the battle is under way: the mark has done its job.
        .onChange(of: playing) { _, now in if now { dismissSplash() } }
        .onChange(of: model.choiceSubmitted) { _, now in if now { dismissSplash() } }
        // VoiceOver hears a turn open once, on a screen that is shown, after the beats on screen have ended.
        .onChange(of: turnCue, initial: true) { announceTurnIfDue() }
    }

    // MARK: Splash

    /// Once per battle, before anything has played and on the first turn. A battle already under way when the screen
    /// opens (a reopened popover, a returning app) never gets it.
    static func splashDue(turn: Int?, introShown: Bool, played: Bool) -> Bool {
        PracticeBattleBoard.splashDue(phase: .running, turn: turn, introShown: introShown, played: played)
    }

    /// True when the splash is due, and records that it was shown so a view built later does not show it again.
    func claimSplash() -> Bool {
        guard let playback = model.stage?.playback,
              Self.splashDue(turn: model.arena?.turn, introShown: playback.introShown,
                             played: !playback.history.isEmpty || playback.beat != nil) else { return false }
        playback.introShown = true
        return true
    }

    /// Three seconds or so: the spring in, a pause, the fade out. A press, a choice or a beat clears it sooner.
    private func playSplash() async {
        guard claimSplash() else { return }
        withAnimation(.spring(duration: 0.25, bounce: 0.3)) { splash = true }
        try? await Task.sleep(for: .milliseconds(2_500))
        dismissSplash()
    }

    private func dismissSplash() {
        guard splash else { return }
        withAnimation(.easeIn(duration: 0.3)) { splash = false }
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
        // The server's clock keeps running while beats play; hiding the screen never pauses it.
        OnlineBattleClockBand(title: mode == .auto ? l.onlineAutomatic : l.onlineManual, l: l, mode: mode, footer: footer,
                              deadline: model.deadline, playing: playing, stagedTurn: shownTurn(view), viewTurn: choosingTurn(view))
    }

    /// The state the bar is in at `now`, from the model alone. Internal so tests can read it.
    func turnClock(now: Date) -> OnlineBattleTurnClock.State {
        OnlineBattleTurnClock.state(mode: mode, footer: footer, deadline: model.deadline, playing: playing, now: now)
    }

    /// The turn the header names: the seconds belong to the turn being chosen, which the beats on screen have not
    /// reached yet. With no clock the turn on screen is the beat's.
    func clockTurn(_ view: BattleView, state: OnlineBattleTurnClock.State) -> Int { state == .idle ? shownTurn(view) : choosingTurn(view) }

    /// The turn after the beat on screen. The engine's turn stops at the last round, and a header that stopped with it
    /// would tell the match is over before the beats do.
    private func choosingTurn(_ view: BattleView) -> Int { playing ? max(view.turn, shownTurn(view) + 1) : view.turn }

    /// The turn of the beat on screen; the view is already at the next turn while its beats still play.
    func shownTurn(_ view: BattleView) -> Int { model.stage?.playback.beat?.turn ?? view.turn }

    /// Dates come from the server's millisecond deadline via the session; hiding the screen never pauses it.
    /// nil when the server has given none yet: that is not zero seconds.
    static func remainingSeconds(deadline: Date?, now: Date) -> Int? {
        guard let deadline else { return nil }
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
        // What the card draws, and so what VoiceOver says: never the view that is already ahead of the beats.
        let display = staging?.shown(side) ?? OnlineBattleStaging.resting(pokemon)
        let name = speciesName(side, view: view).displayName
        // The view is ahead of the beats on screen, so while they play the opponent shows only what they showed.
        let reveal: PracticeReveal? = own || staging?.isPlaying != true ? nil : staging.map { PracticeReveal(staged: $0.playback) }
        return PracticeSideCard(side: pokemon, own: own, name: name,
                                snapshot: own ? ownSnapshot : nil, l: l, artwork: artwork,
                                display: display,
                                beatID: beat?.id, delta: beat?.hpDelta[side], hitTrigger: lastHit(side), reveal: reveal,
                                moveSlugs: model.moveSlugs[seat] ?? [:], abilitySlugs: model.abilitySlugs[seat] ?? [:],
                                spriteSpecies: pokemon.speciesNum,
                                label: own ? nil : model.opponentNickname.map { l.onlineFoeLabel(nickname: $0) },
                                caption: own ? nil : l.onlineOpponentLine(record: model.opponentRecord, streak: model.opponentStreak) ?? " ",
                                spoken: OnlineBattleSpoken.card(l: l, own: own, name: name, level: pokemon.level,
                                                                nickname: own ? nil : model.opponentNickname, display: display))
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
    /// (one finished line at least, five at most), so the picker below it keeps its place. The tallest foe card with
    /// its nickname, record and wrapped move chips leaves room for the one line only.
    private func beatLines(_ view: BattleView) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let playback = model.stage?.playback {
                let idle = playback.history.isEmpty && mode == .manual ? l.practiceBattleBegins : l.practiceTurn(shownTurn(view))
                ViewThatFits(in: .vertical) {
                    PracticeBeatLines(playback: playback, wording: wording, idle: idle, l: l, artwork: artwork, recentCount: 5)
                    PracticeBeatLines(playback: playback, wording: wording, idle: idle, l: l, artwork: artwork, recentCount: 4)
                    PracticeBeatLines(playback: playback, wording: wording, idle: idle, l: l, artwork: artwork, recentCount: 3)
                    PracticeBeatLines(playback: playback, wording: wording, idle: idle, l: l, artwork: artwork, recentCount: 2)
                    PracticeBeatLines(playback: playback, wording: wording, idle: idle, l: l, artwork: artwork, recentCount: 1)
                }
            } else {
                Text(mode == .manual ? l.practiceBattleBegins : l.practiceTurn(view.turn))
                    .font(.callout.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, minHeight: 56, maxHeight: .infinity, alignment: .topLeading)
        .practiceCard(padding: 8)
    }

    // MARK: Prompt and picker

    private func prompt(_ view: BattleView) -> some View {
        HStack(alignment: .firstTextBaseline) {
            switch footer {
            case .sent:
                Label(l.onlineChoiceDone, systemImage: "checkmark.circle").font(.callout.weight(.semibold)).fixedSize()
                // One line inside the board's fixed height; the grid below keeps the picked card marked.
                waitLine
            case .moves:
                Text(movePrompt)
                    .font(.callout.weight(.semibold)).foregroundStyle(turnIsOpen && !playing ? Color.primary : Color.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
                // Only the fact that the other side is done shows while I still choose; it never says what they chose.
                if model.opponentWait == .submitted { waitLine }
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
            } else if turnIsOpen, model.opponentWait != .submitted {
                // The key hint is the first thing to go when the other side's news needs the room.
                Text(l.practiceKeyHint).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 20)
    }

    /// What the other side is doing: quiet while they think, accented when they are done, orange when they are gone.
    @ViewBuilder private var waitLine: some View {
        if let wait = model.opponentWait {
            Text(l.onlineOpponentWait(wait)).font(.caption)
                .foregroundStyle(wait == .choosing ? Color.secondary : wait == .submitted ? Color.accentColor : Color.orange)
                .lineLimit(2).minimumScaleFactor(0.85).layoutPriority(1)
                .accessibilityIdentifier("online.opponentWait")
        }
    }

    private var footerRegion: some View {
        Group {
            switch footer {
            case .moves, .sent:
                if let moves = model.request?.moves.prefix(4), !moves.isEmpty { moveGrid(Array(moves)) } else { waitingCard }
            case .automatic:
                automaticCard
            case .waiting:
                if waitingMoves.isEmpty { waitingCard } else { moveGrid(waitingMoves) }
            case .forced:
                waitingCard
            }
        }
        .frame(maxWidth: .infinity, minHeight: Self.footerHeight, maxHeight: Self.footerHeight, alignment: .top)
    }

    /// Only the battle's own rules lock a move card. A beat playing does not (D6): the server's clock keeps
    /// running and the choice may be made while the last turn is still on screen.
    func movesLocked(_ slot: Int) -> Bool { !model.canChooseMove(slot) }

    /// The line over an open picker.
    var movePrompt: String {
        if model.heldChoice != nil { return l.onlineChoiceHeld }
        if playing { return l.practicePlayingTurn }
        return model.roundIsOpen ? l.practiceWhatNext : l.onlineRoundOpening
    }

    /// The cards drawn, locked, while beats play and the live request has no moves. They come from the last move request.
    var waitingMoves: [BattleMove] { footer == .waiting ? Array((model.stage?.lastMoveRequest?.moves ?? []).prefix(4)) : [] }

    /// The card of the choice that is already in; nil slot means nothing is marked.
    func moveChosen(_ slot: Int) -> Bool { model.chosenSlot == slot }

    private func moveGrid(_ moves: [BattleMove]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 6) {
            ForEach(moves) { move in
                moveCard(move)
                    .accessibilityIdentifier("online.move.\(move.slot)")
            }
        }
    }

    /// Internal and concrete so tests can check what each card is given.
    func moveCard(_ move: BattleMove) -> PracticeMoveCard {
        PracticeMoveCard(move: namedMove(move), key: move.slot, snapshot: ownSnapshot,
                         hint: footer == .waiting ? model.stage?.lastMoveHints[move.slot] : model.moveHints[move.slot],
                         l: l, artwork: artwork, locked: movesLocked(move.slot), chosen: moveChosen(move.slot)) {
            model.send(.chooseMove(move.slot))
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
