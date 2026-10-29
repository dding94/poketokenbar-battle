import SwiftUI

/// A running (or failed) practice battle: both sides, the newest log lines, and the move grid. The
/// session drives turns and deadlines; this view only reads the battle and forwards choices.
@MainActor
struct PracticeBattleBoard: View {
    @Bindable var session: PracticeSession
    let battle: PracticeBattle
    let l: L
    let artwork: Bool

    private var automatic: Bool { session.mode == .automatic }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if battle.phase == .failed {
                failure
                Spacer(minLength: 0)
            } else {
                if let view = battle.view {
                    PracticeSideCard(side: view.p2, own: false, name: session.opponent?.name ?? view.p2.species,
                                     snapshot: session.opponent?.snapshot, l: l, artwork: artwork)
                    PracticeSideCard(side: view.p1, own: true, name: session.player?.name ?? view.p1.species,
                                     snapshot: session.player?.snapshot, l: l, artwork: artwork)
                }
                ticker
                if let notice = battle.notice {
                    Label(notice, systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                prompt
                moveGrid
                Spacer(minLength: 0)
                controls
            }
        }
    }

    // MARK: Log

    /// The three newest lines, newest first. Turn separators are left to the full log.
    private var ticker: some View {
        let lines = Array(battle.messages.filter { !$0.hasPrefix("──") }.suffix(3).reversed())
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                Text(line)
                    .foregroundStyle(index == 0 ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .topLeading)
        .practiceCard(padding: 8)
    }

    // MARK: Moves

    @ViewBuilder
    private var prompt: some View {
        HStack(alignment: .firstTextBaseline) {
            if battle.isPaused {
                Text(l.practicePausedHint).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
            } else if automatic {
                Text(l.practiceAutoPlaying).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
            } else {
                Text(l.practiceWhatNext).font(.callout.weight(.semibold))
            }
            Spacer(minLength: 4)
            if !battle.isPaused && !automatic {
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
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(Array(moves.enumerated()), id: \.element.slot) { index, move in
                        PracticeMoveCard(move: move, key: index + 1, snapshot: session.player?.snapshot, l: l,
                                         artwork: artwork,
                                         locked: automatic || battle.isPaused) {
                            session.choose(slot: move.slot)
                        }
                    }
                }
            }
        }
    }

    // MARK: Controls

    private var controls: some View {
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
/// moves and ability. The opponent's HP comes from the engine as a percentage.
@MainActor
struct PracticeSideCard: View {
    let side: BattleView.Pokemon
    let own: Bool
    let name: String
    let snapshot: BattleSnapshot?
    let l: L
    let artwork: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                PracticeSpriteTile(set: snapshot?.set, size: 44, artwork: artwork)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(own ? l.practiceYou : l.practiceFoe)
                            .font(.caption2).foregroundStyle(.secondary).fixedSize()
                        PracticeNameLevel(name: name, level: side.level)
                        PracticeTypeBadges(types: side.types, l: l, artwork: artwork).fixedSize()
                        Spacer(minLength: 0)
                        if !side.status.isEmpty {
                            Badge(l.practiceStatusName(side.status), tint: .orange, style: .tinted, size: 9)
                                .fixedSize()
                        }
                    }
                    HStack(spacing: 8) {
                        PracticeHPBar(hp: side.hp, maxHP: side.maxhp)
                        Text(own ? "\(side.hp)/\(side.maxhp)" : "\(side.hp)%")
                            .font(.caption.weight(.semibold)).monospacedDigit()
                            .frame(minWidth: 52, alignment: .trailing)
                    }
                }
            }
            if own { ownAbility } else { revealed }
        }
        .practiceCard()
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
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) { movesRow; Spacer(minLength: 0) }
                HStack(spacing: 5) { abilityRow; Spacer(minLength: 0) }
            }
        }
    }

    private var movesRow: some View {
        HStack(spacing: 4) {
            Text(l.practiceMoves).font(.caption2).foregroundStyle(.secondary)
            ForEach(Array(side.moves.prefix(4)), id: \.self) { move in
                PracticeChip {
                    PracticeMetadataName(kind: .move, id: move, snapshot: snapshot, l: l, artwork: artwork)
                }
            }
            ForEach(0..<max(0, 4 - side.moves.count), id: \.self) { _ in
                PracticeChip(dimmed: true) { Text("?") }
            }
        }
    }

    private var abilityRow: some View {
        HStack(spacing: 4) {
            Text(l.practiceAbility).font(.caption2).foregroundStyle(.secondary)
            if let ability = side.ability {
                PracticeChip {
                    PracticeMetadataName(kind: .ability, id: ability, snapshot: snapshot, l: l, artwork: artwork)
                }
            } else {
                PracticeChip(dimmed: true) { Text("?") }
            }
        }
    }
}

/// A move button tinted with its type color, bound to the number key of its position.
@MainActor
struct PracticeMoveCard: View {
    let move: BattleMove
    let key: Int
    let snapshot: BattleSnapshot?
    let l: L
    let artwork: Bool
    /// Automatic mode or a paused battle: nothing to choose.
    let locked: Bool
    let action: () -> Void

    private var special: Bool { move.id == "recharge" || move.id == "struggle" }
    private var disabled: Bool { locked || move.disabled || (!special && move.pp <= 0) }
    private var tint: Color { PokemonType(apiName: move.type)?.color ?? .gray }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    name.font(.callout.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 2)
                    Text("\(key)")
                        .font(.system(size: 9, weight: .bold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.secondary.opacity(0.4)))
                }
                HStack(spacing: 4) {
                    if !move.type.isEmpty {
                        PracticeTypeBadges(types: [move.type], l: l, artwork: artwork)
                    }
                    Spacer(minLength: 2)
                    if !special {
                        Text("PP \(move.pp)/\(move.maxpp)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(move.pp <= 0 ? Color.red : Color.secondary)
                    }
                }
            }
            .padding(8)
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
