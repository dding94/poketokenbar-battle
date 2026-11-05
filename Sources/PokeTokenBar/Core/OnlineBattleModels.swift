import CryptoKit
import Foundation

/// Validated origin only: credentials, paths, queries and fragments never enter configuration.
struct OnlineBattleOrigin: Equatable, Sendable {
    let url: URL
    init(_ value: String) throws {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              var components = URLComponents(string: value), components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty, Self.isOriginOnly(components) else { throw OnlineBattleFailure.invalidOrigin }
        components.scheme = "https"; components.host = host.lowercased(); components.path = ""
        if components.port == 443 { components.port = nil }
        guard let url = components.url else { throw OnlineBattleFailure.invalidOrigin }
        self.url = url
    }
    /// Explicit injection for local workerd fixtures; user-entered settings always use the HTTPS initializer.
    init(testLoopbackURL: URL) throws {
        guard var components = URLComponents(url: testLoopbackURL, resolvingAgainstBaseURL: false),
              components.scheme == "http", ["localhost", "127.0.0.1", "[::1]", "::1"].contains(components.host ?? ""),
              Self.isOriginOnly(components) else {
            throw OnlineBattleFailure.invalidOrigin
        }
        components.path = ""
        guard let url = components.url else { throw OnlineBattleFailure.invalidOrigin }
        self.url = url
    }
    private static func isOriginOnly(_ components: URLComponents) -> Bool {
        components.user == nil && components.password == nil && components.query == nil && components.fragment == nil
            && (components.path.isEmpty || components.path == "/")
            && (components.port.map { (1...65535).contains($0) } ?? true)
    }
    var hash: String { SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined() }
}
enum OnlineBattleFailure: String, Error, Equatable, Sendable { case invalidSettings, credentialsDisabled, invalidOrigin, invalidRequest, transport, invalidResponse, staleGeneration, unauthorized, protocolError, credentialsUnavailable, peerCancelled, peerExpired, entryChanged, connectionUnavailable, roundPassed, choiceAlreadyIn }

enum OnlineBattleMode: String, Codable, Sendable { case manual, auto }
enum OnlineBattleState: String, Codable, Sendable {
    case pending = "PENDING", accepted = "ACCEPTED", ready = "READY", running = "RUNNING", reported = "REPORTED"
    case completed = "COMPLETED", declined = "DECLINED", cancelled = "CANCELLED", expired = "EXPIRED", void = "VOID"
    var isActive: Bool { [.pending, .accepted, .ready, .running, .reported].contains(self) }
}
enum OnlineBattleSide: String, Codable, Sendable { case p1, p2 }
enum OnlineBattleWinner: String, Codable, Sendable { case p1, p2, draw }
struct OnlineBattleSnapshot: Codable, Equatable, Sendable {
    let instanceId: String
    let set: BattleSet
    let publicInfo: BattlePublicInfo
    let hp: Int
    enum CodingKeys: String, CodingKey { case instanceId, set, publicInfo = "public", hp }
    init(instanceId: String, set: BattleSet, publicInfo: BattlePublicInfo, hp: Int) {
        self.instanceId = instanceId; self.set = set; self.publicInfo = publicInfo; self.hp = hp
    }
    init(snapshot: BattleSnapshot, hp: Int) {
        self.init(instanceId: snapshot.instanceID, set: snapshot.set, publicInfo: snapshot.publicInfo, hp: hp)
    }
}
extension OnlineBattleSnapshot {
    /// The shape the practice cards read (sprite shiny/form, move and ability slugs). Display only: the engine hash
    /// is left empty because this value is never hashed, verified or sent anywhere.
    var displaySnapshot: BattleSnapshot {
        BattleSnapshot(schemaVersion: 1, instanceID: instanceId, engineHash: "", rulesVersion: BattleSnapshot.rules,
                       policyVersion: BattleSnapshot.policy, set: set, publicInfo: publicInfo)
    }
}
struct OnlineBattlePlayer: Codable, Equatable, Sendable {
    let trainerId: String
    let snapshot: OnlineBattleSnapshot?
    let publicInfo: BattlePublicInfo?
    let hpPercent: Double?
    enum CodingKeys: String, CodingKey { case trainerId, snapshot, publicInfo = "public", hpPercent }
}
struct OnlineBattleEnginePlayer: Codable, Equatable, Sendable {
    let name: String
    let set: BattleSet
    let hp: Int
    let policy: String
}
struct OnlineBattleEngineConfig: Codable, Equatable, Sendable {
    let seed: [UInt32]
    let policySeed: UInt32
    let p1: OnlineBattleEnginePlayer
    let p2: OnlineBattleEnginePlayer
}
struct OnlineBattleConfig: Codable, Equatable, Sendable {
    let readyToken: String
    let engineHash: String
    let rulesVersion: String
    let policyVersion: String
    let relayVersion: String
    let seed: [UInt32]
    let policySeed: UInt32
    let p1: OnlineBattleEnginePlayer
    let p2: OnlineBattleEnginePlayer
    var engineConfig: OnlineBattleEngineConfig { .init(seed: seed, policySeed: policySeed, p1: p1, p2: p2) }
}
/// Server-authored policy markers never become simulator source text.
enum OnlineBattleRelayToken: Equatable, Sendable, Codable {
    case move(Int), timeout, policy
    private enum CodingKeys: String, CodingKey { case kind, slot }
    private enum Kind: String, Codable { case move, timeout, policy }
    private struct AnyKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try box.decode(Kind.self, forKey: .kind)
        let keys = try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue)
        guard Set(keys) == Set(kind == .move ? ["kind", "slot"] : ["kind"]) else { throw OnlineBattleFailure.invalidResponse }
        switch kind {
        case .move:
            let slot = try box.decode(Int.self, forKey: .slot)
            guard (1...4).contains(slot) else { throw OnlineBattleFailure.invalidResponse }
            self = .move(slot)
        case .timeout: self = .timeout
        case .policy: self = .policy
        }
    }
    func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .move(let slot):
            guard (1...4).contains(slot) else { throw OnlineBattleFailure.invalidResponse }
            try box.encode(Kind.move, forKey: .kind); try box.encode(slot, forKey: .slot)
        case .timeout: try box.encode(Kind.timeout, forKey: .kind)
        case .policy: try box.encode(Kind.policy, forKey: .kind)
        }
    }
}
struct OnlineBattlePair: Codable, Equatable, Sendable {
    let roundSeq: Int
    let p1: OnlineBattleRelayToken
    let p2: OnlineBattleRelayToken
    let releasedAt: Double
}
struct OnlineBattleFinalHP: Codable, Equatable, Sendable { let p1: Int; let p2: Int }
struct OnlineBattleReport: Codable, Equatable, Sendable {
    let readyToken: String
    let engineHash: String
    let terminalSeq: Int
    let winner: OnlineBattleWinner
    let logHash: String
    let journalHash: String
    let finalHp: OnlineBattleFinalHP
}
struct OnlineBattleView: Codable, Equatable, Sendable {
    let battleId: String
    let state: OnlineBattleState
    let revision: Int
    let mode: OnlineBattleMode
    let p1: OnlineBattlePlayer
    let p2: OnlineBattlePlayer
    let createdAt: Double
    let expiresAt: Double
    let startedAt: Double?
    let reportedAt: Double?
    let confirmed: Bool
    let config: OnlineBattleConfig?
    let roundSeq: Int
    let deadline: Double?
    let ownChoice: String?
    let journal: [OnlineBattlePair]
    let result: OnlineBattleReport?
    let reason: String?
    let rematchOf: String?
    /// Whether the other seat's choice for this round is in; never which one. Optional on the wire: a server
    /// that predates the field sends nothing, which reads the same as "not known".
    var opponentSubmitted: Bool? = nil
    func side(for trainerId: String) -> OnlineBattleSide? { p1.trainerId == trainerId ? .p1 : p2.trainerId == trainerId ? .p2 : nil }
}
struct OnlineBattlePage: Codable, Sendable { let battles: [OnlineBattleView]; let before: String? }
struct OnlineBattleTrainer: Codable, Equatable, Sendable {
    enum Role: String, Codable, Sendable { case host, member }
    enum Status: String, Codable, Sendable { case active, left }
    let trainerId: String
    let displayEmail: String?
    let role: Role
    let status: Status
}
struct OnlineBattleMember: Codable, Equatable, Sendable {
    let trainerId: String
    let displayEmail: String?
    let role: OnlineBattleTrainer.Role
    let status: OnlineBattleTrainer.Status
    let joinedAt: Double
    let online: Bool
}
struct OnlineBattleGroup: Codable, Equatable, Sendable { let groupId: String; let name: String; let hostTrainerId: String }
struct OnlineBattleAccount: Codable, Equatable, Sendable { let trainer: OnlineBattleTrainer; let group: OnlineBattleGroup }
struct OnlineBattleGroupMembers: Codable, Equatable, Sendable { let group: OnlineBattleGroup; let members: [OnlineBattleMember] }
struct OnlineBattleGrant: Decodable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let trainer: OnlineBattleTrainer
    let group: OnlineBattleGroup
    let accessKey: String
    let recoveryCode: String
    var account: OnlineBattleAccount { .init(trainer: trainer, group: group) }
    var description: String { "OnlineBattleGrant(redacted)" }
    var debugDescription: String { description }
}
struct OnlineBattleInvite: Codable, Sendable {
    let inviteId: String; let createdAt: Double; let expiresAt: Double; let maxUses: Int; let uses: Int; let revoked: Bool; let revokedAt: Double?
}
struct OnlineBattleInvites: Codable, Sendable { let invites: [OnlineBattleInvite] }
struct OnlineBattleIssuedInvite: Decodable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let invite: OnlineBattleInvite; let inviteCode: String
    var description: String { "OnlineBattleIssuedInvite(redacted)" }; var debugDescription: String { description }
}
struct OnlineBattleIssuedReconnect: Decodable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let trainerId: String; let reconnectCode: String; let expiresAt: Double
    var description: String { "OnlineBattleIssuedReconnect(redacted)" }; var debugDescription: String { description }
}
struct OnlineBattleAudit: Codable, Sendable {
    struct Entry: Codable, Sendable {
        enum Kind: String, Codable, Sendable { case inviteCreated = "invite_created", inviteRevoked = "invite_revoked", reconnectCodeIssued = "reconnect_code_issued", reconnectCodeUsed = "reconnect_code_used", operatorHostReconnect = "operator_host_reconnect", memberLeft = "member_left", memberRemoved = "member_removed", hostTransferred = "host_transferred" }
        let id: Int; let at: Double; let kind: Kind; let actorTrainerId: String?; let targetTrainerId: String?; let inviteId: String?
    }
    let entries: [Entry]
}

/// Server-authoritative group records; no battle snapshots or local settlement state.
struct OnlineBattleStanding: Codable, Equatable, Sendable, Identifiable {
    let trainerId: String
    let displayName: String
    let wins: Int
    let losses: Int
    let draws: Int
    let streak: Int
    let bestStreak: Int
    let winRate: Double?
    var id: String { trainerId }
}
struct OnlineBattleStandings: Codable, Equatable, Sendable {
    let groupId: String
    let championTrainerId: String?
    let rows: [OnlineBattleStanding]
}
