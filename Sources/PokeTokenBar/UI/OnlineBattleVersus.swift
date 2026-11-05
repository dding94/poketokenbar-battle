import SwiftUI

/// The opening mark over the two cards: "VS" and, when the server gave a nickname, who the battle is against. It is
/// drawn state of the arena and nothing waits for it: the battle, the clock and the picker below it run as if it were
/// not there, and a press anywhere on it clears it early.
@MainActor
struct OnlineBattleVersus: View {
    let l: L
    let nickname: String?
    let skip: () -> Void

    var body: some View {
        Button(action: skip) {
            VStack(spacing: 6) {
                Text(l.practiceVersus)
                    .font(.system(size: 30, weight: .black, design: .rounded)).italic()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18).padding(.vertical, 2)
                    .background(LinearGradient(colors: [.orange, .pink], startPoint: .leading, endPoint: .trailing), in: Capsule())
                    .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
                if let line = l.onlineSplashLine(nickname) {
                    Text(line).font(.callout.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                }
                Text(l.onlineSplashSkip).font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.96), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel([l.onlineSplashLine(nickname), l.onlineSplashSkip].compactMap { $0 }.joined(separator: ". "))
        .accessibilityIdentifier("online.splash")
    }
}
