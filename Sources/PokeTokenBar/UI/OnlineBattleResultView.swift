import SwiftUI

/// The finished room: outcome, what it did to this save, and the way to another match.
@MainActor
struct OnlineBattleResultView: View {
    let model: OnlineBattlePresentation
    let l: L
    let artwork: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.result.map { l.onlineResultTitle($0.kind) } ?? l.onlineResult).font(.title3.bold())
            if let room = model.room, room.state == .completed,
               room.side(for: model.account?.trainer.trainerId ?? "") != nil {
                Button(l.onlineRematchAgain) { model.send(.prepareRematch(room.battleId)) }
                    .disabled(!model.canRematch(room))
            }
            Button(l.onlineDone) { model.send(.dismissResult) }
                .buttonStyle(.borderedProminent).disabled(model.isBusy)
        }
        .frame(maxWidth: .infinity, alignment: .leading).practiceCard()
    }
}
