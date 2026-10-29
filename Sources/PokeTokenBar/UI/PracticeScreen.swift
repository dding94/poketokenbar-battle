import SwiftUI

/// The local practice battle inside the popover: selection → battle → result. It replaces the whole
/// popover content like Settings and Recap, at the same height as the tabs so the popover does not jump.
@MainActor
struct PracticeScreen: View {
    let session: PracticeSession
    let l: L
    /// false keeps tests offline: no sprite downloads and no PokéAPI name lookups.
    var artwork = true
    let onClose: () -> Void

    init(session: PracticeSession, l: L, artwork: Bool = true, onClose: @escaping () -> Void) {
        self.session = session; self.l = l; self.artwork = artwork; self.onClose = onClose
    }

    /// Top bar 22 + body 520 + caption 16, with the tabs' 12pt spacing and 14pt padding: 610pt,
    /// the height of Home (segmented control, 520pt content, footer).
    private static let barHeight: CGFloat = 22
    private static let bodyHeight: CGFloat = 520
    private static let captionHeight: CGFloat = 16

    private enum Stage {
        case selection
        case battle(PracticeBattle)
        case result(PracticeBattle)
    }

    private var stage: Stage {
        guard let battle = session.battle else { return .selection }
        switch battle.phase {
        case .ready, .cancelled: return .selection
        case .running, .failed: return .battle(battle)
        case .finished: return .result(battle)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            topBar
                .frame(height: Self.barHeight)
            content
                .frame(width: PopoverMetrics.contentWidth, height: Self.bodyHeight, alignment: .top)
            caption
                .frame(height: Self.captionHeight)
        }
        .frame(width: PopoverMetrics.contentWidth)
        .padding(PopoverMetrics.padding)
    }

    @ViewBuilder
    private var content: some View {
        switch stage {
        case .selection:
            PracticeSelectionView(session: session, l: l, artwork: artwork)
        case .battle(let battle):
            PracticeBattleBoard(session: session, battle: battle, l: l, artwork: artwork)
        case .result(let battle):
            PracticeResultView(session: session, battle: battle, l: l, artwork: artwork)
        }
    }

    // MARK: Chrome

    private var topBar: some View {
        ZStack {
            Text(title).font(.headline).lineLimit(1)
            HStack(spacing: 6) {
                Button(action: onClose) {
                    Label(l.home, systemImage: "chevron.left").labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)   // Esc, like Settings and Recap
                Spacer(minLength: 4)
                statusCapsule
            }
        }
    }

    private var title: String {
        if case .result = stage { return l.practiceResultTitle }
        return l.practiceTitle
    }

    /// Selection and result: the result is not recorded. Manual battle: turn and seconds left.
    /// Automatic battle: "Auto".
    private var statusCapsule: some View {
        var text = l.practiceNotRecorded
        var urgent = false
        if case .battle(let battle) = stage, battle.phase == .running {
            if session.mode == .automatic {
                text = l.practiceAutoBadge
            } else {
                text = l.practiceTurnClock(battle.view?.turn ?? 1, battle.remainingSeconds)
                urgent = battle.remainingSeconds <= 10 && !battle.isPaused
            }
        }
        return Text(text)
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(urgent ? Color.orange : Color.secondary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background((urgent ? Color.orange : Color.secondary).opacity(0.12), in: Capsule())
    }

    private var caption: some View {
        let text: String
        switch stage {
        case .selection: text = l.practiceRules
        case .battle: text = l.practiceCaptionBattle
        case .result: text = l.practiceCaptionResult
        }
        return Label(text, systemImage: "lock.shield")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity)
    }
}
