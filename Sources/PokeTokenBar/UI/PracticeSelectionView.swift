import SwiftUI

/// Practice selection: the record line, my entry (changeable inline), then the opponents — today's opponent
/// with its goals, level-matched wild ones, my own below — as one radio list with a paired stat comparison on
/// the selected row, unavailable Pokémon, the mode, and the start button. The list scrolls; the mode and the
/// start button stay pinned at the bottom of the 520pt body.
@MainActor
struct PracticeSelectionView: View {
    @Bindable var session: PracticeSession
    /// The record line and today's opponent; `PracticeScreen` passes the session's values.
    let progress: PracticeSelectionProgress
    let l: L
    let artwork: Bool
    @State private var changingPlayer = false

    private var eligible: [PracticeCandidate] { session.roster?.eligible ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    PracticeRecordsLine(records: progress.records, l: l)
                    playerCard
                    if let error = session.loadError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // No roster yet: `prepare` runs synchronously on appear, so there is nothing to wait for
                    // (and no spinner — the popover avoids open-ended animations). One entry is enough now:
                    // the wild section supplies the opponent.
                    if session.roster != nil, session.player == nil {
                        Label(l.practiceNeedsEntry, systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .practiceCard()
                    } else if session.roster != nil {
                        Text(l.practiceOpponentCaption)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        dailySection
                        wildSection
                        ownedSection
                    }
                    blockedSection
                }
                .reservesScrollerLane()
            }
            modeSection
            Button { session.start() } label: {
                Text(l.practiceStartBattle)
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(session.player == nil || session.opponent == nil)
        }
        // Wild opponents are matched to the entry's level: search whenever one is due — idle with a player —
        // rather than on particular transitions. After a release the same player can come back through
        // `prepare` with no player or state change to observe, and the search must still start.
        .onChange(of: wildSearchDue, initial: true) { _, due in
            if due { session.findWildOpponents() }
        }
    }

    private var wildSearchDue: Bool { session.wildState == .idle && session.player != nil }

    // MARK: My entry

    private var playerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                PracticeSpriteTile(set: session.player?.snapshot?.set, size: 44, artwork: artwork)
                VStack(alignment: .leading, spacing: 3) {
                    Text(l.practicePlayer).font(.caption2).foregroundStyle(.secondary)
                    if let player = session.player, let snapshot = player.snapshot {
                        PracticeNameLevel(name: player.name, level: snapshot.set.level)
                        PracticeTypeBadges(types: snapshot.publicInfo.types, l: l, artwork: artwork)
                    } else {
                        Text(l.practiceChoose).font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                if eligible.count >= 2 {
                    Button(l.practiceChange) { changingPlayer.toggle() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
            if changingPlayer {
                VStack(spacing: 4) {
                    ForEach(eligible.filter { $0.id != session.playerID }) { candidate in
                        Button { choosePlayer(candidate.id) } label: {
                            compactRow(candidate)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .practiceCard()
    }

    /// Picking my current opponent as my entry swaps the two, so the pair stays valid. A new entry drops the
    /// wild opponents matched to the old one; a wild pick that went with them falls back to one of my own.
    private func choosePlayer(_ id: String) {
        if id == session.opponentID { session.opponentID = session.playerID }
        session.playerID = id
        if session.opponent == nil { session.opponentID = eligible.first { $0.id != id }?.id }
        changingPlayer = false
    }

    private func compactRow(_ candidate: PracticeCandidate) -> some View {
        HStack(spacing: 8) {
            PracticeSpriteTile(set: candidate.snapshot?.set, size: 28, artwork: artwork)
            PracticeNameLevel(name: candidate.name, level: candidate.snapshot?.set.level ?? 0, font: .caption.weight(.semibold))
            PracticeTypeBadges(types: candidate.snapshot?.publicInfo.types ?? [], l: l, artwork: artwork)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    // MARK: Opponents

    /// The entry's level ±3 within the app's 5...100, the band the wild search draws from.
    static func wildLevels(around level: Int) -> ClosedRange<Int> {
        let low = min(100, max(5, level - 3)), high = max(5, min(100, level + 3))
        return low...high
    }

    /// Today's opponent with today's stars (the session keeps only today's). It comes from the same search as the
    /// wild opponents, so its retry is that search.
    private var dailySection: some View {
        PracticeDailyCard(candidate: progress.daily, state: progress.dailyState, stars: progress.todayStars,
                          l: l, onRetry: { session.findWildOpponents() }) { candidate in
            opponentRow(candidate, number: nil)
        }
    }

    /// Level-matched wild opponents, made in memory by the hatch rule: a header with the level band and a
    /// reroll, then the search state or the three candidates.
    @ViewBuilder
    private var wildSection: some View {
        if let level = session.player?.snapshot?.set.level {
            let band = Self.wildLevels(around: level)
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        sectionTitle(l.practiceWildHeader(low: band.lowerBound, high: band.upperBound))
                        Spacer(minLength: 4)
                        if session.wildState == .ready {
                            Button { session.findWildOpponents() } label: {
                                Label(l.practiceWildReroll, systemImage: "arrow.triangle.2.circlepath")
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .fixedSize()
                        }
                    }
                    // Describes the candidates, so it waits for them; the header's band says enough before.
                    if session.wildState == .ready {
                        Text(l.practiceWildHint)
                            .font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1).minimumScaleFactor(0.85)
                    }
                }
                switch session.wildState {
                case .ready:
                    VStack(spacing: 6) {
                        ForEach(session.wildCandidates) { candidate in
                            opponentRow(candidate, number: nil)
                        }
                    }
                case .idle, .searching:
                    wildNotice {
                        // The only spinner on the screen, and only while a search is in flight.
                        if session.wildState == .searching {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "leaf").foregroundStyle(.secondary)
                        }
                        Text(l.practiceWildSearching).foregroundStyle(.secondary)
                    }
                case .unavailable:
                    wildNotice {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        // Two lines at most keep my own opponents in view; the tooltip has the rest.
                        Text(l.practiceWildUnavailable).foregroundStyle(.secondary)
                            .lineLimit(2)
                            .help(l.practiceWildUnavailable)
                        Spacer(minLength: 4)
                        Button(l.retry) { session.findWildOpponents() }
                            .buttonStyle(.borderless)
                            .fixedSize()
                    }
                }
            }
        }
    }

    /// A one-line row in place of the wild candidates while they are missing.
    private func wildNotice<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) {
            content()
            Spacer(minLength: 0)
        }
        .font(.caption)
        .padding(.horizontal, 8).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    /// My own Pokémon as opponents. Their numbers follow the roster, so they match the Home list.
    @ViewBuilder
    private var ownedSection: some View {
        let owned = eligible.enumerated().filter { $0.element.id != session.playerID }
        if !owned.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle(l.practiceOwnedHeader)
                ForEach(owned, id: \.element.id) { index, candidate in
                    opponentRow(candidate, number: index + 1)
                }
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
    }

    /// One opponent row; selected, it opens the paired stats and the matchup card under it.
    private func opponentRow(_ candidate: PracticeCandidate, number: Int?) -> some View {
        let selected = candidate.id == session.opponentID
        return PracticeOpponentRow(candidate: candidate, temperament: candidate.temperament, selected: selected,
                                   number: number, l: l, artwork: artwork,
                                   onSelect: { session.opponentID = candidate.id }) {
            if selected, let mine = session.player?.snapshot?.publicInfo.stats,
               let theirs = candidate.snapshot?.publicInfo.stats {
                PracticeStatComparison(mine: mine, theirs: theirs, l: l)
                if let matchup = session.matchup {
                    PracticeMatchupCard(matchup: matchup, playerSnapshot: session.player?.snapshot,
                                        playerLevel: session.player?.snapshot?.set.level ?? 0,
                                        opponentLevel: candidate.snapshot?.set.level ?? 0, l: l, artwork: artwork)
                }
                Text(l.practiceRevealHint).font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var blockedSection: some View {
        let blocked = session.roster?.candidates.filter { $0.snapshot == nil } ?? []
        if !blocked.isEmpty {
            DisclosureGroup(l.practiceBlocked(blocked.count)) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(blocked) { row in
                        Text("\(row.name) — \(row.blockedReason ?? l.practiceMissingInfo)")
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, 4)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: Mode

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(l.practiceMode, selection: $session.mode) {
                Text(l.practiceManualPerTurn(PracticeBattle.manualTurnSeconds)).tag(PracticeBattle.Mode.manual)
                Text(l.practiceAuto).tag(PracticeBattle.Mode.automatic)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(session.mode == .manual ? l.practiceAutoPickHint : l.practiceAutoModeHint)
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// One opponent in the selection list (owned, wild and today's): a radio, the sprite, then the name and level over
/// the types and the temperament. A wild one adds its shininess and rarity to the name and the wild tag to the
/// types, the way Home's companion header shows them. Selected, `detail` opens under it.
@MainActor
struct PracticeOpponentRow<Detail: View>: View {
    let candidate: PracticeCandidate
    /// The tag next to the types (`PracticeCandidate.temperament`); nil hides it.
    let temperament: PracticeTemperament?
    let selected: Bool
    var number: Int?
    let l: L
    let artwork: Bool
    let onSelect: () -> Void
    let detail: Detail

    init(candidate: PracticeCandidate, temperament: PracticeTemperament?, selected: Bool, number: Int? = nil,
         l: L, artwork: Bool, onSelect: @escaping () -> Void, @ViewBuilder detail: () -> Detail) {
        self.candidate = candidate; self.temperament = temperament; self.selected = selected; self.number = number
        self.l = l; self.artwork = artwork; self.onSelect = onSelect; self.detail = detail()
    }

    var body: some View {
        let font: Font = .callout.weight(selected ? .semibold : .regular)
        return VStack(alignment: .leading, spacing: 8) {
            Button(action: onSelect) {
                HStack(spacing: 8) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    PracticeSpriteTile(set: candidate.snapshot?.set, size: 32, artwork: artwork)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            PracticeNameLevel(name: candidate.name, level: candidate.snapshot?.set.level ?? 0, font: font)
                            if let wild = candidate.origin.wildTraits {
                                if wild.shiny { Text("✨").font(.system(size: 11)) }
                                Badge(l.rarityLabel(wild.rarity).uppercased(), tint: .rarity(wild.rarity)).fixedSize()
                            }
                        }
                        // The name truncates first; on this line the temperament drops to its symbol before a type
                        // badge would be cut.
                        ViewThatFits(in: .horizontal) {
                            tags(compact: false)
                            tags(compact: true)
                        }
                    }
                    Spacer(minLength: 4)
                    if let number {
                        Text("#\(number)").font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if selected { detail }
        }
        .padding(8)
        .background(selected ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(selected ? Color.accentColor.opacity(0.35) : Color.clear))
    }

    private func tags(compact: Bool) -> some View {
        HStack(spacing: 5) {
            PracticeTypeBadges(types: candidate.snapshot?.publicInfo.types ?? [], l: l, artwork: artwork).fixedSize()
            if candidate.origin.wildTraits != nil { PracticeWildTag(l: l) }
            PracticeTemperamentTag(temperament: temperament, l: l, compact: compact)
        }
    }
}

/// What the pairing means for the selected opponent, from public information only: my best hit on its
/// types, its types against mine, who moves first by Speed, and a warning for a big level gap. It never
/// names the opponent's moves or ability.
@MainActor
struct PracticeMatchupCard: View {
    let matchup: PracticeMatchup
    let playerSnapshot: BattleSnapshot?
    let playerLevel: Int
    let opponentLevel: Int
    let l: L
    let artwork: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row(reach == .none || reach == .immune ? "exclamationmark.octagon.fill" : "scope", tint: reach.iconTint) {
                PracticePhraseText(phrase: offense, l: l, artwork: artwork)
                    .foregroundStyle(reach.textTint)
            }
            row("shield.lefthalf.filled", tint: threatTint) {
                Text(l.practiceThreat(l.practiceMultiplier(matchup.threat)))
                    .foregroundStyle(matchup.threat == 1 ? Color.primary : threatTint)
            }
            row("hare.fill", tint: orderTint) {
                Text(l.practiceOrder(matchup.order, mine: matchup.playerSpeed, theirs: matchup.opponentSpeed))
                    .monospacedDigit()
            }
            if abs(matchup.levelGap) >= 10 {
                row("exclamationmark.triangle.fill", tint: .orange) {
                    Text(l.practiceLevelGap(mine: playerLevel, theirs: opponentLevel))
                        .foregroundStyle(.orange)
                        .monospacedDigit()
                }
            }
        }
        .font(.caption)
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    private func row<Content: View>(_ symbol: String, tint: Color,
                                    @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 14)
            content()
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    /// How far my best damaging move reaches the foe's types (`PracticeMatchup.bestOffense`).
    enum Reach: Equatable {
        /// ×2 or more: names the moves.
        case strong
        /// ×1 at best (Core lists no moves then).
        case neutral
        /// Every damaging move is resisted: names the least-resisted ones.
        case resisted
        /// Every damaging move is blocked by type: the battle may stall into a draw.
        case immune
        /// No damaging move at all: the battle may stall into a draw.
        case none

        init(_ matchup: PracticeMatchup) {
            let best = matchup.bestOffense, named = !matchup.bestMoveIDs.isEmpty
            if best <= 0 { self = named ? .immune : .none }
            else if best > 1, named { self = .strong }
            else if best < 1, named { self = .resisted }
            else { self = .neutral }
        }

        var iconTint: Color {
            switch self {
            case .strong: PracticeCalloutTone.strong.color
            case .neutral: .secondary
            case .resisted: .orange
            case .immune, .none: .red
            }
        }

        var textTint: Color {
            switch self {
            case .strong: .primary
            case .neutral, .resisted: .secondary
            case .immune, .none: .red
            }
        }
    }

    private var reach: Reach { Reach(matchup) }

    /// Strong: "약점 공략: 10만볼트·볼트태클 ×2"; resisted: "모든 공격이 반감돼요 · 그나마 아이언테일 ×½"
    /// (localized names); neutral, immune and no attacks are fixed lines.
    private var offense: PracticePhrase {
        let marker = "\u{1F}"
        let multiplier = l.practiceMultiplier(matchup.bestOffense)
        let template: String
        switch reach {
        case .strong: template = l.practiceWeakSpot(marker, multiplier)
        case .resisted: template = l.practiceAllResisted(marker, multiplier)
        case .neutral: return PracticePhrase(l.practiceNoWeakSpot)
        case .immune: return PracticePhrase(l.practiceAllImmune)
        case .none: return PracticePhrase(l.practiceNoAttacks)
        }
        let parts = template.components(separatedBy: marker)
        var pieces: [PracticePhrase.Piece] = []
        for (index, part) in parts.enumerated() {
            if !part.isEmpty { pieces.append(.text(part)) }
            guard index < parts.count - 1 else { continue }
            for (offset, moveID) in matchup.bestMoveIDs.enumerated() {
                if offset > 0 { pieces.append(.text(l.practiceNameJoiner)) }
                let slug = PracticeMetadataName.slug(.move, moveID, in: playerSnapshot)
                pieces.append(.name(.resource(PokemonNameResource(kind: .move, name: slug))))
            }
        }
        return PracticePhrase(pieces)
    }

    /// Resisting the foe's types is good news, being weak to them is bad news.
    private var threatTint: Color {
        matchup.threat > 1 ? .red : matchup.threat < 1 ? .green : .secondary
    }

    private var orderTint: Color {
        switch matchup.order {
        case .playerFirst: .green
        case .opponentFirst: .orange
        case .speedTie: .secondary
        }
    }
}

/// Six base stats as paired bars: mine grows left from the middle, theirs right, on one shared scale.
@MainActor
struct PracticeStatComparison: View {
    let mine: [String: Int]
    let theirs: [String: Int]
    let l: L

    private static let keys = ["hp", "atk", "def", "spa", "spd", "spe"]
    private static let barWidth: CGFloat = 80

    var body: some View {
        let scale = Double(max(1, Self.keys.flatMap { [mine[$0] ?? 0, theirs[$0] ?? 0] }.max() ?? 1))
        VStack(spacing: 3) {
            HStack(spacing: 6) {
                Spacer().frame(width: 38)
                Text(l.practiceYou).frame(width: 30 + Self.barWidth + 3, alignment: .trailing)
                Text(l.practiceFoe).frame(width: Self.barWidth + 30 + 3, alignment: .leading)
            }
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
            ForEach(Self.keys, id: \.self) { key in
                let a = mine[key] ?? 0, b = theirs[key] ?? 0
                HStack(spacing: 6) {
                    Text(l.practiceStatName(key)).foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .leading)
                    Text("\(a)").frame(width: 30, alignment: .trailing)
                    HStack(spacing: 3) {
                        bar(Double(a) / scale, color: .orange, leading: false)
                        bar(Double(b) / scale, color: .blue, leading: true)
                    }
                    Text("\(b)").frame(width: 30, alignment: .leading)
                }
                .font(.system(size: 10).monospacedDigit())
            }
        }
    }

    private func bar(_ ratio: Double, color: Color, leading: Bool) -> some View {
        Capsule().fill(color.opacity(0.75))
            .frame(width: max(2, Self.barWidth * min(1, ratio)), height: 5)
            .frame(width: Self.barWidth, alignment: leading ? .leading : .trailing)
    }
}
