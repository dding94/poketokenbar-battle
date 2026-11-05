import XCTest
@testable import PokeTokenBar

/// T05: which online steps pin the popover, and where a reopened popover lands. The pure decisions only;
/// what NSPopover does with `.applicationDefined` needs a real run (see the T24 manual table).
@MainActor
final class OnlinePopoverPinningTests: XCTestCase {
    private typealias Phase = OnlineBattlePresentation.Phase
    private let allPhases: [Phase] = [.setup, .lobby, .room, .arena, .verifying, .result]

    // MARK: pinned section

    func testEntryWaitingAndBattleStepsPinWhileTheOnlineScreenShows() {
        // setup = join form, room = accept / final-confirm wait / prepare, arena and verifying = the match.
        for phase in [Phase.setup, .room, .arena, .verifying] {
            XCTAssertTrue(OnlinePopoverPinning.isPinned(phase: phase, onlineScreenShowing: true), "\(phase)")
        }
    }

    func testLobbyListAndResultStayTransient() {
        for phase in [Phase.lobby, .result] {
            XCTAssertFalse(OnlinePopoverPinning.isPinned(phase: phase, onlineScreenShowing: true), "\(phase)")
        }
    }

    func testNothingPinsOffTheOnlineScreen() {
        // Home, Settings and the other tabs keep the stock outside-click close even mid-match.
        for phase in allPhases {
            XCTAssertFalse(OnlinePopoverPinning.isPinned(phase: phase, onlineScreenShowing: false), "\(phase)")
        }
    }

    // MARK: reopen target

    func testOnlyAMatchInPlayOrVerificationRoutesToTheOnlineScreen() {
        let routed = allPhases.filter { OnlinePopoverPinning.routesToOnlineScreenOnOpen(phase: $0) }
        XCTAssertEqual(routed, [.arena, .verifying])
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

    func testPinnedMarkerIsLocalized() {
        XCTAssertEqual(L(.ko).onlinePinned, "고정됨")
        XCTAssertEqual(L(.en).onlinePinned, "Pinned")
    }
}
