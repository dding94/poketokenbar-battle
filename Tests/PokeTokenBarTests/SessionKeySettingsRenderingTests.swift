import AppKit
import SwiftUI
import Vision
import XCTest
@testable import PokeTokenBar

/// Used for the optional keyboard-focus check on an interactive desktop.
private final class SessionKeyTestWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class SessionKeySettingsRenderingTests: XCTestCase {
    func testSessionKeyEntryOpensInsideViewportAndPreservesDifficultyControls() async throws {
        let suite = "SessionKeySettingsRendering-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(suite).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let usage = UsageStore(providers: [], autoRefresh: false, defaults: defaults)
        let companion = CompanionStore(fileURL: file, defaults: defaults)
        companion.setLanguage(.en)
        let navigation = PopoverNavigation()
        navigation.openSessionKeySettings()
        let host = NSHostingController(rootView: SettingsView(
            onClose: {}, onChooseRepresentative: {}, startExpanded: navigation.expandAdvancedOnOpen)
            .environment(usage).environment(companion).environment(UpdateChecker())
            .frame(width: PopoverMetrics.width))
        let previousKeyWindow = NSApp.keyWindow
        let window = SessionKeyTestWindow(contentRect: NSRect(x: -10000, y: -10000, width: PopoverMetrics.width, height: 460),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = host
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            previousKeyWindow?.makeKey()
        }
        host.view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        host.view.layoutSubtreeIfNeeded()
        let views = descendants(of: host.view)
        let secure = try XCTUnwrap(views.compactMap { $0 as? NSSecureTextField }.first)
        let rect = secure.convert(secure.bounds, to: host.view)
        XCTAssertTrue(host.view.bounds.contains(rect), "session key entry must be visible after scrolling")
        // Hosted CI renders the layout but does not grant this XCTest window an editor.
        // Verify keyboard focus on an interactive Mac with PTB_VERIFY_KEYBOARD_FOCUS=1.
        if ProcessInfo.processInfo.environment["PTB_VERIFY_KEYBOARD_FOCUS"] == "1" {
            XCTAssertNotNil(secure.currentEditor(), "session key entry must receive keyboard focus")
            XCTAssertTrue(secure.currentEditor() === window.firstResponder)
        }
        try await assertDifficultyControlsAreDrawn(l: companion.l, around: secure, in: host.view)
        XCTAssertTrue(navigation.showSettings)
        navigation.reset()
        XCTAssertFalse(navigation.expandAdvancedOnOpen)
    }

    /// Reads the growth and shop rows off the pixels, one screenful at a time: linked against the macOS 27 SDK
    /// a SwiftUI slider has no `NSSlider` to count (defect log).
    private func assertDifficultyControlsAreDrawn(l: L, around field: NSView, in host: NSView) async throws {
        let scroll = try XCTUnwrap(field.enclosingScrollView)
        let clip = scroll.contentView
        let height = try XCTUnwrap(scroll.documentView).frame.height
        var seen = ""
        for y in stride(from: 0, to: height, by: clip.bounds.height * 0.75) {
            clip.scroll(to: NSPoint(x: 0, y: clip.isFlipped ? y : height - clip.bounds.height - y))
            scroll.reflectScrolledClipView(clip)
            try await Task.sleep(for: .milliseconds(100))
            let image = try XCTUnwrap(PracticeScreenRenderingTests.capture2x(host).cgImage)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate; request.recognitionLanguages = ["en-US"]
            try VisionOCR.perform(request, on: image)
            seen += (request.results ?? []).flatMap { $0.topCandidates(3).map(\.string) }.joined(separator: " ") + " "
        }
        let compact = { (text: String) in text.filter { !$0.isWhitespace }.lowercased() }
        for label in [l.difficultySectionTitle, l.difficultyGrowthLabel, l.difficultyShopLabel,
                      l.difficultyGrowthLowLabel, l.difficultyShopLowLabel] {
            XCTAssertTrue(compact(seen).contains(compact(label)),
                          "\(label): growth and shop difficulty controls must survive the Settings merge. Seen: \(seen)")
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }
}
