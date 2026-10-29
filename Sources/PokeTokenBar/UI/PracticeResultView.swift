import SwiftUI

/// A finished practice battle: outcome, the staged totals (turns, damage, finishing move, big hits),
/// the full beat log, and the ways back in. Without a playback it shows the engine's view and log.
/// Appearing reports the result as seen, which clears the menu bar badge and the Home entry hint.
@MainActor
struct PracticeResultView: View {
    @Bindable var session: PracticeSession
    let battle: PracticeBattle
    let l: L
    let artwork: Bool

    private enum Outcome { case win, loss, draw }

    private var outcome: Outcome {
        switch battle.result?.winner {
        case nil: .draw
        case "p1": .win
        default: .loss
        }
    }

    private var playback: PracticePlayback? { session.playback }
    private var wording: PracticeWording { PracticeWording(session: session, battle: battle, l: l) }
    private var turns: Int {
        if let staged = playback?.summary.turns, staged > 0 { return staged }
        return battle.result?.turns ?? battle.view?.turn ?? 0
    }
    private var foeName: String { wording.opponentName }

    var body: some View {
        VStack(spacing: 10) {
            hero
            if let playback {
                tiles(playback.summary)
                stagedSummary(playback.summary)
                stagedLog(playback)
            } else {
                summary
                log
                Spacer(minLength: 0)
            }
            actions
        }
        .onAppear { session.markResultSeen() }
    }

    private var hero: some View {
        VStack(spacing: 3) {
            PracticeSpriteTile(set: session.player?.snapshot?.set, size: 52, artwork: artwork)
                .practiceFainted(outcome == .loss)
            Text(outcome == .win ? l.practiceVictory : outcome == .loss ? l.practiceDefeat : l.practiceDraw)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(outcome == .win ? Color.accentColor : Color.primary)
            Text(subtitle)
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    private var subtitle: String {
        switch outcome {
        case .win: l.practiceWonLine(turns: turns, foe: foeName)
        case .loss: l.practiceLostLine(turns: turns, foe: foeName)
        case .draw: l.practiceDrawLine(turns: turns)
        }
    }

    // MARK: Staged totals

    /// Turns, damage dealt and damage taken as three tiles.
    private func tiles(_ summary: PracticeSummary) -> some View {
        HStack(spacing: 8) {
            tile(l.practiceTurnsLabel, "\(turns)", tint: .primary)
            tile(l.practiceDamageDealt, l.practicePercent(summary.damageDealtPercent), tint: .accentColor)
            tile(l.practiceDamageTaken, l.practicePercent(summary.damageTakenPercent), tint: .primary)
        }
    }

    private func tile(_ label: String, _ value: String, tint: Color) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.system(size: 17, weight: .bold).monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(1)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .practiceCard(padding: 7)
    }

    private func stagedSummary(_ summary: PracticeSummary) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                rowLabel(l.practiceFinishingMove)
                if let moveID = summary.finishingMoveID {
                    // The loser fainted to this move, so the winner used it.
                    let side: PracticeSide = outcome == .loss ? .opponent : .player
                    PracticePhraseText(phrase: PracticePhrase([.name(wording.move(side, moveID))]), l: l, artwork: artwork)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                } else {
                    Text(l.practiceNone).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .font(.caption)
            row(l.practiceBigHits, l.practiceHitCounts(superEffective: summary.superEffectiveHits,
                                                       critical: summary.criticalHits))
            if let mine = playback?.display[.player] {
                row(l.practiceRemainingHP, "\(mine.hp)/\(mine.maxHP) · \(l.practicePercent(mine.percent))")
            }
            row(l.practiceMode, battle.mode == .manual ? l.practiceManual : l.practiceAuto)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .practiceCard()
    }

    /// Every beat as a localized line, oldest first, opening at the end where the battle was decided.
    private func stagedLog(_ playback: PracticePlayback) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(l.practiceLog).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(playback.history) { beat in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(l.practiceTurnTag(beat.turn))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .frame(width: 30, alignment: .leading)
                            PracticePhraseText(phrase: wording.sentence(beat, notes: 3), l: l, artwork: artwork)
                                .font(.caption)
                                .foregroundStyle(beat.id == playback.history.last?.id ? Color.primary : Color.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .reservesScrollerLane()
            }
            .defaultScrollAnchor(.bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .practiceCard()
    }

    private func rowLabel(_ label: String) -> some View {
        Text(label).foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
    }

    // MARK: Without a playback

    private var summary: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let mine = battle.view?.p1 {
                let percent = mine.maxhp > 0 ? mine.hp * 100 / mine.maxhp : 0
                row(l.practiceRemainingHP, "\(mine.hp)/\(mine.maxhp) · \(percent)%")
            }
            if let foe = battle.view?.p2 {
                row(l.practiceFoeRevealed, l.practiceRevealedSummary(moves: foe.moves.count, ability: foe.ability != nil))
            }
            row(l.practiceMode, battle.mode == .manual ? l.practiceManual : l.practiceAuto)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .practiceCard()
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            rowLabel(label)
            Text(value).monospacedDigit().lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.caption)
    }

    /// The four newest lines, newest first.
    private var log: some View {
        let lines = Array(battle.messages.filter { !$0.hasPrefix("──") }.suffix(4).reversed())
        return VStack(alignment: .leading, spacing: 3) {
            Text(l.practiceLog).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                Text(line)
                    .foregroundStyle(index == 0 ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .practiceCard()
    }

    // MARK: Actions

    private var actions: some View {
        VStack(spacing: 8) {
            Button { session.start() } label: {
                Text(l.practiceRematch).font(.body.weight(.semibold)).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            HStack(spacing: 8) {
                Button {
                    // A wild foe was just fought: offer fresh ones instead of the same three.
                    let wasWild = session.opponent?.origin.wildTraits != nil
                    session.backToSelection()
                    if wasWild { session.findWildOpponents() }
                } label: {
                    Text(l.practiceOtherOpponent).frame(maxWidth: .infinity)
                }
                Button {
                    session.mode = .automatic
                    session.start()
                } label: {
                    Text(l.practiceAutoAgain).frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
        }
    }
}
