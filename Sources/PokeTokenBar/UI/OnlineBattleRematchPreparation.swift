import SwiftUI

@MainActor
struct OnlineBattleRematchPreparation: View {
    let model: OnlineBattlePresentation
    let l: L
    let artwork: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { model.send(.cancelRematch) } label: {
                Label(l.onlineRematchBack, systemImage: "chevron.left")
            }.buttonStyle(.borderless).accessibilityIdentifier("online.rematch.back")
            Text(l.onlineRematchPreparation).font(.headline)
            VStack(alignment: .leading, spacing: 7) {
                Text(l.onlineRematchOpponent).font(.caption).foregroundStyle(.secondary)
                Text(model.rematchOpponent?.displayEmail ?? l.onlineAnonymous)
                    .font(.subheadline.bold()).lineLimit(2)
                Divider()
                Text(l.onlineMode).font(.caption).foregroundStyle(.secondary)
                Text(model.rematchMode == .auto ? l.onlineAuto : l.onlineManual)
                    .font(.subheadline.bold())
                Text(l.onlineRematchLocked).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.practiceCard()
            OnlineBattleRoster(model: model, l: l, artwork: artwork)
            Text(l.onlineStakesHint).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).practiceCard()
            if !model.canSubmitRematch {
                Text(l.onlineRematchUnavailable)
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(l.onlineRematchSubmit) { model.send(.submitRematch) }
                .buttonStyle(.borderedProminent).disabled(!model.canSubmitRematch)
                .accessibilityIdentifier("online.rematch.submit")
        }
    }
}
