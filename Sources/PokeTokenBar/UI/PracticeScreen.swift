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
        // The board stays until the last beat has played; the result follows the staged finish.
        case .finished: return session.playback?.isPlaying == true ? .battle(battle) : .result(battle)
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
            PracticeSelectionView(session: session, progress: PracticeSelectionProgress(session), l: l, artwork: artwork)
        case .battle(let battle):
            PracticeBattleBoard(session: session, battle: battle, l: l, artwork: artwork)
        case .result(let battle):
            PracticeResultView(session: session, battle: battle, record: session.lastRecord, l: l, artwork: artwork)
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

    /// Selection and result: practice keeps its own record and never touches the save. Manual battle: turn and
    /// seconds left. Automatic battle: "Auto".
    private var statusCapsule: some View {
        var text = l.practiceSaveUntouched
        var urgent = false
        if case .battle(let battle) = stage, battle.phase == .running {
            if session.mode == .automatic {
                text = l.practiceAutoBadge
            } else {
                // While a turn is being staged the clock is held; show the turn on screen, not the engine's next one.
                let turn = session.playback?.beat?.turn ?? battle.view?.turn ?? 1
                text = l.practiceTurnClock(turn, battle.remainingSeconds)
                urgent = Self.clockIsUrgent(remaining: battle.remainingSeconds, paused: battle.isPaused)
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

    /// The turn clock turns orange for the last 5 s of a manual turn; a held clock is not running out. (At the
    /// old 10 s mark a 15 s practice turn would be orange for two thirds of it.)
    static func clockIsUrgent(remaining: Int, paused: Bool) -> Bool { remaining <= 5 && !paused }

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
