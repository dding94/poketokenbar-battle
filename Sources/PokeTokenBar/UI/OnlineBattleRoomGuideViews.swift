import SwiftUI

/// Top of the battle room: who we are battling, the four steps, whose move it is, and (for the
/// challenger) that the request went out and how long ago.
@MainActor
struct OnlineBattleRoomGuide: View {
    let model: OnlineBattlePresentation
    let l: L
    let progress: OnlineRoomProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(l.onlineRoomVersus(model.roomOpponentName)).font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            steps
            Text(l.onlineRoomGuide(progress, opponent: model.roomOpponentName))
                .font(.callout.weight(progress.turn == .mine ? .semibold : .regular))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(progress.turn == .mine ? 0.14 : 0.06)))
                .accessibilityIdentifier("online.room.guide")
            if model.room?.state == .pending && model.localSide == .p1 { requestSent }
        }
    }

    private var steps: some View {
        HStack(alignment: .top, spacing: 2) {
            ForEach(OnlineRoomStep.allCases, id: \.rawValue) { step in
                let done = step.rawValue < progress.step.rawValue
                let current = step == progress.step
                VStack(spacing: 3) {
                    Image(systemName: done ? "checkmark.circle.fill" : "\(step.rawValue + 1).circle\(current ? ".fill" : "")")
                        .font(.system(size: 16))
                        .foregroundStyle(done || current ? Color.accentColor : Color.secondary.opacity(0.6))
                    Text(l.onlineStepName(step)).font(.system(size: 10, weight: current ? .bold : .regular))
                        .foregroundStyle(current ? Color.primary : Color.secondary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(step.rawValue + 1)/4 \(l.onlineStepName(step))")
                .accessibilityValue(l.onlineStepState(done: done, current: current))
            }
        }
    }

    /// Minute-level wording, so a slow tick is enough and no animation runs.
    private var requestSent: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            VStack(alignment: .leading, spacing: 2) {
                Label(l.onlineRequestSent(opponent: model.roomOpponentName), systemImage: "paperplane")
                    .font(.caption)
                Text(l.onlineRequestAge(seconds: Int(model.requestAge(now: context.date) ?? 0)))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One short line under a disabled primary button saying why it is disabled.
struct OnlineBattleBlockReason: View {
    let block: OnlineActionBlock?
    let l: L
    var identifier = "online.block.reason"
    var body: some View {
        if let block {
            Text(l.onlineActionBlock(block)).font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(identifier)
        }
    }
}
