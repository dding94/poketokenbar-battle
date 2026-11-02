import XCTest
import Security
@testable import PokeTokenBar

private final class OnlineKeychainStub: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: Data] = [:]
    private var calls: [(String, [String: Any])] = []
    var failWrite = false
    var operations: OnlineBattleKeychainOperations {
        .init(read: { query in self.lock.withLock {
            let query = query as! [String: Any]; self.calls.append(("read", query))
            let value = self.entries[query[kSecAttrAccount as String] as! String]
            return (value == nil ? errSecItemNotFound : errSecSuccess, value)
        } }, add: { query in self.lock.withLock {
            let query = query as! [String: Any]; self.calls.append(("add", query))
            if self.failWrite { return errSecInteractionNotAllowed }
            self.entries[query[kSecAttrAccount as String] as! String] = query[kSecValueData as String] as? Data
            return errSecSuccess
        } }, update: { query, changes in self.lock.withLock {
            let query = query as! [String: Any], changes = changes as! [String: Any]
            self.calls.append(("update", query))
            if self.failWrite { return errSecInteractionNotAllowed }
            let key = query[kSecAttrAccount as String] as! String
            guard self.entries[key] != nil else { return errSecItemNotFound }
            self.entries[key] = changes[kSecValueData as String] as? Data; return errSecSuccess
        } }, delete: { query in self.lock.withLock {
            let query = query as! [String: Any]; self.calls.append(("delete", query))
            return self.entries.removeValue(forKey: query[kSecAttrAccount as String] as! String) == nil ? errSecItemNotFound : errSecSuccess
        } })
    }
    var recorded: [(String, [String: Any])] { lock.withLock { calls } }
}
@MainActor
final class OnlineBattleCredentialsTests: XCTestCase {
    private func scope(_ profile: String = "00000000-0000-4000-8000-000000000001", host: String = "https://example.invalid") throws -> OnlineBattleCredentialScope { .init(profileID: profile, origin: try OnlineBattleOrigin(host)) }
    func testScopedCredentialRoundTripAndRotationUsesInjectedSecurityOnly() async throws {
        do {
        let stub = OnlineKeychainStub(), scope = try scope()
        let store = OnlineBattleCredentials(operations: stub.operations, gate: .init(allowsAccess: { true }))
        var value = try await store.load(scope: scope); XCTAssertNil(value)
        try await store.save("synthetic-first", scope: scope)
        value = try await store.load(scope: scope); XCTAssertEqual(value, "synthetic-first")
        try await store.save("synthetic-second", scope: scope)
        value = try await store.load(scope: scope); XCTAssertEqual(value, "synthetic-second")
        try await store.remove(scope: scope)
        value = try await store.load(scope: scope); XCTAssertNil(value)
        for (_, query) in stub.recorded {
            XCTAssertEqual(query[kSecAttrService as String] as? String, "io.github.dding94.poketokenbar-battle.online-access")
            XCTAssertEqual(query[kSecAttrAccount as String] as? String, scope.account)
        }
        let read = try XCTUnwrap(stub.recorded.first { $0.0 == "read" }?.1)
        XCTAssertEqual(read[kSecMatchLimit as String] as? String, kSecMatchLimitOne as String)
        XCTAssertEqual(read[kSecReturnData as String] as? Bool, true)
        } catch { XCTFail("Expected successful fixture operation; received \(error)") }
    }
    func testProfileAndOriginScopesCannotReadEachOthersKey() async throws {
        do {
        let stub = OnlineKeychainStub()
        let store = OnlineBattleCredentials(operations: stub.operations, gate: .init(allowsAccess: { true }))
        try await store.save("synthetic", scope: scope())
        let otherProfile = try await store.load(scope: scope("00000000-0000-4000-8000-000000000002"))
        let otherOrigin = try await store.load(scope: scope(host: "https://other.invalid"))
        XCTAssertNil(otherProfile); XCTAssertNil(otherOrigin)
        XCTAssertEqual(try scope().originHash, try scope(host: "https://EXAMPLE.INVALID:443/").originHash)
        } catch { XCTFail("Expected successful fixture operation; received \(error)") }
    }
    func testDisabledGatePerformsZeroSecurityCalls() async throws {
        do {
        let stub = OnlineKeychainStub(), scope = try scope()
        let store = OnlineBattleCredentials(operations: stub.operations, gate: .init(allowsAccess: { false }))
        do { _ = try await store.load(scope: scope); XCTFail() } catch { XCTAssertEqual(error as? OnlineBattleFailure, .credentialsDisabled) }
        do { try await store.save("synthetic", scope: scope); XCTFail() } catch { XCTAssertEqual(error as? OnlineBattleFailure, .credentialsDisabled) }
        do { try await store.remove(scope: scope); XCTFail() } catch { XCTAssertEqual(error as? OnlineBattleFailure, .credentialsDisabled) }
        XCTAssertTrue(stub.recorded.isEmpty)
        } catch { XCTFail("Expected successful fixture operation; received \(error)") }
    }
    func testStorageFailureIsNeverReportedAsSuccess() async throws {
        do {
        let stub = OnlineKeychainStub(); stub.failWrite = true
        let store = OnlineBattleCredentials(operations: stub.operations, gate: .init(allowsAccess: { true }))
        do { try await store.save("synthetic", scope: scope()); XCTFail() } catch { XCTAssertEqual(error as? OnlineBattleFailure, .credentialsUnavailable) }
        XCTAssertEqual(stub.recorded.map(\.0), ["update"])
        } catch { XCTFail("Expected successful fixture operation; received \(error)") }
    }
    func testSettingsPersistOnlyProfileAndOriginOutsideSave() throws {
        do {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        var settings = try OnlineBattleSettings.load(from: folder)
        XCTAssertNotNil(UUID(uuidString: settings.profileID))
        try settings.setServer("https://EXAMPLE.INVALID:443/"); try settings.save(to: folder)
        let reloaded = try OnlineBattleSettings.load(from: folder)
        XCTAssertEqual(settings, reloaded); XCTAssertEqual(reloaded.serverURL, "https://example.invalid")
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(files, ["online-battle-settings.json"])
        let data = try Data(contentsOf: folder.appendingPathComponent(files[0]))
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys.sorted()
        XCTAssertEqual(keys, ["profileID", "serverURL"])
        } catch { XCTFail("Expected successful fixture operation; received \(error)") }
    }
    func testSettingsFailClosedOnCorruptProfile() throws {
        do {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"profileID":"not-a-uuid","serverURL":null}"#.utf8).write(to: folder.appendingPathComponent("online-battle-settings.json"))
        XCTAssertThrowsError(try OnlineBattleSettings.load(from: folder))
        } catch { XCTFail("Expected successful fixture operation; received \(error)") }
    }
}
