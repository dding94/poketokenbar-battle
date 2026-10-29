import SwiftUI

/// A finished practice battle: outcome, a short summary, the last log lines, and the ways back in.
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

    private var turns: Int { battle.result?.turns ?? battle.view?.turn ?? 0 }
    private var foeName: String { session.opponent?.name ?? battle.view?.p2.species ?? "" }

    var body: some View {
        VStack(spacing: 10) {
            hero
            summary
            log
            Spacer(minLength: 0)
            actions
        }
        .onAppear { session.markResultSeen() }
    }

    private var hero: some View {
        VStack(spacing: 4) {
            PracticeSpriteTile(set: session.player?.snapshot?.set, size: 64, artwork: artwork)
            Text(outcome == .win ? l.practiceVictory : outcome == .loss ? l.practiceDefeat : l.practiceDraw)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(outcome == .win ? Color.accentColor : Color.primary)
            Text(subtitle)
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private var subtitle: String {
        switch outcome {
        case .win: l.practiceWonLine(turns: turns, foe: foeName)
        case .loss: l.practiceLostLine(turns: turns, foe: foeName)
        case .draw: l.practiceDrawLine(turns: turns)
        }
    }

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
            Text(label).foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
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

    private var actions: some View {
        VStack(spacing: 8) {
            Button { session.start() } label: {
                Text(l.practiceRematch).font(.body.weight(.semibold)).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            HStack(spacing: 8) {
                Button { session.backToSelection() } label: {
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
