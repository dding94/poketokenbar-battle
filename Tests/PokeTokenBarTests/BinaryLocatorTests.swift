import XCTest
@testable import PokeTokenBar

final class BinaryLocatorTests: XCTestCase {
    /// mise shim 이 버전매니저 본체를 찾을 수 있도록 PATH 가 보강되는지 (버그 리포트 시나리오).
    func testAugmentedEnvironmentPrependsToolPaths() {
        let home = NSHomeDirectory()
        let env = BinaryLocator.augmentedEnvironment(
            binaryPath: "\(home)/.local/share/mise/shims/codex",
            base: ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"])
        let paths = env["PATH"]!.split(separator: ":").map(String.init)

        XCTAssertEqual(paths.first, "\(home)/.local/share/mise/shims")   // 바이너리 디렉토리 최우선
        XCTAssertTrue(paths.contains("/opt/homebrew/bin"))               // mise 본체 위치 후보
        XCTAssertTrue(paths.contains("\(home)/.local/bin"))
        XCTAssertTrue(paths.contains("/usr/bin"))                        // 기존 PATH 보존
        XCTAssertEqual(paths.filter { $0 == "\(home)/.local/share/mise/shims" }.count, 1)  // dedup
        XCTAssertEqual(env["LANG"], "en_US.UTF-8")                       // 다른 env 보존
    }

    func testAugmentedEnvironmentWithoutBasePath() {
        let env = BinaryLocator.augmentedEnvironment(
            binaryPath: "/opt/homebrew/bin/codex", base: [:])
        let paths = env["PATH"]!.split(separator: ":").map(String.init)
        XCTAssertEqual(paths.first, "/opt/homebrew/bin")
        XCTAssertTrue(paths.contains("/usr/bin"))   // 기본 PATH 폴백
    }

    func testParsesCleanMarkedPath() {
        XCTAssertEqual(
            BinaryLocator.parseMarkedPath("<<<BIN:/opt/homebrew/bin/ccusage:BIN>>>"),
            "/opt/homebrew/bin/ccusage")
    }

    func testIgnoresProfileNoiseAroundMarker() {
        // 인터랙티브 셸이 neofetch 등 stdout noise 를 찍어도 마커만 추출
        let noisy = """
        ⠀⣴⣶⣷ neofetch art line 1
        OS: macOS / Shell: zsh
        <<<BIN:/Users/x/.local/share/mise/installs/node/22.14.0/bin/ccusage:BIN>>>
        """
        XCTAssertEqual(
            BinaryLocator.parseMarkedPath(noisy),
            "/Users/x/.local/share/mise/installs/node/22.14.0/bin/ccusage")
    }

    func testEmptyPathReturnsNil() {
        // command -v 가 못 찾으면 마커 사이가 비어 있음
        XCTAssertNil(BinaryLocator.parseMarkedPath("noise\n<<<BIN::BIN>>>\n"))
    }

    func testMissingMarkersReturnsNil() {
        XCTAssertNil(BinaryLocator.parseMarkedPath("just some neofetch output, no marker"))
        XCTAssertNil(BinaryLocator.parseMarkedPath("<<<BIN:/path/without/closing"))
    }

    func testTrimsWhitespace() {
        XCTAssertEqual(BinaryLocator.parseMarkedPath("<<<BIN:  /usr/local/bin/codex \n :BIN>>>"),
                       "/usr/local/bin/codex")
    }

    func testCommonPathsIncludeManagersForBinary() {
        let paths = BinaryLocator.commonNodeToolPaths("ccusage")
        XCTAssertTrue(paths.contains("/opt/homebrew/bin/ccusage"))
        XCTAssertTrue(paths.contains { $0.contains("/.local/share/mise/shims/ccusage") })
        XCTAssertTrue(paths.contains { $0.contains("/.asdf/shims/ccusage") })
        XCTAssertTrue(paths.contains { $0.contains("/.volta/bin/ccusage") })
    }

    /// These FileHandle reads raise an Objective-C exception on failure, and Swift cannot catch it: the whole app goes
    /// down. The locator's deadline closes the handle under its reader, which killed a CI run on macOS 15 (2026-11-05).
    /// It did not reproduce on macOS 27, so the guard is on the API itself. `readToEnd()` and `read(upToCount:)` throw instead.
    func testNoSourceUsesAFileHandleReadThatRaises() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        var offenders: [String] = []
        for case let url as URL in try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for api in [".readDataToEndOfFile()", ".readData(ofLength", ".availableData"] where text.contains(api) {
                offenders.append("\(url.lastPathComponent): \(api)")
            }
        }
        XCTAssertEqual(offenders, [])
    }
}
