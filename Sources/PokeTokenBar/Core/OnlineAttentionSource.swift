import Foundation
import Observation

/// Where the attention input's facts that the presentation does not carry come from.
/// The menu bar and the home row both build their input here, so they cannot disagree.
@MainActor
@Observable
final class OnlineAttentionSource {
    let presentation: OnlineBattlePresentation
    @ObservationIgnored private let preparedBattleIDs: () -> Set<String>
    @ObservationIgnored private let stagingHeldBattleIDs: () -> Set<String>
    @ObservationIgnored private let noChoiceBattleIDs: () -> Set<String>

    /// `stagingHeldBattleIDs` names the battles whose staged display still holds back their outcome.
    init(presentation: OnlineBattlePresentation,
         preparedBattleIDs: @escaping () -> Set<String> = { [] },
         stagingHeldBattleIDs: @escaping () -> Set<String> = { [] },
         noChoiceBattleIDs: @escaping () -> Set<String> = { [] }) {
        self.presentation = presentation
        self.preparedBattleIDs = preparedBattleIDs
        self.stagingHeldBattleIDs = stagingHeldBattleIDs
        self.noChoiceBattleIDs = noChoiceBattleIDs
    }

    func input(now: Date = Date(), onlineScreenShowing: Bool = false) -> OnlineAttentionInput {
        .init(presentation: presentation, preparedBattleIDs: preparedBattleIDs(), stagingHeldBattleIDs: stagingHeldBattleIDs(),
              noChoiceBattleIDs: noChoiceBattleIDs(), onlineScreenShowing: onlineScreenShowing, now: now)
    }

    func banner(onlineScreenShowing: Bool, now: Date = Date()) -> OnlineAttention? {
        OnlineAttentionCalculator.banner(input(now: now, onlineScreenShowing: onlineScreenShowing))
    }
    func openRoute(now: Date = Date()) -> OnlineOpenRoute? { OnlinePopoverPinning.openRoute(input(now: now)) }

    func menuMark(l: L, now: Date = Date()) -> OnlineMenuMark? { l.onlineMenuMark(input(now: now)) }
    func homeSubtitle(l: L, now: Date = Date()) -> String { l.onlineHomeSubtitle(input(now: now), connectionStatus: presentation.connectionStatus) }

    /// The next moment the mark can change without any presentation change: a myTurn crossing ten seconds, then its deadline.
    func nextMarkChange(now: Date = Date()) -> Date? {
        OnlineAttentionCalculator.active(input(now: now)).compactMap { attention -> Date? in
            guard attention.kind == .myTurn, let deadline = attention.deadline else { return nil }
            let urgentAt = deadline.addingTimeInterval(-OnlineMenuMark.urgentSeconds)
            return urgentAt > now ? urgentAt : deadline
        }.min()
    }
}
