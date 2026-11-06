import AppKit
import Vision
import XCTest

final class VisionOCRTests: XCTestCase {
    func testAStuckCallFailsWithinItsLimitAndLaterCallsFailAtOnceUntilItEnds() throws {
        let gate = VisionOCR.Gate()
        let release = DispatchSemaphore(value: 0)
        let ended = DispatchSemaphore(value: 0)
        let started = ContinuousClock.now
        XCTAssertThrowsError(try gate.run(limit: .milliseconds(200), .init { release.wait(); ended.signal() })) {
            XCTAssertTrue($0 is VisionOCR.Stalled, "\($0)")
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))

        let later = ContinuousClock.now
        var ran = false
        XCTAssertThrowsError(try gate.run(limit: .seconds(30), .init { ran = true })) {
            XCTAssertTrue($0 is VisionOCR.Stalled, "\($0)")
        }
        XCTAssertFalse(ran, "a later call must not start behind the stuck one")
        XCTAssertLessThan(ContinuousClock.now - later, .seconds(5), "a later call must not wait out its own limit")

        release.signal()
        ended.wait()
        var recovered = false
        for _ in 0..<100 where !recovered {   // the stuck thread clears the gate just after `ended`
            try? gate.run(limit: .seconds(30), .init { recovered = true })
            if !recovered { Thread.sleep(forTimeInterval: 0.02) }
        }
        XCTAssertTrue(recovered, "the gate opens again once the stuck call has ended")
    }

    func testACallsOwnErrorComesBackAndLeavesTheGateOpen() throws {
        struct Failure: Error {}
        let gate = VisionOCR.Gate()
        XCTAssertThrowsError(try gate.run(limit: .seconds(30), .init { throw Failure() })) {
            XCTAssertTrue($0 is Failure, "\($0)")
        }
        var ran = false
        try gate.run(limit: .seconds(30), .init { ran = true })
        XCTAssertTrue(ran)
    }

    func testARealRequestDeliversItsResults() throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 100, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 400, height: 100).fill()
        ("Pokedex" as NSString).draw(at: NSPoint(x: 20, y: 30), withAttributes: [.font: NSFont.systemFont(ofSize: 36)])
        NSGraphicsContext.restoreGraphicsState()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.recognitionLanguages = ["en-US"]
        try VisionOCR.perform(request, on: XCTUnwrap(rep.cgImage))
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined()
        XCTAssertTrue(text.localizedCaseInsensitiveContains("pokedex"), text)
    }

    /// A direct call has no limit, and one stuck call stops the whole run with nothing printed.
    func testEveryOCRCallInTheTestsHasALimit() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var offenders: [String] = []
        for case let url as URL in try XCTUnwrap(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
        where url.pathExtension == "swift" && !["VisionOCR.swift", "VisionOCRTests.swift"].contains(url.lastPathComponent) {
            if try String(contentsOf: url, encoding: .utf8).contains("VNImageRequestHandler(") {
                offenders.append(url.lastPathComponent)
            }
        }
        XCTAssertEqual(offenders, [], "use VisionOCR.perform")
    }
}
