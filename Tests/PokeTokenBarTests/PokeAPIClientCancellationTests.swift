import XCTest
@testable import PokeTokenBar

/// A cancelled request is not a failed one. These tests pin the side effects `catch` blocks used to run when a
/// cancelled task surfaced as an ordinary error: the REST base-index crawl, a stale details fallback that poisons
/// the memory cache, and a "failed" marker for a load nobody was waiting for any more.
///
/// The stub answers only PokéAPI hosts, stalls the requests a test wants to cancel until the task is cancelled, and
/// fails every other request at once, so no real network is touched before or after the fix.
final class PokeAPIStubProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var counts: [String: Int] = [:]
    nonisolated(unsafe) private static var stalled: Set<String> = []

    static func reset(stalling kinds: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        counts = [:]; stalled = kinds
    }
    static func stop(stalling kind: String) {
        lock.lock(); defer { lock.unlock() }
        stalled.remove(kind)
    }
    static func count(_ kind: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return counts[kind, default: 0]
    }
    private static func kind(of url: URL) -> String {
        if url.host == "graphql.pokeapi.co" { return "graphql" }
        if url.path.contains("/pokemon-species/") { return "species" }
        if url.path.contains("/pokemon/") { return "pokemon" }
        return "other"
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return host == "graphql.pokeapi.co" || host == "pokeapi.co"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let kind = Self.kind(of: url)
        Self.lock.lock()
        Self.counts[kind, default: 0] += 1
        let stall = Self.stalled.contains(kind)
        Self.lock.unlock()
        // A stalled request never answers: only the cancellation of its task ends it (URLError.cancelled).
        if !stall { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    }
    override func stopLoading() {}
}

private struct StoredDetails: Codable { let fetchedAt: Date; let details: PokemonDetails }

/// A details provider whose request is held open until released, then fails the way URLSession reports a cancel.
private actor GatedDetailsProvider: PokeProviding, PokemonDetailProviding {
    private var continuation: CheckedContinuation<Void, Never>?
    func line(baseSpeciesID: Int) async throws -> EvoLine { throw URLError(.cancelled) }
    func baseSpeciesIndex() async throws -> [BaseSpecies] { [] }
    func baseSpecies(id: Int) async throws -> BaseSpecies? { nil }
    func pokemonDetails(speciesID: Int) async throws -> PokemonDetails {
        await withCheckedContinuation { continuation = $0 }
        throw URLError(.cancelled)
    }
    func isSuspended() -> Bool { continuation != nil }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
final class PokeAPIClientCancellationTests: XCTestCase {
    nonisolated(unsafe) private var directory: URL!
    nonisolated(unsafe) private var suites: [String] = []

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("pokeapi-cancel-\(UUID())")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        PokeAPIStubProtocol.reset(stalling: [])
        URLProtocol.registerClass(PokeAPIStubProtocol.self)
    }
    override func tearDown() {
        URLProtocol.unregisterClass(PokeAPIStubProtocol.self)
        PokeAPIStubProtocol.reset(stalling: [])
        try? FileManager.default.removeItem(at: directory)
        for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return condition()
    }
    /// Until the species request count stops moving, so a crawl a broken build started cannot outlive the stub.
    private func quiesce() async {
        var last = -1, stable = 0
        for _ in 0..<100 where stable < 4 {
            let now = PokeAPIStubProtocol.count("species")
            stable = now == last ? stable + 1 : 0
            last = now
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func testCancelledGraphQLIndexRequestDoesNotStartTheRESTCrawl() async throws {
        let file = directory.appendingPathComponent("base-index.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "no disk cache, or the fallbacks would not run")
        PokeAPIStubProtocol.reset(stalling: ["graphql"])
        let client = PokeAPIClient(baseIndexFile: file, detailsDirectory: directory)
        let task = Task { try await client.baseSpeciesIndex() }
        let reached = await waitUntil { PokeAPIStubProtocol.count("graphql") > 0 }
        XCTAssertTrue(reached, "the index request is in flight")
        task.cancel()
        do {
            let index = try await task.value
            XCTFail("a cancelled index request returned \(index.count) entries")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        let triggered = await client.didTriggerRESTIndexBuild
        XCTAssertFalse(triggered, "a cancel is not a GraphQL outage and must not spend the once-per-session crawl")
        XCTAssertEqual(PokeAPIStubProtocol.count("species"), 0, "no pokemon-species request")
        await quiesce()
        XCTAssertEqual(PokeAPIStubProtocol.count("species"), 0, "no crawl started in the background either")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    /// Control: a real outage (not a cancel) still triggers the crawl once, so the guard did not switch it off.
    func testGraphQLOutageStillTriggersTheRESTCrawlOnce() async throws {
        let file = directory.appendingPathComponent("base-index.json")
        PokeAPIStubProtocol.reset(stalling: [])
        let client = PokeAPIClient(baseIndexFile: file, detailsDirectory: directory)
        do {
            _ = try await client.baseSpeciesIndex()
            XCTFail("expected the failed GraphQL request to throw")
        } catch {
            XCTAssertFalse(error is CancellationError, "\(error)")
        }
        let triggered = await client.didTriggerRESTIndexBuild
        XCTAssertTrue(triggered)
        // Wait for the whole crawl (one request per species but Ditto): tearDown unregisters the stub, and a crawl
        // still running then would reach the real PokéAPI. Slow runners need more than the quiesce window.
        let crawl = PokemonAssets.animatedSpeciesIDs.filter { $0 != PokemonOdds.dittoSpeciesID }.count
        let finished = await waitUntil(timeout: 60) { PokeAPIStubProtocol.count("species") >= crawl }
        XCTAssertTrue(finished, "the crawl asked for \(PokeAPIStubProtocol.count("species")) of \(crawl) species")
        await quiesce()
    }

    func testCancelledDetailsRequestThrowsInsteadOfServingAndCachingTheStaleDiskEntry() async throws {
        let stale = PokemonDetails(speciesID: 25, name: "pikachu", height: 4, weight: 60, baseExperience: 112,
                                   genderRate: 4, types: ["electric"], baseStats: ["hp": 35], abilities: [], moves: [])
        let snapshot = StoredDetails(fetchedAt: Date().addingTimeInterval(-40 * 86400), details: stale)
        try JSONEncoder().encode(snapshot).write(to: directory.appendingPathComponent("25.json"))
        PokeAPIStubProtocol.reset(stalling: ["pokemon"])
        let client = PokeAPIClient(baseIndexFile: directory.appendingPathComponent("base-index.json"), detailsDirectory: directory)
        let task = Task { try await client.pokemonDetails(speciesID: 25) }
        let reached = await waitUntil { PokeAPIStubProtocol.count("pokemon") > 0 }
        XCTAssertTrue(reached)
        task.cancel()
        do {
            let served = try await task.value
            XCTFail("a cancelled request served \(served.name) from the stale disk entry")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        // The next, uncancelled call must go back to the network, not to a memory cache the cancel filled.
        PokeAPIStubProtocol.stop(stalling: "pokemon")
        let again = try await client.pokemonDetails(speciesID: 25)
        XCTAssertEqual(again.name, "pikachu", "offline now: the stale disk entry is a legitimate fallback")
        XCTAssertEqual(PokeAPIStubProtocol.count("pokemon"), 2, "the second call asked the network again")
    }

    func testCancelledDetailLoadIsNotRecordedAsAFailure() async throws {
        let gate = GatedDetailsProvider()
        let suite = "pokeapi-cancel-\(UUID())"
        suites.append(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let store = CompanionStore(provider: gate, detailProvider: gate, clock: Date.init,
                                   fileURL: directory.appendingPathComponent("state.json"),
                                   dittoDisguiseRollingEnabled: false, defaults: defaults)
        // Cancelled while in flight (the Dex page was closed): nothing failed, so nothing is marked.
        let cancelled = Task { await store.loadPokemonDetails(speciesID: 7) }
        var suspended = false
        for _ in 0..<2500 where !suspended {
            suspended = await gate.isSuspended()
            if !suspended { try? await Task.sleep(nanoseconds: 2_000_000) }
        }
        XCTAssertTrue(suspended)
        cancelled.cancel()
        await gate.release()
        await cancelled.value
        XCTAssertTrue(store.failedPokemonDetailIDs.isEmpty, "a cancelled load is not a failed one")
        // Control: the same error without a cancel is still a failure.
        let plain = Task { await store.loadPokemonDetails(speciesID: 7) }
        suspended = false
        for _ in 0..<2500 where !suspended {
            suspended = await gate.isSuspended()
            if !suspended { try? await Task.sleep(nanoseconds: 2_000_000) }
        }
        XCTAssertTrue(suspended)
        await gate.release()
        await plain.value
        XCTAssertEqual(store.failedPokemonDetailIDs, [7])
    }
}
