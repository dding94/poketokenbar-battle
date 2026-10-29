import AppKit
import XCTest
@testable import PokeTokenBar

@MainActor
final class PracticeLaunchTests: XCTestCase {
    // MARK: launch argument

    func testLaunchArgumentIsDetected() {
        XCTAssertTrue(AppDelegate.launchRequestsPractice(arguments: ["/Applications/PokeTokenBar", "--practice"]))
    }

    func testLaunchWithoutTheArgumentDoesNotOpenPractice() {
        XCTAssertFalse(AppDelegate.launchRequestsPractice(arguments: ["/Applications/PokeTokenBar"]))
        XCTAssertFalse(AppDelegate.launchRequestsPractice(arguments: []))
        XCTAssertFalse(AppDelegate.launchRequestsPractice(arguments: ["--practice-later", "practice"]))
    }

    // MARK: reopen route

    func testActiveBattleReopensOnPracticeAfterTheReset() {
        let navigation = PopoverNavigation()
        navigation.showSettings = true
        AppDelegate.applyOpenRoute(to: navigation, practiceActive: true) { _ in }
        XCTAssertTrue(navigation.showingPractice)
        XCTAssertFalse(navigation.showSettings, "the reset to Home still runs first")
    }

    func testIdleSessionReopensOnHome() {
        let navigation = PopoverNavigation()
        navigation.showingPractice = true   // left over from a previous opening
        AppDelegate.applyOpenRoute(to: navigation, practiceActive: false) { _ in }
        XCTAssertFalse(navigation.showingPractice)
        XCTAssertEqual(navigation.tab, .home)
        XCTAssertFalse(navigation.showSettings)
    }

    func testRouteRunsAfterThePracticeDecision() {
        let navigation = PopoverNavigation()
        var sawPractice: Bool?
        AppDelegate.applyOpenRoute(to: navigation, practiceActive: true) { sawPractice = $0.showingPractice }
        XCTAssertEqual(sawPractice, true, "route sees the state it may override")
        AppDelegate.applyOpenRoute(to: navigation, practiceActive: false) { $0.showingPractice = true }
        XCTAssertTrue(navigation.showingPractice, "an explicit route (Finder reopen, --practice) wins over idle")
    }

    // MARK: menu line badge

    func testNilBadgeLeavesTheLinesUntouched() {
        XCTAssertEqual(AppDelegate.menuLines(["5h 12%", "1.2M"], badge: nil), ["5h 12%", "1.2M"])
        XCTAssertEqual(AppDelegate.menuLines([], badge: nil), [])
    }

    func testBadgeIsAppendedToTheOnlyLine() {
        XCTAssertEqual(AppDelegate.menuLines(["1.2M"], badge: "⚔︎"), ["1.2M ⚔︎"])
    }

    func testBadgeGoesOnTheFirstOfSeveralLines() {
        XCTAssertEqual(AppDelegate.menuLines(["5h 12%", "1.2M"], badge: "⚑"), ["5h 12% ⚑", "1.2M"])
        XCTAssertEqual(AppDelegate.menuLines(["a", "b", "c"], badge: "⚑"), ["a ⚑", "b", "c"])
    }

    func testBadgeAloneFillsAnEmptyMenu() {
        XCTAssertEqual(AppDelegate.menuLines([], badge: "⚔︎"), ["⚔︎"])
    }

    // MARK: tooltip

    func testToolTipWithoutBadgeIsTheBaseTip() {
        XCTAssertNil(AppDelegate.menuToolTip(base: nil, badge: nil, resultReady: false, l: L(.en)))
        XCTAssertEqual(AppDelegate.menuToolTip(base: "tip", badge: nil, resultReady: true, l: L(.en)), "tip")
    }

    func testToolTipAddsTheRunningLine() {
        let l = L(.en)
        XCTAssertEqual(AppDelegate.menuToolTip(base: nil, badge: "⚔︎", resultReady: false, l: l), l.practiceStatusRunning)
        XCTAssertEqual(AppDelegate.menuToolTip(base: "tip", badge: "⚔︎", resultReady: false, l: l),
                       "tip\n" + l.practiceStatusRunning)
    }

    func testToolTipAddsTheResultLine() {
        let l = L(.ko)
        XCTAssertEqual(AppDelegate.menuToolTip(base: nil, badge: "⚑", resultReady: true, l: l), l.practiceStatusResult)
        XCTAssertEqual(AppDelegate.menuToolTip(base: "tip", badge: "⚑", resultReady: true, l: l),
                       "tip\n" + l.practiceStatusResult)
    }

    // MARK: Finder reopen

    func testFinderReopenOpensPracticeWithoutCreatingAWindow() {
        _ = NSApplication.shared
        let appDelegate = AppDelegate()   // not launched: statusItem stays nil and is never touched
        var opened = 0
        appDelegate.onOpenPractice = { opened += 1 }
        let windowsBefore = NSApp.windows.count

        let delegate: NSApplicationDelegate = appDelegate
        XCTAssertEqual(delegate.applicationShouldHandleReopen?(NSApp, hasVisibleWindows: false), false)

        XCTAssertEqual(opened, 1)
        XCTAssertEqual(NSApp.windows.count, windowsBefore, "practice lives in the popover; no window may appear")
    }
}
