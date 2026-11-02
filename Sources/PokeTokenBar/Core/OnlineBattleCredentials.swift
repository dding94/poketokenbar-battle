import Foundation
import Security

/// Not part of CompanionState or its exports. No credentials are ever written here.
struct OnlineBattleSettings: Codable, Equatable, Sendable {
    let profileID: String
    var serverURL: String?
    static func load(from stateDirectory: URL) throws -> Self {
        let url = stateDirectory.appendingPathComponent("online-battle-settings.json")
        if FileManager.default.fileExists(atPath: url.path) {
            let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
            guard UUID(uuidString: value.profileID) != nil else { throw OnlineBattleFailure.invalidSettings }
            if let serverURL = value.serverURL { _ = try OnlineBattleOrigin(serverURL) }
            return value
        }
        let value = Self(profileID: UUID().uuidString, serverURL: nil)
        try value.save(to: stateDirectory)
        return value
    }
    func save(to stateDirectory: URL) throws {
        guard UUID(uuidString: profileID) != nil else { throw OnlineBattleFailure.invalidSettings }
        if let serverURL { _ = try OnlineBattleOrigin(serverURL) }
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let url = stateDirectory.appendingPathComponent("online-battle-settings.json")
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    mutating func setServer(_ value: String?) throws {
        serverURL = try value.map { try OnlineBattleOrigin($0).url.absoluteString }
    }
}
struct OnlineBattleCredentialScope: Equatable, Sendable {
    static let service = "io.github.dding94.poketokenbar-battle.online-access"
    let profileID: String
    let originHash: String
    init(profileID: String, origin: OnlineBattleOrigin) { self.profileID = profileID; originHash = origin.hash }
    var account: String { profileID + ":" + originHash }
}
/// Product policy is supplied by the session; this layer does not read provider defaults.
struct OnlineBattleCredentialAccessGate: Sendable {
    var allowsAccess: @Sendable () -> Bool
    init(allowsAccess: @escaping @Sendable () -> Bool) { self.allowsAccess = allowsAccess }
}
struct OnlineBattleKeychainOperations: Sendable {
    var read: @Sendable (CFDictionary) -> (OSStatus, Data?)
    var add: @Sendable (CFDictionary) -> OSStatus
    var update: @Sendable (CFDictionary, CFDictionary) -> OSStatus
    var delete: @Sendable (CFDictionary) -> OSStatus
    static let live = Self(
        read: { query in
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query, &result)
            return (status, result as? Data)
        },
        add: { SecItemAdd($0, nil) }, update: { SecItemUpdate($0, $1) }, delete: { SecItemDelete($0) }
    )
}
protocol OnlineBattleCredentialStoring: Sendable {
    func load(scope: OnlineBattleCredentialScope) async throws -> String?
    func save(_ accessKey: String, scope: OnlineBattleCredentialScope) async throws
    func remove(scope: OnlineBattleCredentialScope) async throws
}
actor OnlineBattleCredentials: OnlineBattleCredentialStoring {
    private let operations: OnlineBattleKeychainOperations
    private let gate: OnlineBattleCredentialAccessGate
    init(operations: OnlineBattleKeychainOperations = .live, gate: OnlineBattleCredentialAccessGate) {
        self.operations = operations; self.gate = gate
    }
    private func query(_ scope: OnlineBattleCredentialScope) throws -> [String: Any] {
        throw OnlineBattleFailure.credentialsUnavailable // RED scaffold
        guard gate.allowsAccess() else { throw OnlineBattleFailure.credentialsDisabled }
        guard UUID(uuidString: scope.profileID) != nil else { throw OnlineBattleFailure.invalidSettings }
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: OnlineBattleCredentialScope.service,
                kSecAttrAccount as String: scope.account,
                kSecAttrSynchronizable as String: false]
    }
    func load(scope: OnlineBattleCredentialScope) throws -> String? {
        var query = try query(scope)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        let (status, data) = operations.read(query as CFDictionary)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data, let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            throw OnlineBattleFailure.credentialsUnavailable
        }
        return value
    }
    func save(_ accessKey: String, scope: OnlineBattleCredentialScope) throws {
        guard !accessKey.isEmpty else { throw OnlineBattleFailure.credentialsUnavailable }
        let query = try query(scope), data = Data(accessKey.utf8)
        let update = operations.update(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw OnlineBattleFailure.credentialsUnavailable }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard operations.add(item as CFDictionary) == errSecSuccess else { throw OnlineBattleFailure.credentialsUnavailable }
    }
    func remove(scope: OnlineBattleCredentialScope) throws {
        let status = operations.delete(try query(scope) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw OnlineBattleFailure.credentialsUnavailable }
    }
}
