import AppKit
import XCTest
@testable import PokeTokenBar

@MainActor
final class PracticeWindowTests: XCTestCase {
    private func makeController() -> PracticeWindowController {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return PracticeWindowController(engineURL: root.appendingPathComponent("engine/dist/battle-engine.js"), artwork: false)
    }

    func testFinderReopenCreatesAWindowAfterClosingIt() throws {
        let controller = makeController()
        let appDelegate = AppDelegate()
        appDelegate.onOpenPractice = { controller.open(state: CompanionState(), activeName: nil) }
        appDelegate.onOpenPractice?()
        let first = try XCTUnwrap(controller.window)
        first.close()
        XCTAssertNil(controller.window)
        XCTAssertNil(controller.model)
        defer { controller.window?.close() }

        let delegate: NSApplicationDelegate = appDelegate
        XCTAssertEqual(delegate.applicationShouldHandleReopen?(NSApp, hasVisibleWindows: false), false)
        XCTAssertNotNil(controller.window, "Finder reopening a running menu bar app must recreate its closed practice window")
        XCTAssertTrue(controller.window?.isVisible == true)
        XCTAssertFalse(controller.window === first)
    }

    func testOpenRestoresHiddenAndMinimizedWindowWithoutReplacingSession() async throws {
        let controller = makeController()
        controller.open(state: CompanionState(), activeName: nil)
        let window = try XCTUnwrap(controller.window), model = try XCTUnwrap(controller.model)
        defer { controller.window?.close() }
        window.orderOut(nil)
        XCTAssertFalse(window.isVisible)
        controller.open(state: CompanionState(), activeName: nil)
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(controller.model === model)

        window.miniaturize(nil)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(window.isMiniaturized)
        let appDelegate = AppDelegate()
        appDelegate.onOpenPractice = { controller.open(state: CompanionState(), activeName: nil) }
        let delegate: NSApplicationDelegate = appDelegate
        // AppKit counts minimized windows as visible when dispatching a reopen event.
        XCTAssertEqual(delegate.applicationShouldHandleReopen?(NSApp, hasVisibleWindows: true), false)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(window.isMiniaturized)
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(controller.window === window)
        XCTAssertTrue(controller.model === model)
    }
}
