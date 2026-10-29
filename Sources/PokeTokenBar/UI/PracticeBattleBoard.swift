import SwiftUI

/// A running (or failed) practice battle: both sides, the staged beat with its callouts, the newest
/// beats, and the move grid. The session drives turns, deadlines and the playback clock; this view only
/// reads them and forwards choices. Without a playback it falls back to the battle's own view and log.
@MainActor
struct PracticeBattleBoard: View {
    @Bindable var session: PracticeSession
    let battle: PracticeBattle
    let l: L
    let artwork: Bool

    /// The one-shot "VS" splash at the start of a battle.
    @State private var splash = false

    private var automatic: Bool { session.mode == .automatic }
    private var playback: PracticePlayback? { session.playback }
    private var playing: Bool { playback?.isPlaying ?? false }
    private var wording: PracticeWording { PracticeWording(session: session, battle: battle, l: l) }

    var body: some View {
        // 8pt rhythm (not 10): the move hints and the speed row take the room the looser spacing had.
        VStack(alignment: .leading, spacing: 8) {
            if battle.phase == .failed {
                failure
                Spacer(minLength: 0)
            } else {
                if let view = battle.view {
                    VStack(alignment: .leading, spacing: 8) {
                        sideCard(.opponent, view.p2)
                        sideCard(.player, view.p1)
                    }
                    .overlay { if splash { versus.transition(.scale(scale: 1.6).combined(with: .opacity)) } }
                }
                stage
                prompt
                moveGrid
                Spacer(minLength: 0)
                controls
            }
        }
        .task(id: ObjectIdentifier(battle)) { await playSplash() }
    }

    // MARK: Sides

    /// While a beat plays the sides already show its outcome, so the bar drains, the number floats and
    /// the sprite reacts together; between beats they show the committed display.
    private func shown(_ side: PracticeSide) -> PracticeDisplaySide? {
        playback?.beat?.after[side] ?? playback?.display[side]
    }

    /// The id of the newest beat that hurt this side. It changes only when a new hit starts, so the
    /// shake plays once per hit even after the beat moves into the history.
    private func lastHit(_ side: PracticeSide) -> Int? {
        if let beat = playback?.beat, (beat.hpDelta[side] ?? 0) < 0 { return beat.id }
        return playback?.history.last { ($0.hpDelta[side] ?? 0) < 0 }?.id
    }

    private func sideCard(_ side: PracticeSide, _ pokemon: BattleView.Pokemon) -> some View {
        let own = side == .player
        let beat = playback?.beat
        return PracticeSideCard(side: pokemon, own: own, name: wording.name(side),
                                snapshot: own ? session.player?.snapshot : session.opponent?.snapshot,
                                l: l, artwork: artwork, display: shown(side),
                                beatID: beat?.id, delta: beat?.hpDelta[side], hitTrigger: lastHit(side),
                                reveal: own ? nil : stagedReveal)
    }

    /// What the staged beats have shown of the opponent so far (history plus the beat on screen). The
    /// engine's view is already at the end of the step, so it would reveal a move before its beat plays.
    /// nil without a playback: the view is then the only source.
    private var stagedReveal: PracticeReveal? {
        guard let playback else { return nil }
        let beats = playback.history + (playback.beat.map { [$0] } ?? [])
        var reveal = PracticeReveal()
        for beat in beats {
            if beat.actor == .opponent, let moveID = beat.moveID, moveID != "struggle", moveID != "recharge",
               !reveal.moves.contains(moveID) {
                reveal.moves.append(moveID)
            }
            for case .abilityRevealed(.opponent, let abilityID) in beat.callouts { reveal.ability = abilityID }
        }
        return reveal
    }

    private var versus: some View {
        Text(l.practiceVersus)
            .font(.system(size: 30, weight: .black, design: .rounded)).italic()
            .foregroundStyle(.white)
            .padding(.horizontal, 18).padding(.vertical, 2)
            .background(LinearGradient(colors: [.orange, .pink], startPoint: .leading, endPoint: .trailing),
                        in: Capsule())
            .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
            .allowsHitTesting(false)
    }

    /// Under a second, once per battle, before anything has played. The playback remembers it: reopening
    /// the popover rebuilds this view and would otherwise replay the splash.
    static func splashDue(phase: PracticeBattle.Phase, turn: Int?, introShown: Bool, played: Bool) -> Bool {
        phase == .running && turn == 1 && !introShown && !played
    }

    private func playSplash() async {
        guard let playback,
              Self.splashDue(phase: battle.phase, turn: battle.view?.turn, introShown: playback.introShown,
                             played: !playback.history.isEmpty || playback.beat != nil) else { return }
        playback.introShown = true
        withAnimation(.spring(duration: 0.25, bounce: 0.3)) { splash = true }
        try? await Task.sleep(for: .milliseconds(450))
        withAnimation(.easeIn(duration: 0.25)) { splash = false }
    }

    // MARK: Stage

    /// The beat on screen (action and callouts) over the three newest finished beats. Fixed height, so
    /// beats coming and going never move the move grid.
    private var stage: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let playback {
                current(playback)
                if !playback.recent.isEmpty {
                    Divider()
                    recent(playback)
                }
            } else {
                legacyTicker
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, minHeight: 92, maxHeight: 92, alignment: .topLeading)
        .practiceCard(padding: 8)
    }

    private func current(_ playback: PracticePlayback) -> some View {
        ZStack(alignment: .topLeading) {
            if let beat = playback.beat {
                VStack(alignment: .leading, spacing: 4) {
                    PracticePhraseText(phrase: wording.action(beat), l: l, artwork: artwork)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    chips(beat)
                }
                .id(beat.id)
                .transition(.asymmetric(insertion: .offset(x: -12).combined(with: .opacity), removal: .opacity))
            } else {
                Text(playback.history.isEmpty ? l.practiceBattleBegins : l.practiceTurn(battle.view?.turn ?? 1))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 38, alignment: .topLeading)
        .animation(.easeOut(duration: 0.2), value: playback.beat?.id)
    }

    /// Up to three chips; fewer when the localized words do not fit one line.
    private func chips(_ beat: PracticeBeat) -> some View {
        let callouts = wording.chips(beat)
        return ViewThatFits(in: .horizontal) {
            chipRow(callouts.prefix(3), beat)
            chipRow(callouts.prefix(2), beat)
            chipRow(callouts.prefix(1), beat)
        }
        .frame(minHeight: 18, alignment: .leading)
    }

    private func chipRow(_ callouts: ArraySlice<PracticeCallout>, _ beat: PracticeBeat) -> some View {
        HStack(spacing: 5) {
            ForEach(Array(callouts.enumerated()), id: \.offset) { _, callout in
                PracticeCalloutChip(phrase: wording.callout(callout, in: beat), tone: wording.tone(callout),
                                    l: l, artwork: artwork)
            }
        }
    }

    /// The three newest finished beats as sentences, newest first.
    private func recent(_ playback: PracticePlayback) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(playback.recent.prefix(3).enumerated()), id: \.element.id) { index, beat in
                PracticePhraseText(phrase: wording.sentence(beat), l: l, artwork: artwork)
                    .foregroundStyle(index == 0 ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: playback.recent.first?.id)
    }

    /// Without a playback: the three newest log lines, newest first. Turn separators are left out.
    private var legacyTicker: some View {
        let lines = Array(battle.messages.filter { !$0.hasPrefix("──") }.suffix(3).reversed())
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                Text(line)
                    .foregroundStyle(index == 0 ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    // MARK: Moves

    /// The engine's notice (a move that cannot be used) takes the prompt's place instead of a row of its own,
    /// so it never pushes the controls out of the fixed-height board.
    @ViewBuilder
    private var prompt: some View {
        HStack(alignment: .firstTextBaseline) {
            if playing {
                Text(l.practicePlayingTurn).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
            } else if let notice = battle.notice {
                Label(notice, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            } else if battle.isPaused {
                Text(l.practicePausedHint).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
            } else if automatic {
                Text(l.practiceAutoPlaying).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
            } else {
                Text(l.practiceWhatNext).font(.callout.weight(.semibold))
            }
            Spacer(minLength: 4)
            if playing, let playback {
                Button(l.practiceSkip) {
                    playback.skipToEnd()
                    session.tick()
                }
                .buttonStyle(.borderless)
                .font(.caption)
            } else if !battle.isPaused && !automatic && battle.notice == nil {
                Text(l.practiceKeyHint).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var moveGrid: some View {
        let moves = Array(battle.request.moves.prefix(4))
        return Group {
            if moves.isEmpty {
                Text(l.practiceWaitingTurn)
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 104)
                    .practiceCard()
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 6) {
                    ForEach(Array(moves.enumerated()), id: \.element.slot) { index, move in
                        PracticeMoveCard(move: move, key: index + 1, snapshot: session.player?.snapshot,
                                         hint: session.moveHint(move.id), l: l, artwork: artwork,
                                         locked: automatic || battle.isPaused || playing) {
                            session.choose(slot: move.slot)
                        }
                    }
                }
            }
        }
    }

    // MARK: Controls

    /// The speed row over the mode toggle and forfeit. Both rows keep their place in every state, so
    /// switching modes or finishing never moves the board: "Skip to result" only shows in automatic
    /// battles, and the toggle row hides once the battle has ended and only its last beats are playing.
    /// The speed stays usable until the last beat has played.
    private var controls: some View {
        VStack(spacing: 2) {
            HStack(spacing: 8) {
                speedPicker
                Spacer(minLength: 4)
                Button {
                    session.skipToResult()
                } label: {
                    Label(l.practiceSkipToResult, systemImage: "forward.end.fill")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .opacity(automatic && battle.phase == .running ? 1 : 0)
                .disabled(!automatic || battle.phase != .running)
            }
            HStack {
                Toggle(l.practiceSwitchToAuto, isOn: Binding(
                    get: { session.mode == .automatic },
                    set: { session.mode = $0 ? .automatic : .manual }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.caption)
                Spacer()
                Button(l.practiceForfeit, role: .destructive) { session.forfeit() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
            .opacity(battle.phase == .running ? 1 : 0)
            .disabled(battle.phase != .running)
        }
    }

    private var speedPicker: some View {
        Picker(l.practicePlaybackSpeed, selection: $session.playbackSpeed) {
            ForEach(PracticePlaybackSpeed.allCases, id: \.self) { speed in
                Text(l.practiceSpeedName(speed)).tag(speed)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.mini)
        .font(.caption)
        .fixedSize()
        .help(l.practicePlaybackSpeed)
    }

    private var failure: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(l.practiceBattleFailed, systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold)).foregroundStyle(.orange)
            if let notice = battle.notice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(l.practiceBackToSelection) { session.forfeit() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .practiceCard()
    }
}

/// One side of the battle: sprite, name and level, types, status, HP, and what is known about its
/// moves and ability. The opponent's HP is a percentage. With a playback, `display` overrides the
/// engine's HP and status, `delta` floats over the HP for the beat `beatID`, and `hitTrigger` shakes
/// the sprite once per new hit.
@MainActor
struct PracticeSideCard: View {
    let side: BattleView.Pokemon
    let own: Bool
    let name: String
    let snapshot: BattleSnapshot?
    let l: L
    let artwork: Bool
    var display: PracticeDisplaySide?
    var beatID: Int?
    var delta: Int?
    var hitTrigger: Int?
    /// The opponent's moves and ability as staged so far; nil reads them from the engine's view.
    var reveal: PracticeReveal?

    private var revealedMoves: [String] { reveal?.moves ?? side.moves }
    private var revealedAbility: String? {
        if let reveal { return reveal.ability }
        return side.ability
    }

    private var hp: Int { display?.hp ?? side.hp }
    private var maxHP: Int { display?.maxHP ?? side.maxhp }
    private var status: String { display.map { $0.status ?? "" } ?? side.status }
    private var fainted: Bool { display?.fainted ?? false }
    private var hpText: String {
        if own { return "\(hp)/\(maxHP)" }
        return l.practicePercent(display?.percent ?? side.hp)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                PracticeSpriteTile(set: snapshot?.set, size: 44, artwork: artwork)
                    .practiceFainted(fainted)
                    .practiceHitReaction(trigger: hitTrigger)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(own ? l.practiceYou : l.practiceFoe)
                            .font(.caption2).foregroundStyle(.secondary).fixedSize()
                        PracticeNameLevel(name: name, level: side.level)
                        PracticeTypeBadges(types: side.types, l: l, artwork: artwork).fixedSize()
                        Spacer(minLength: 0)
                        // Zero-width anchor: the number floats left of the status badge, above the HP bar.
                        Color.clear.frame(width: 0, height: 0).overlay(alignment: .trailing) { floating }
                        if !status.isEmpty {
                            Badge(l.practiceStatusName(status), tint: .orange, style: .tinted, size: 9)
                                .fixedSize()
                        }
                    }
                    HStack(spacing: 8) {
                        PracticeHPBar(hp: hp, maxHP: maxHP)
                        Text(hpText)
                            .font(.caption.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(fainted ? Color.secondary : Color.primary)
                            .frame(minWidth: 52, alignment: .trailing)
                    }
                }
            }
            if own { ownAbility } else { revealed }
        }
        .practiceCard(padding: 8)
    }

    /// The beat's HP change next to the name row, right above the HP bar; keyed by the beat so each
    /// beat plays it once.
    private var floating: some View {
        ZStack {
            if let beatID, let delta, delta != 0 {
                PracticeFloatingDelta(delta: delta, l: l)
                    .id(beatID)
                    .transition(PracticeFloatingDelta.transition)
            }
        }
        .animation(.easeOut(duration: 0.3), value: beatID)
        .allowsHitTesting(false)
    }

    private var ownAbility: some View {
        HStack(spacing: 5) {
            Text(l.practiceAbility).font(.caption2).foregroundStyle(.secondary)
            if let ability = side.ability ?? snapshot?.set.ability {
                PracticeChip {
                    PracticeMetadataName(kind: .ability, id: ability, snapshot: snapshot, l: l, artwork: artwork)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// Revealed moves plus "?" up to four, then the ability or "?". Wraps to two lines when the
    /// localized names do not fit one.
    private var revealed: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 5) { movesRow; abilityRow; Spacer(minLength: 0) }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) { movesRow; Spacer(minLength: 0) }
                HStack(spacing: 5) { abilityRow; Spacer(minLength: 0) }
            }
        }
    }

    private var movesRow: some View {
        HStack(spacing: 4) {
            Text(l.practiceMoves).font(.caption2).foregroundStyle(.secondary)
            ForEach(Array(revealedMoves.prefix(4)), id: \.self) { move in
                PracticeChip {
                    PracticeMetadataName(kind: .move, id: move, snapshot: snapshot, l: l, artwork: artwork)
                }
            }
            ForEach(0..<max(0, 4 - revealedMoves.count), id: \.self) { _ in
                PracticeChip(dimmed: true) { Text("?") }
            }
        }
    }

    private var abilityRow: some View {
        HStack(spacing: 4) {
            Text(l.practiceAbility).font(.caption2).foregroundStyle(.secondary)
            if let ability = revealedAbility {
                PracticeChip {
                    PracticeMetadataName(kind: .ability, id: ability, snapshot: snapshot, l: l, artwork: artwork)
                }
            } else {
                PracticeChip(dimmed: true) { Text("?") }
            }
        }
    }
}

/// A move button tinted with its type color, bound to the number key of its position. With a hint it adds
/// what a choice needs: power, accuracy and category, the type matchup against the foe's public types, and
/// STAB / priority markers. A card without a hint (Recharge, Struggle) keeps the same height.
@MainActor
struct PracticeMoveCard: View {
    let move: BattleMove
    let key: Int
    let snapshot: BattleSnapshot?
    var hint: PracticeMoveHint?
    let l: L
    let artwork: Bool
    /// Automatic mode or a paused battle: nothing to choose.
    let locked: Bool
    let action: () -> Void

    private var special: Bool { move.id == "recharge" || move.id == "struggle" }
    private var disabled: Bool { locked || move.disabled || (!special && move.pp <= 0) }
    private var tint: Color { PokemonType(apiName: move.type)?.color ?? .gray }
    private var priority: Bool { (hint?.info.priority ?? 0) > 0 }
    /// ×1 says nothing, so it has no badge.
    private var multiplier: Double? { hint?.multiplier.flatMap { $0 == 1 ? nil : $0 } }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    name.font(.callout.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8).layoutPriority(1)
                    Spacer(minLength: 2)
                    if let multiplier { PracticeEffectivenessBadge(multiplier: multiplier, l: l) }
                    Text("\(key)")
                        .font(.system(size: 9, weight: .bold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.secondary.opacity(0.4)))
                }
                // A long type name with both markers runs out of room first (FIGHTING + STAB + Priority in
                // English): the PP count drops its label, then Priority shrinks to the hare glyph the matchup's
                // speed line uses, and only then goes. The accessibility value always says all of it.
                ViewThatFits(in: .horizontal) {
                    badgeRow(ppLabel: true, priority: .text)
                    badgeRow(ppLabel: false, priority: .text)
                    badgeRow(ppLabel: false, priority: .glyph)
                    badgeRow(ppLabel: false, priority: .hidden)
                }
                Text(stats)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .opacity(hint == nil ? 0 : 1)
            }
            .padding(.horizontal, 7).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(0.4)))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
        .keyboardShortcut(KeyEquivalent(Character(String(key))), modifiers: [])
        .accessibilityLabel(l.practiceMoveLabel(key, move.name))
        .accessibilityValue(spoken)
    }

    private enum PriorityStyle { case text, glyph, hidden }

    /// The glyph row also tightens its gaps by a point: FIGHTING + STAB + hare + "30/30" needs 146 of 148pt.
    private func badgeRow(ppLabel: Bool, priority style: PriorityStyle) -> some View {
        HStack(spacing: style == .glyph ? 3 : 4) {
            if !move.type.isEmpty {
                PracticeTypeBadges(types: [move.type], l: l, artwork: artwork).fixedSize()
            }
            if hint?.info.variableType == true { PracticeMarker(text: l.practiceVariableType) }
            if hint?.stab == true { PracticeMarker(text: l.practiceStab) }
            if priority {
                switch style {
                case .text: PracticeMarker(text: l.practicePriority)
                case .glyph: PracticeMarker(symbol: "hare.fill")
                case .hidden: EmptyView()
                }
            }
            Spacer(minLength: 2)
            if !special {
                Text(ppLabel ? "PP \(move.pp)/\(move.maxpp)" : "\(move.pp)/\(move.maxpp)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(move.pp <= 0 ? Color.red : Color.secondary)
                    .fixedSize()
            }
        }
    }

    /// "Pow 90 · Acc 100 · Special", "Fixed damage · Acc 100 · Physical"; a blank line without a hint.
    /// Variable-power moves (Flail) report 0.
    private var stats: String {
        guard let info = hint?.info else { return " " }
        return l.practiceMoveStats(category: info.category, power: info.basePower > 0 ? info.basePower : nil,
                                   accuracy: info.accuracy, fixedDamage: info.fixedDamage)
    }

    private var spoken: String {
        guard let hint else { return "" }
        var parts = [stats, "PP \(move.pp)/\(move.maxpp)"]
        if hint.info.variableType { parts.append(l.practiceVariableType) }
        if let multiplier { parts.append(l.practiceMultiplier(multiplier)) }
        if hint.stab { parts.append(l.practiceStab) }
        if priority { parts.append(l.practicePriority) }
        return parts.joined(separator: l.practiceSeparator)
    }

    @ViewBuilder
    private var name: some View {
        switch move.id {
        case "recharge": Text(l.practiceRecharge)
        case "struggle": Text(l.practiceStruggle)
        default: PracticeMetadataName(kind: .move, id: move.id, snapshot: snapshot, l: l, artwork: artwork)
        }
    }
}

/// The opponent's moves (Showdown ids, first-use order) and ability as far as the playback has shown them.
struct PracticeReveal: Equatable {
    var moves: [String] = []
    var ability: String?
}
