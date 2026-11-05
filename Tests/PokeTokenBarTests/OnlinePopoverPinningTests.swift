import XCTest
@testable import PokeTokenBar

/// T05: which online steps pin the popover, and where a reopened popover lands. The pure decisions only;
/// what NSPopover does with `.applicationDefined` needs a real run (see the T24 manual table).
@MainActor
final class OnlinePopoverPinningTests: XCTestCase {
    private final class ObservedFlag: @unchecked Sendable { var value = false }
    private typealias Phase = OnlineBattlePresentation.Phase
    private let allPhases: [Phase] = [.setup, .lobby, .room, .arena, .verifying, .result]

    private func model(_ phase: Phase, recoveryCode: String? = nil) -> OnlineBattlePresentation {
        let model = OnlineBattlePresentation()
        model.phase = phase; model.recoveryCode = recoveryCode
        return model
    }

    // MARK: pinned section

    func testEntryWaitingAndBattleStepsPinWhileTheOnlineScreenShows() {
        // setup = join form, room = accept / final-confirm wait / prepare, arena and verifying = the match.
        for phase in [Phase.setup, .room, .arena, .verifying] {
            XCTAssertTrue(OnlinePopoverPinning.isPinned(model(phase), onlineScreenShowing: true), "\(phase)")
        }
    }

    func testLobbyListAndResultStayTransient() {
        for phase in [Phase.lobby, .result] {
            XCTAssertFalse(OnlinePopoverPinning.isPinned(model(phase), onlineScreenShowing: true), "\(phase)")
        }
    }

    func testNothingPinsOffTheOnlineScreen() {
        // Home, Settings and the other tabs keep the stock outside-click close even mid-match.
        for phase in allPhases {
            XCTAssertFalse(OnlinePopoverPinning.isPinned(model(phase), onlineScreenShowing: false), "\(phase)")
        }
    }

    // MARK: recovery code

    /// A join lands on the lobby with the code on screen: the code has to survive a click on Notes, on every phase.
    func testARecoveryCodeOnScreenPinsOnEveryPhase() {
        for phase in allPhases {
            XCTAssertTrue(OnlinePopoverPinning.isPinned(model(phase, recoveryCode: "one-time-code"), onlineScreenShowing: true), "\(phase)")
            XCTAssertFalse(OnlinePopoverPinning.isPinned(model(phase, recoveryCode: "one-time-code"), onlineScreenShowing: false), "\(phase)")
        }
    }

    /// The app delegate tracks exactly what this function reads, so saving the code has to wake the pin up.
    func testSavingTheRecoveryCodeUnpinsThroughTheObservedRead() {
        let lobby = model(.lobby, recoveryCode: "one-time-code")
        let changed = ObservedFlag()
        withObservationTracking {
            _ = OnlinePopoverPinning.isPinned(lobby, onlineScreenShowing: true)
        } onChange: { changed.value = true }
        lobby.recoveryCode = nil
        XCTAssertTrue(changed.value)
        XCTAssertFalse(OnlinePopoverPinning.isPinned(lobby, onlineScreenShowing: true))
    }

    // MARK: reopen target

    func testOnlyAMatchInPlayOrVerificationRoutesWhenNothingAsksForAttention() {
        // The other phases now route too when an event is waiting (OnlineAttentionFlowTests); with no event they stay Home.
        for phase in allPhases {
            let model = model(phase)
            if phase == .arena || phase == .verifying { model.room = OnlineBattleScreenRenderingTests.room(state: phase == .arena ? .running : .reported) }
            let input = OnlineAttentionSource(presentation: model).input()
            XCTAssertEqual(OnlinePopoverPinning.openRoute(input) != nil, phase == .arena || phase == .verifying, "\(phase)")
        }
    }

    func testReopeningDuringAMatchLandsOnTheOnlineScreenAfterTheReset() {
        let navigation = PopoverNavigation()
        navigation.showSettings = true
        navigation.tab = .shop
        AppDelegate.applyOpenRoute(to: navigation, practiceActive: false, onlineActive: true) { _ in }
        XCTAssertTrue(navigation.showingOnlineBattle)
        XCTAssertFalse(navigation.showSettings)
        XCTAssertEqual(navigation.tab, .home)
    }

    func testReopeningWithoutAMatchStaysOnHome() {
        let navigation = PopoverNavigation()
        navigation.showingOnlineBattle = true   // left over from the previous opening
        AppDelegate.applyOpenRoute(to: navigation, practiceActive: false, onlineActive: false) { _ in }
        XCTAssertFalse(navigation.showingOnlineBattle)
    }

    func testAMatchOutranksALocalPracticeBattleOnReopen() {
        // The online screen is drawn before the practice screen and its turn clock cannot wait.
        let navigation = PopoverNavigation()
        AppDelegate.applyOpenRoute(to: navigation, practiceActive: true, onlineActive: true) { $0.showingPractice = true }
        XCTAssertTrue(navigation.showingOnlineBattle)
    }

    func testAnExplicitMenuDestinationIsNotCoveredByTheMatchRoute() {
        for route: (PopoverNavigation) -> Void in [{ $0.showSettings = true }, { $0.openRepresentativeDex() }, { $0.showingRecap = true }] {
            let navigation = PopoverNavigation()
            AppDelegate.applyOpenRoute(to: navigation, practiceActive: false, onlineActive: true, route: route)
            XCTAssertFalse(navigation.showingOnlineBattle, "a destination the person picked is not overridden")
        }
    }

    func testANotificationClickKeepsTheOnlineScreenWhenAMatchIsActive() {
        let navigation = PopoverNavigation()
        AppDelegate.applyOpenRoute(to: navigation, practiceActive: false, onlineActive: true, route: AppDelegate.openOnlineScreen)
        XCTAssertTrue(navigation.showingOnlineBattle)
    }

    // MARK: copy

    func testAPinnedPopoverBehindAnotherAppStillLetsNotificationsThrough() {
        XCTAssertFalse(OnlinePopoverPinning.showsAttentionInstead(popoverShown: true, appActive: false))
        XCTAssertTrue(OnlinePopoverPinning.showsAttentionInstead(popoverShown: true, appActive: true))
        XCTAssertFalse(OnlinePopoverPinning.showsAttentionInstead(popoverShown: false, appActive: true))
    }

    // MARK: a notification or banner while the popover is open

    /// Settings and the recap are drawn before the online screen, so only flipping the flag would leave the room hidden.
    func testAnEventRouteUncoversTheOnlineScreenFromSettingsAndTheRecap() {
        for cover: (PopoverNavigation) -> Void in [{ $0.showSettings = true }, { $0.showingRecap = true }, { $0.openSessionKeySettings() }] {
            let navigation = PopoverNavigation()
            cover(navigation)
            var sent: [String] = []
            let model = OnlineBattlePresentation()
            model.onAction = { action in if case .followAttention(let id) = action { sent.append(id) } }
            navigation.openOnlineEvent("bt-1", model: model, l: L(.ko))
            XCTAssertTrue(navigation.showingOnlineBattle)
            XCTAssertFalse(navigation.showSettings)
            XCTAssertFalse(navigation.showingRecap)
            XCTAssertFalse(navigation.expandAdvancedOnOpen)
            XCTAssertEqual(sent, ["bt-1"])
        }
    }

    func testAnEventRouteWithoutARoomKeepsTheSelectedRoom() {
        let navigation = PopoverNavigation()
        var sent = 0
        let model = OnlineBattlePresentation()
        model.onAction = { _ in sent += 1 }
        navigation.openOnlineEvent(nil, model: model, l: L(.ko))
        XCTAssertTrue(navigation.showingOnlineBattle)
        XCTAssertEqual(sent, 0)
    }

    func testOpeningFollowsTheRouteOnlyWhenTheOnlineScreenWon() {
        let cases: [(route: (PopoverNavigation) -> Void, followed: Bool)] = [({ _ in }, true), ({ $0.showSettings = true }, false)]
        for (route, followed) in cases {
            let navigation = PopoverNavigation()
            var sent: [String] = []
            let model = OnlineBattlePresentation()
            model.onAction = { action in if case .followAttention(let id) = action { sent.append(id) } }
            AppDelegate.applyOpenRoute(to: navigation, practiceActive: false, onlineActive: true, route: route)
            AppDelegate.followOpenRoute("bt-1", navigation: navigation, model: model, l: L(.ko))
            XCTAssertEqual(sent, followed ? ["bt-1"] : [], "A destination the person picked does not move the room either")
        }
    }

    func testPinnedMarkerIsLocalized() {
        XCTAssertEqual(L(.ko).onlinePinned, "고정됨")
        XCTAssertEqual(L(.en).onlinePinned, "Pinned")
    }
}
