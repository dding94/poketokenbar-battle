import XCTest

/// A `UsageStore` built without `providers:` holds the real providers, so anything beyond reading
/// its registry can start a refresh over the machine's real usage logs. That refresh outlives the
/// test and blocks the next one on `LocalUsageCache.shared`: one such store made a 0.9-second Grok
/// test take 49 seconds, only on machines with large logs. CI has none, so only a scan can catch it.
final class UsageStoreTestIsolationGuardTests: XCTestCase {

    func testStoresWithRealProvidersOnlyReadTheRegistry() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let ownName = URL(fileURLWithPath: #filePath).lastPathComponent
        let files = try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != ownName }
        XCTAssertGreaterThan(files.count, 100, "the scan must see the whole test target")

        var scannedStores = 0
        var offenders: [String] = []
        for file in files {
            let result = Self.scan(try String(contentsOf: file, encoding: .utf8))
            scannedStores += result.realProviderStores
            offenders += result.offendingLines.map { "\(file.lastPathComponent):\($0)" }
        }
        XCTAssertGreaterThan(scannedStores, 0, "the scan must find the registry readers")
        XCTAssertEqual(offenders, [], "inject providers: these stores can refresh over real usage logs")
    }

    func testScanFlagsAStoreThatDoesMoreThanReadTheRegistry() {
        let flagged = Self.scan("""
            func testA() {
                let store = UsageStore(autoRefresh: false, defaults: defaults)
                store.setCustomScanRoots("x", for: "codex")
            }
            """)
        XCTAssertEqual(flagged.offendingLines, [2])

        let handedOff = Self.scan("""
            func testB() {
                let store = UsageStore(autoRefresh: false)
                consume(store)
            }
            """)
        XCTAssertEqual(handedOff.offendingLines, [2], "passing the store on can start a refresh too")

        let returned = Self.scan("""
            func makeStore() -> UsageStore {
                return UsageStore(autoRefresh: false)
            }
            """)
        XCTAssertEqual(returned.offendingLines, [2], "a store that leaves the function is not bounded")
    }

    func testScanAcceptsRegistryReadsAndInjectedProviders() {
        let accepted = Self.scan("""
            func testA() {
                let store = UsageStore(autoRefresh: false,
                                       defaults: defaults)
                XCTAssertTrue(store.registeredProviderIDs.contains("grok"))
            }
            func testB() {
                let ids = UsageStore(autoRefresh: false).registeredProviderIDs
                XCTAssertFalse(ids.isEmpty)
            }
            func testC() {
                let store = UsageStore(providers: [fake], autoRefresh: false)
                store.setCustomScanRoots("x", for: "codex")
            }
            // UsageStore(autoRefresh: false) in a comment is not a store.
            """)
        XCTAssertEqual(accepted.offendingLines, [])
        XCTAssertEqual(accepted.realProviderStores, 2)
    }

    private static func scan(_ source: String) -> (realProviderStores: Int, offendingLines: [Int]) {
        let marker = "UsageStore("
        var realProviderStores = 0
        var offendingLines: [Int] = []
        var cursor = source.startIndex

        while let match = source.range(of: marker, range: cursor..<source.endIndex) {
            cursor = match.upperBound
            let lineStart = source[..<match.lowerBound].lastIndex(of: "\n")
                .map { source.index(after: $0) } ?? source.startIndex
            let prefix = source[lineStart..<match.lowerBound]
            if prefix.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
            if let before = prefix.last, before.isLetter || before.isNumber || before == "_" { continue }

            var depth = 1
            var end = match.upperBound
            while depth > 0, end < source.endIndex {
                if source[end] == "(" { depth += 1 }
                if source[end] == ")" { depth -= 1 }
                end = source.index(after: end)
            }
            if source[match.upperBound..<end].contains("providers:") { continue }

            realProviderStores += 1
            let line = source[..<match.lowerBound].filter { $0 == "\n" }.count + 1
            if source[end...].hasPrefix(".registeredProviderIDs") { continue }

            let words = prefix.split(whereSeparator: \.isWhitespace)
            guard words.count == 3, words[0] == "let", words[2] == "=" else {
                offendingLines.append(line)
                continue
            }
            let name = String(words[1])
            let rest = source[end...]
            let body = rest.range(of: "\n    func ").map { rest[..<$0.lowerBound] }
                ?? rest.range(of: "\nfunc ").map { rest[..<$0.lowerBound] }
                ?? rest
            if usesAnythingButTheRegistry(name, in: body) { offendingLines.append(line) }
        }
        return (realProviderStores, offendingLines)
    }

    private static func usesAnythingButTheRegistry(_ name: String, in body: Substring) -> Bool {
        var cursor = body.startIndex
        while let use = body.range(of: name, range: cursor..<body.endIndex) {
            cursor = use.upperBound
            if use.lowerBound > body.startIndex {
                let before = body[body.index(before: use.lowerBound)]
                if before.isLetter || before.isNumber || before == "_" { continue }
            }
            if let after = body[use.upperBound...].first, after.isLetter || after.isNumber || after == "_" {
                continue
            }
            if !body[use.upperBound...].hasPrefix(".registeredProviderIDs") { return true }
        }
        return false
    }
}
