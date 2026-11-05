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
    func testReadAddAndDeleteFailuresUseFixedErrors() async throws {
        let scope = try scope()
        let operations = OnlineBattleKeychainOperations(read: { _ in (errSecInteractionNotAllowed, nil) }, add: { _ in errSecInteractionNotAllowed }, update: { _, _ in errSecItemNotFound }, delete: { _ in errSecInteractionNotAllowed })
        let store = OnlineBattleCredentials(operations: operations, gate: .init(allowsAccess: { true }))
        do { _ = try await store.load(scope: scope); XCTFail() } catch { XCTAssertEqual(error as? OnlineBattleFailure, .credentialsUnavailable) }
        do { try await store.save("synthetic", scope: scope); XCTFail() } catch { XCTAssertEqual(error as? OnlineBattleFailure, .credentialsUnavailable) }
        do { try await store.remove(scope: scope); XCTFail() } catch { XCTAssertEqual(error as? OnlineBattleFailure, .credentialsUnavailable) }
        do { try await store.save("", scope: scope); XCTFail() } catch { XCTAssertEqual(error as? OnlineBattleFailure, .credentialsUnavailable) }
    }
    func testCorruptStoredBytesAndInvalidScopeFailWithoutCrossScopeReads() async throws {
        let operations = OnlineBattleKeychainOperations(read: { _ in (errSecSuccess, Data([0xff])) }, add: { _ in errSecSuccess }, update: { _, _ in errSecSuccess }, delete: { _ in errSecItemNotFound })
        let store = OnlineBattleCredentials(operations: operations, gate: .init(allowsAccess: { true }))
        do { _ = try await store.load(scope: scope()); XCTFail() } catch { XCTAssertEqual(error as? OnlineBattleFailure, .credentialsUnavailable) }
        do { _ = try await store.load(scope: scope("invalid-profile")); XCTFail() } catch { XCTAssertEqual(error as? OnlineBattleFailure, .invalidSettings) }
        try await store.remove(scope: scope())
        let invalid = OnlineBattleSettings(profileID: "invalid-profile", serverURL: nil)
        XCTAssertThrowsError(try invalid.save(to: URL(fileURLWithPath: "/private/tmp/never-written-invalid-profile")))
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
    // MARK: T08 — build-time embedded server address
    private func settingsFolder(stored: String?) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var settings = try OnlineBattleSettings.load(from: folder)
        if let stored { try settings.setServer(stored); try settings.save(to: folder) }
        return folder
    }
    private func storedJSONServer(_ folder: URL) throws -> String? {
        let data = try Data(contentsOf: folder.appendingPathComponent("online-battle-settings.json"))
        return (try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]))["serverURL"] as? String
    }
    private func account(_ settings: OnlineBattleSettings) throws -> String {
        OnlineBattleCredentialScope(profileID: settings.profileID, origin: try OnlineBattleOrigin(try XCTUnwrap(settings.serverURL))).account
    }
    func testEmbeddedAddressOverridesStoredAddressWithoutRewritingTheStoredFile() throws {
        let folder = try settingsFolder(stored: "https://stored.example.test")
        defer { try? FileManager.default.removeItem(at: folder) }
        let settings = try OnlineBattleSettings.load(from: folder, embeddedServerURL: "https://embedded.example.test")
        XCTAssertEqual(settings.serverURL, "https://embedded.example.test")
        XCTAssertTrue(settings.serverIsEmbedded)
        XCTAssertEqual(settings.storedServerURL, "https://stored.example.test")
        try settings.save(to: folder)
        XCTAssertEqual(try storedJSONServer(folder), "https://stored.example.test")
        let manual = try OnlineBattleSettings.load(from: folder, embeddedServerURL: nil)
        XCTAssertEqual(manual.serverURL, "https://stored.example.test")
    }
    func testWithoutEmbeddedAddressStoredAddressStaysManual() throws {
        let folder = try settingsFolder(stored: "https://stored.example.test")
        defer { try? FileManager.default.removeItem(at: folder) }
        let settings = try OnlineBattleSettings.load(from: folder, embeddedServerURL: nil)
        XCTAssertEqual(settings.serverURL, "https://stored.example.test")
        XCTAssertFalse(settings.serverIsEmbedded)
        var editable = settings
        XCTAssertNoThrow(try editable.setServer("https://other.example.test"))
        XCTAssertEqual(editable.serverURL, "https://other.example.test")
    }
    func testEmbeddedAddressWithNoStoredAddressIsUsedAndNotPersisted() throws {
        let folder = try settingsFolder(stored: nil)
        defer { try? FileManager.default.removeItem(at: folder) }
        let settings = try OnlineBattleSettings.load(from: folder, embeddedServerURL: "https://example.test/")
        XCTAssertEqual(settings.serverURL, "https://example.test")
        XCTAssertTrue(settings.serverIsEmbedded)
        try settings.save(to: folder)
        XCTAssertNil(try storedJSONServer(folder))
    }
    func testEmbeddedAddressSameAsStoredKeepsTheExistingKeychainScope() throws {
        let folder = try settingsFolder(stored: "https://example.test")
        defer { try? FileManager.default.removeItem(at: folder) }
        let stored = try OnlineBattleSettings.load(from: folder, embeddedServerURL: nil)
        // Different spellings of the same origin must normalize to the same hash, or the saved key is orphaned.
        for spelling in ["https://example.test", "https://example.test/", "HTTPS://Example.TEST:443/"] {
            let embedded = try OnlineBattleSettings.load(from: folder, embeddedServerURL: spelling)
            XCTAssertTrue(embedded.serverIsEmbedded, spelling)
            XCTAssertEqual(embedded.profileID, stored.profileID)
            XCTAssertEqual(try account(embedded), try account(stored), spelling)
        }
        let different = try OnlineBattleSettings.load(from: folder, embeddedServerURL: "https://other.example.test")
        XCTAssertNotEqual(try account(different), try account(stored))
    }
    func testInvalidEmbeddedValuesAreIgnoredAndManualEntryRemains() throws {
        let folder = try settingsFolder(stored: "https://stored.example.test")
        defer { try? FileManager.default.removeItem(at: folder) }
        for bad in ["", "   ", "http://example.test", "https://example.test/path", "https://example.test?x=1",
                    "https://user@example.test", "$(PTB_BATTLE_SERVER_URL)", "not a url"] {
            let settings = try OnlineBattleSettings.load(from: folder, embeddedServerURL: bad)
            XCTAssertFalse(settings.serverIsEmbedded, bad)
            XCTAssertEqual(settings.serverURL, "https://stored.example.test", bad)
        }
    }
    func testEmbeddedAddressRejectsManualServerChanges() throws {
        let folder = try settingsFolder(stored: nil)
        defer { try? FileManager.default.removeItem(at: folder) }
        var settings = try OnlineBattleSettings.load(from: folder, embeddedServerURL: "https://example.test")
        XCTAssertThrowsError(try settings.setServer("https://other.example.test")) {
            XCTAssertEqual($0 as? OnlineBattleFailure, .invalidSettings)
        }
        XCTAssertEqual(settings.serverURL, "https://example.test")
    }
    func testEmbeddedServerReadsOnlyTheInfoPlistStringKey() {
        XCTAssertEqual(OnlineBattleEmbeddedServer.infoKey, "PTBBattleServerURL")
        XCTAssertEqual(OnlineBattleEmbeddedServer.address(infoDictionary: ["PTBBattleServerURL": "https://example.test/"]), "https://example.test")
        XCTAssertNil(OnlineBattleEmbeddedServer.address(infoDictionary: nil))
        XCTAssertNil(OnlineBattleEmbeddedServer.address(infoDictionary: [:]))
        XCTAssertNil(OnlineBattleEmbeddedServer.address(infoDictionary: ["PTBBattleServerURL": 7]))
        XCTAssertNil(OnlineBattleEmbeddedServer.address(infoDictionary: ["PTBBattleServerURL": ""]))
        XCTAssertNil(OnlineBattleEmbeddedServer.address(infoDictionary: ["PTBBattleServerURL": "http://example.test"]))
        XCTAssertNil(OnlineBattleEmbeddedServer.configured, "The test host bundle must carry no embedded address")
    }
}
