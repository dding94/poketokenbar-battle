import AppKit
import SwiftUI
import Vision
import XCTest
@testable import PokeTokenBar

@MainActor
final class PracticeBattleRenderingTests: XCTestCase {
    func testNativePracticeScreenShowsRulesAndRendersRunningBattle() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let engine = try BattleEngine(url: root.appendingPathComponent("engine/dist/battle-engine.js"))
        var state = CompanionState()
        state.dex = [25, 129].enumerated().map { index, species in
            var p = PokemonProfile.generate(seed: 42, instanceID: "render-\(index)")
            p.gender = .male; p.level = 50; p.abilityName = index == 0 ? "static" : "swift-swim"
            p.moves = [PokemonKnownMove(name: index == 0 ? "thunderbolt" : "splash", learnedAtLevel: 1)]
            return DexEntry(baseID: species, finalID: species, chainOrder: [species], rarity: .common,
                            caughtAt: nil, nature: .hardy, profile: p,
                            names: [species: ["ko": index == 0 ? "피카츄" : "잉어킹"]])
        }
        let roster = PracticeRoster(state: state, engine: engine), model = PracticeBattle(engine: engine)
        let host = NSHostingView(rootView: PracticeBattleView(roster: roster, model: model, artwork: false, liveUpdates: false))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 760),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { model.cancel(); window.close() }
        for stage in ["selection", "battle"] {
            if stage == "battle" {
                model.start(player: roster.eligible[0], opponent: roster.eligible[1], mode: .manual, seed: [1,2,3,4])
            }
            try await Task.sleep(for: .milliseconds(250))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let image = try XCTUnwrap(bitmap.cgImage)
            let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US", "ko-KR"]
            try VNImageRequestHandler(cgImage: image).perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            XCTAssertTrue(text.contains("PRACTICE"), text)
            XCTAssertTrue(text.contains("200"), text)
            if stage == "battle" { XCTAssertTrue(text.contains("30"), text) }
            else { XCTAssertTrue(text.contains("스피드"), text) }
            if let path = ProcessInfo.processInfo.environment["PTB_SNAPSHOT_SCREENSHOT_DIR"] {
                let directory = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: directory.appendingPathComponent("practice-\(stage)-synthetic.png"))
            }
        }
    }
}
