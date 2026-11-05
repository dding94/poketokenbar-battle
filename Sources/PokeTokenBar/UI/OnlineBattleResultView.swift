import SwiftUI

/// The finished room: outcome, what it did to this save (only what the receipt recorded), and the way to another
/// match. It draws `OnlineBattlePresentation.resultScreen` and adds no words of its own. The hero, totals tiles and
/// opponent line follow the practice result; the controls follow the rematch beside it.
@MainActor
struct OnlineBattleResultView: View {
    let model: OnlineBattlePresentation
    let l: L
    let artwork: Bool

    var body: some View {
        if let screen = model.resultScreen(l: l) {
            content(screen)
        } else {
            Button { model.send(.dismissResult) } label: { Text(l.onlineResultToLobby).frame(maxWidth: .infinity) }
                .buttonStyle(.bordered).disabled(model.isBusy)
        }
    }

    private func content(_ screen: OnlineBattleResultScreen) -> some View {
        VStack(spacing: 10) {
            hero(screen)
            if let totals = screen.totals {
                HStack(spacing: 8) {
                    PracticeResultTile(label: l.practiceTurnsLabel, value: "\(totals.turns)")
                    PracticeResultTile(label: l.practiceDamageDealt, value: l.practicePercent(totals.dealtPercent), tint: .accentColor)
                    PracticeResultTile(label: l.practiceDamageTaken, value: l.practicePercent(totals.takenPercent))
                }
            }
            if !screen.effects.isEmpty { effects(screen.effects) }
            if case .answer(let banner, _) = screen.rematch { answer(banner, screen) }
            actions(screen)
        }
        .frame(maxWidth: .infinity)
    }

    private func hero(_ screen: OnlineBattleResultScreen) -> some View {
        let seat = model.localSide == .p1 ? model.room?.p1 : model.room?.p2
        let won = model.result?.kind == .win
        return VStack(spacing: 3) {
            PracticeSpriteTile(set: seat?.snapshot?.set, size: 48, artwork: artwork)
                .practiceFainted(model.result?.effects?.fainted == true)
            Text(screen.title)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(won ? Color.accentColor : Color.primary)
                .lineLimit(1).minimumScaleFactor(0.7)
                .accessibilityIdentifier("online.result.title")
            if !screen.subtitle.isEmpty {
                Text(screen.subtitle)
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            if !screen.opponent.isEmpty {
                Text(screen.opponent)
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("online.result.opponent")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func effects(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .practiceCard()
        .accessibilityIdentifier("online.result.effects")
    }

    /// The other seat's request, answered where the result already is.
    private func answer(_ banner: String, _ screen: OnlineBattleResultScreen) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(banner, systemImage: "bell.badge.fill")
                .font(.callout).foregroundStyle(Color.primary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button { if let action = screen.primaryAction { model.send(action) } } label: { Text(l.onlineAccept).frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAnswer(screen))
                    .accessibilityIdentifier("online.result.accept")
                Button { if let action = screen.secondaryAction { model.send(action) } } label: { Text(l.onlineRematchLater).frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("online.result.later")
            }
            if let note = screen.note {
                Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                    .accessibilityIdentifier("online.result.note")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1))
    }

    /// Accepting needs a Pokémon that can fight, which `canAccept` already knows about.
    private func isAnswer(_ screen: OnlineBattleResultScreen) -> Bool {
        if case .answer = screen.rematch { return true }
        return false
    }

    private func canAnswer(_ screen: OnlineBattleResultScreen) -> Bool {
        guard case .answer(_, let id) = screen.rematch else { return false }
        return model.canAccept(model.actionRoom(id))
    }

    @ViewBuilder
    private func primary(_ label: String, prominent: Bool, enabled: Bool, id: String, _ screen: OnlineBattleResultScreen) -> some View {
        let button = Button { if let action = screen.primaryAction { model.send(action) } } label: {
            Text(label).font(.body.weight(.semibold)).frame(maxWidth: .infinity).lineLimit(1).minimumScaleFactor(0.8)
        }
        .controlSize(.large)
        .disabled(!enabled)
        .accessibilityIdentifier(id)
        if prominent { button.buttonStyle(.borderedProminent) } else { button.buttonStyle(.bordered) }
    }

    private func actions(_ screen: OnlineBattleResultScreen) -> some View {
        VStack(spacing: 6) {
            switch screen.rematch {
            case .none, .answer:
                EmptyView()
            case .request:
                primary(l.onlineRematchAgain, prominent: true, enabled: screen.primaryEnabled, id: "online.result.rematch", screen)
            case .waiting(let label, _):
                primary(label, prominent: false, enabled: !model.isBusy, id: "online.result.rematchWaiting", screen)
            case .open:
                primary(l.onlineRematchOpenRoom, prominent: true, enabled: true, id: "online.result.rematchOpen", screen)
            }
            // A request's own note sits inside its banner.
            if let note = screen.note, !isAnswer(screen) {
                Text(note).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("online.result.note")
            }
            Button { model.send(.dismissResult) } label: { Text(l.onlineResultToLobby).frame(maxWidth: .infinity) }
                .buttonStyle(.bordered).disabled(model.isBusy)
                .accessibilityIdentifier("online.result.toLobby")
        }
    }
}
