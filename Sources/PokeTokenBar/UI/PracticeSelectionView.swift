import SwiftUI

/// Practice selection: my entry (changeable inline), the opponent radio list with a paired stat
/// comparison on the selected row, unavailable Pokémon, the mode, and the start button. The list
/// scrolls; the mode and the start button stay pinned at the bottom of the 520pt body.
@MainActor
struct PracticeSelectionView: View {
    @Bindable var session: PracticeSession
    let l: L
    let artwork: Bool
    @State private var changingPlayer = false

    private var eligible: [PracticeCandidate] { session.roster?.eligible ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    playerCard
                    if let error = session.loadError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // No roster yet: `prepare` runs synchronously on appear, so there is nothing to wait for
                    // (and no spinner — the popover avoids open-ended animations).
                    if session.roster != nil, eligible.count < 2 {
                        Label(l.practiceNeedsPair, systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .practiceCard()
                    } else if session.roster != nil {
                        Text(l.practiceOpponentCaption)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        VStack(spacing: 6) {
                            ForEach(Array(eligible.enumerated()), id: \.element.id) { index, candidate in
                                if candidate.id != session.playerID {
                                    opponentRow(candidate, number: index + 1)
                                }
                            }
                        }
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
    }

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

    /// Picking my current opponent as my entry swaps the two, so the pair stays valid.
    private func choosePlayer(_ id: String) {
        if id == session.opponentID { session.opponentID = session.playerID }
        session.playerID = id
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

    private func opponentRow(_ candidate: PracticeCandidate, number: Int) -> some View {
        let selected = candidate.id == session.opponentID
        return VStack(alignment: .leading, spacing: 8) {
            Button { session.opponentID = candidate.id } label: {
                HStack(spacing: 8) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    PracticeSpriteTile(set: candidate.snapshot?.set, size: 32, artwork: artwork)
                    PracticeNameLevel(name: candidate.name, level: candidate.snapshot?.set.level ?? 0,
                                      font: .callout.weight(selected ? .semibold : .regular))
                    PracticeTypeBadges(types: candidate.snapshot?.publicInfo.types ?? [], l: l, artwork: artwork)
                    Spacer(minLength: 4)
                    Text("#\(number)").font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if selected, let mine = session.player?.snapshot?.publicInfo.stats,
               let theirs = candidate.snapshot?.publicInfo.stats {
                PracticeStatComparison(mine: mine, theirs: theirs, l: l)
                Text(l.practiceRevealHint).font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .background(selected ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(selected ? Color.accentColor.opacity(0.35) : Color.clear))
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
                Text(l.practiceManualPerTurn).tag(PracticeBattle.Mode.manual)
                Text(l.practiceAuto).tag(PracticeBattle.Mode.automatic)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(session.mode == .manual ? l.practiceAutoPickHint : l.practiceAutoModeHint)
                .font(.caption2).foregroundStyle(.secondary)
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
