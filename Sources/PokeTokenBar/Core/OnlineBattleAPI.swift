import Foundation

/// Complete bodies are consumed by the driver before any response classification.
struct OnlineBattleHTTPResponse: Sendable { let status: Int; let body: Data; var retryAfter: Int? = nil }
protocol OnlineBattleHTTPTransport: Sendable { func send(_ request: URLRequest) async throws -> OnlineBattleHTTPResponse }
final class OnlineBattleURLSessionTransport: NSObject, OnlineBattleHTTPTransport, URLSessionTaskDelegate, @unchecked Sendable {
    func send(_ request: URLRequest) async throws -> OnlineBattleHTTPResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw OnlineBattleFailure.invalidResponse }
        return .init(status: response.statusCode, body: data, retryAfter: response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
/// Unknown server text is never retained in errors, diagnostics or UI.
enum OnlineBattleServerCode: String, Codable, Sendable {
    case badRequest = "bad_request", invalidSnapshot = "invalid_snapshot", invalidChoice = "invalid_choice"
    case invalidState = "invalid_state", staleRevision = "stale_revision", engineMismatch = "engine_mismatch", versionMismatch = "version_mismatch"
    case instanceBusy = "instance_busy", fainted, notReady = "not_ready", staleRound = "stale_round", choiceConflict = "choice_conflict", reportConflict = "report_conflict", idempotencyConflict = "idempotency_conflict"
    case cannotTargetSelf = "cannot_target_self", unauthorized, forbidden, operatorDenied = "operator_denied", accountLeft = "account_left"
    case notFound = "not_found", invalidInvite = "invalid_invite", invalidCode = "invalid_code", methodNotAllowed = "method_not_allowed"
    case displayEmailTaken = "display_email_taken", hostMustTransfer = "host_must_transfer", inviteExpired = "invite_expired", inviteRevoked = "invite_revoked", inviteUsedUp = "invite_used_up", codeExpired = "code_expired", codeUsed = "code_used"
    case payloadTooLarge = "payload_too_large", unsupportedMediaType = "unsupported_media_type", upgradeRequired = "upgrade_required", tooManyAttempts = "too_many_attempts", `internal`, operatorDisabled = "operator_disabled"
}
struct OnlineBattleServerError: Error, Equatable, Sendable { let code: OnlineBattleServerCode; let retryAfter: Int? }

actor OnlineBattleAPI {
    private var origin: OnlineBattleOrigin
    private var accessKey: String?
    private var generation: UInt64 = 0
    private let transport: any OnlineBattleHTTPTransport
    init(origin: OnlineBattleOrigin, transport: any OnlineBattleHTTPTransport = OnlineBattleURLSessionTransport()) {
        self.origin = origin; self.transport = transport
    }
    func setAccessKey(_ value: String?) { generation &+= 1; accessKey = value }
    func setOrigin(_ value: OnlineBattleOrigin) { generation &+= 1; origin = value; accessKey = nil }
    func currentGeneration() -> UInt64 { generation }
    private struct Empty: Codable { }
    private struct ErrorEnvelope: Decodable { struct Detail: Decodable { let code: OnlineBattleServerCode }; let error: Detail }
    private struct OK: Decodable { let ok: Bool }
    private struct TrainerID: Encodable { let trainerId: String }
    private struct Revision: Encodable { let revision: Int }
    private struct RevisedSnapshot: Encodable { let revision: Int; let snapshot: OnlineBattleSnapshot }
    private struct GroupEnvelope: Decodable { let group: OnlineBattleGroup }
    private struct InviteEnvelope: Decodable { let invite: OnlineBattleInvite }
    private struct Removal: Decodable { let ok: Bool; let revokedInvites: Int }

    private func request<Response: Decodable & Sendable, Body: Encodable & Sendable>(
        _ path: String, method: String = "GET", body: Body? = nil, authenticated: Bool = true,
        query: [URLQueryItem] = []
    ) async throws -> Response {
        let epoch = generation
        var parts = URLComponents(url: origin.url, resolvingAgainstBaseURL: false)!
        parts.path = "/v1/" + path; parts.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: parts.url!)
        request.httpMethod = method; request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if authenticated {
            guard let accessKey else { throw OnlineBattleFailure.unauthorized }
            request.setValue("Bearer " + accessKey, forHTTPHeaderField: "Authorization")
        }
        if let body { request.httpBody = try JSONEncoder().encode(body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let response: OnlineBattleHTTPResponse
        do { response = try await transport.send(request) }
        catch {
            guard epoch == generation else { throw OnlineBattleFailure.staleGeneration }
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw OnlineBattleFailure.transport
        }
        guard epoch == generation else { throw OnlineBattleFailure.staleGeneration }
        try Task.checkCancellation()
        guard response.status == 200 else {
            if response.status == 401 { throw OnlineBattleFailure.unauthorized }
            guard let error = try? JSONDecoder().decode(ErrorEnvelope.self, from: response.body) else { throw OnlineBattleFailure.invalidResponse }
            throw OnlineBattleServerError(code: error.error.code, retryAfter: response.status == 429 ? response.retryAfter : nil)
        }
        do { return try JSONDecoder().decode(Response.self, from: response.body) }
        catch { throw OnlineBattleFailure.invalidResponse }
    }
    private func get<Response: Decodable & Sendable>(_ path: String, query: [URLQueryItem] = []) async throws -> Response {
        try await request(path, body: Optional<Empty>.none, query: query)
    }
    private func post<Response: Decodable & Sendable, Body: Encodable & Sendable>(_ path: String, _ body: Body, authenticated: Bool = true) async throws -> Response {
        try await request(path, method: "POST", body: body, authenticated: authenticated)
    }
    private func battlePath(_ id: String, action: String? = nil) throws -> String {
        guard id.hasPrefix("bt_"), id.count <= 128, id.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45 }) else { throw OnlineBattleFailure.invalidRequest }
        return "battles/" + id + (action.map { "/" + $0 } ?? "")
    }
    func join(inviteCode: String, displayEmail: String) async throws -> OnlineBattleGrant {
        struct Body: Encodable { let inviteCode: String; let displayEmail: String }
        return try await post("join", Body(inviteCode: inviteCode, displayEmail: displayEmail), authenticated: false)
    }
    func recover(recoveryCode: String) async throws -> OnlineBattleGrant {
        struct Body: Encodable { let recoveryCode: String }
        return try await post("recover", Body(recoveryCode: recoveryCode), authenticated: false)
    }
    func reconnect(reconnectCode: String, displayEmail: String? = nil) async throws -> OnlineBattleGrant {
        struct Body: Encodable { let reconnectCode: String; let displayEmail: String? }
        return try await post("reconnect", Body(reconnectCode: reconnectCode, displayEmail: displayEmail), authenticated: false)
    }
    func me() async throws -> OnlineBattleAccount { try await get("me") }
    func group() async throws -> OnlineBattleGroupMembers { try await get("group") }
    func standings() async throws -> OnlineBattleStandings {
        let value: OnlineBattleStandings = try await get("standings")
        guard !value.groupId.isEmpty, Set(value.rows.map(\.trainerId)).count == value.rows.count,
              value.rows.allSatisfy({ row in
                  !row.trainerId.isEmpty && [row.wins, row.losses, row.draws, row.streak, row.bestStreak].allSatisfy { $0 >= 0 } &&
                  row.streak <= row.bestStreak && row.bestStreak <= row.wins &&
                  row.winRate.map { $0.isFinite && (0...1).contains($0) } != false
              }), value.championTrainerId.map({ id in value.rows.contains { $0.trainerId == id && $0.streak > 0 } }) != false
        else { throw OnlineBattleFailure.invalidResponse }
        return value
    }
    func audit() async throws -> OnlineBattleAudit { try await get("audit") }
    func invites() async throws -> OnlineBattleInvites { try await get("invites") }
    func createInvite(ttlSeconds: Int? = nil, maxUses: Int? = nil) async throws -> OnlineBattleIssuedInvite {
        struct Body: Encodable { let ttlSeconds: Int?; let maxUses: Int? }
        return try await post("invites", Body(ttlSeconds: ttlSeconds, maxUses: maxUses))
    }
    func revokeInvite(inviteId: String) async throws -> OnlineBattleInvite {
        struct Body: Encodable { let inviteId: String }
        let result: InviteEnvelope = try await post("invites/revoke", Body(inviteId: inviteId)); return result.invite
    }
    func issueReconnectCode(trainerId: String) async throws -> OnlineBattleIssuedReconnect { try await post("reconnect-codes", TrainerID(trainerId: trainerId)) }
    func leave() async throws { let _: OK = try await post("leave", Empty()) }
    func removeMember(trainerId: String) async throws -> Int {
        let result: Removal = try await post("members/remove", TrainerID(trainerId: trainerId)); return result.revokedInvites
    }
    func transferHost(trainerId: String) async throws -> OnlineBattleGroup {
        let result: GroupEnvelope = try await post("host/transfer", TrainerID(trainerId: trainerId)); return result.group
    }
    func listBattles() async throws -> [OnlineBattleView] {
        let epoch = generation
        var all: [OnlineBattleView] = [], cursor: String?, seen = Set<String>()
        repeat {
            let page: OnlineBattlePage = try await get("battles", query: cursor.map { [URLQueryItem(name: "before", value: $0)] } ?? [])
            guard epoch == generation else { throw OnlineBattleFailure.staleGeneration }
            all += page.battles
            cursor = page.before
            if let cursor {
                guard !cursor.isEmpty, cursor.utf8.allSatisfy({ (48...57).contains($0) }), seen.insert(cursor).inserted else { throw OnlineBattleFailure.invalidResponse }
            }
        } while cursor != nil
        return all
    }
    func battle(id: String) async throws -> OnlineBattleView { try await get(battlePath(id)) }
    func createBattle(requestId: String, targetTrainerId: String, mode: OnlineBattleMode, snapshot: OnlineBattleSnapshot) async throws -> OnlineBattleView {
        struct Body: Encodable { let requestId: String; let targetTrainerId: String; let mode: OnlineBattleMode; let snapshot: OnlineBattleSnapshot }
        return try await post("battles", Body(requestId: requestId, targetTrainerId: targetTrainerId, mode: mode, snapshot: snapshot))
    }
    func update(id: String, revision: Int, snapshot: OnlineBattleSnapshot) async throws -> OnlineBattleView { try await post(battlePath(id, action: "update"), RevisedSnapshot(revision: revision, snapshot: snapshot)) }
    func accept(id: String, revision: Int, snapshot: OnlineBattleSnapshot) async throws -> OnlineBattleView { try await post(battlePath(id, action: "accept"), RevisedSnapshot(revision: revision, snapshot: snapshot)) }
    func confirm(id: String, revision: Int) async throws -> OnlineBattleView { try await post(battlePath(id, action: "confirm"), Revision(revision: revision)) }
    func decline(id: String, revision: Int) async throws -> OnlineBattleView { try await post(battlePath(id, action: "decline"), Revision(revision: revision)) }
    func cancel(id: String, revision: Int) async throws -> OnlineBattleView { try await post(battlePath(id, action: "cancel"), Revision(revision: revision)) }
    func ready(id: String, revision: Int, connectionId: String, engineHash: String, rulesVersion: String, policyVersion: String) async throws -> OnlineBattleView {
        struct Body: Encodable { let revision: Int; let connectionId: String; let engineHash: String; let rulesVersion: String; let policyVersion: String }
        return try await post(battlePath(id, action: "ready"), Body(revision: revision, connectionId: connectionId, engineHash: engineHash, rulesVersion: rulesVersion, policyVersion: policyVersion))
    }
    func start(id: String, revision: Int, connectionId: String, readyToken: String, engineHash: String) async throws -> OnlineBattleView {
        struct Body: Encodable { let revision: Int; let connectionId: String; let readyToken: String; let engineHash: String }
        return try await post(battlePath(id, action: "start"), Body(revision: revision, connectionId: connectionId, readyToken: readyToken, engineHash: engineHash))
    }
    func choose(id: String, roundSeq: Int, slot: Int) async throws -> OnlineBattleView {
        guard (1...4).contains(slot) else { throw OnlineBattleFailure.invalidRequest }
        struct Body: Encodable { let roundSeq: Int; let choice: String }
        return try await post(battlePath(id, action: "choices"), Body(roundSeq: roundSeq, choice: "move \(slot)"))
    }
    func advance(id: String, processedRoundSeq: Int) async throws -> OnlineBattleView {
        struct Body: Encodable { let processedRoundSeq: Int }
        return try await post(battlePath(id, action: "advance"), Body(processedRoundSeq: processedRoundSeq))
    }
    func report(id: String, report: OnlineBattleReport) async throws -> OnlineBattleView { try await post(battlePath(id, action: "report"), report) }
    func rematch(id: String, requestId: String, snapshot: OnlineBattleSnapshot) async throws -> OnlineBattleView {
        struct Body: Encodable { let requestId: String; let snapshot: OnlineBattleSnapshot }
        return try await post(battlePath(id, action: "rematch"), Body(requestId: requestId, snapshot: snapshot))
    }
}
