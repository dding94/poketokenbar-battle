import Foundation

/// Setup prerequisites are shared by button availability and action dispatch.
struct OnlineBattleSetupInput: Equatable {
    enum Requirement: Equatable { case busy, serverMissing, serverChanged, inviteMissing, nicknameMissing, nicknameInvalid, ready }
    enum PasteFailure: Equatable { case empty, tooLong, noInviteCode, invalidServer, serverMismatch, serverMissing, ambiguous }
    var server = ""
    var invite = ""
    var nickname = ""
    var recovery = ""
    var reconnect = ""
    /// Matches server/src/secrets.ts: twelve Crockford characters, including its aliases.
    static func inviteToken(_ value: String) -> String? {
        let compact = value.filter { !$0.isWhitespace && $0 != "-" }.uppercased()
            .replacingOccurrences(of: "O", with: "0").replacingOccurrences(of: "I", with: "1").replacingOccurrences(of: "L", with: "1")
        guard compact.count == 12, compact.allSatisfy({ "0123456789ABCDEFGHJKMNPQRSTVWXYZ".contains($0) }) else { return nil }
        return compact
    }
    /// All-or-nothing import. Unknown or repeated fields are ambiguous and leave every draft intact.
    mutating func pasteInvitation(_ text: String?, embeddedServer: String?) -> PasteFailure? {
        legacyPaste(text) ? nil : .noInviteCode
    }
    private mutating func legacyPaste(_ text: String?) -> Bool {
        guard let text, text.utf8.count <= 4096 else { return false }
        var address: String?, code: String?
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.count == 2 else { return false }
        for line in lines {
            var value = line
            var kind: String?
            if let range = line.range(of: "^(.+?)[:：]\\s*", options: .regularExpression) {
                let label = String(line[range]).dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
                let normalized = label.lowercased().filter { !$0.isWhitespace && $0 != ":" && $0 != "：" }
                if ["서버주소", "서버", "server", "serveraddress"].contains(normalized) { kind = "server" }
                if ["초대코드", "invite", "invitecode"].contains(normalized) { kind = "invite" }
                if kind != nil { value = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces) }
            }
            if kind != "invite", let origin = try? OnlineBattleOrigin(value) {
                guard address == nil else { return false }; address = origin.url.absoluteString
            } else if kind != "server", let token = Self.inviteToken(value) {
                guard code == nil else { return false }; code = token
            } else { return false }
        }
        guard let address, let code else { return false }
        server = address; invite = code
        return true
    }
    mutating func clearCodes() { invite = ""; recovery = ""; reconnect = "" }
    var serverToApply: String? { (try? OnlineBattleOrigin(server.trimmingCharacters(in: .whitespacesAndNewlines)))?.url.absoluteString }
    func hasAppliedServer(_ applied: String) -> Bool {
        guard let draft = serverToApply, let current = try? OnlineBattleOrigin(applied) else { return false }
        return draft == current.url.absoluteString
    }
    func requirement(appliedServer: String, isBusy: Bool) -> Requirement {
        if isBusy { return .busy }
        if serverToApply == nil { return .serverMissing }
        if !hasAppliedServer(appliedServer) { return .serverChanged }
        if invite.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .inviteMissing }
        if nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .nicknameMissing }
        return .ready
    }
    func requirement(isBusy: Bool, serverIsEmbedded: Bool) -> Requirement { requirement(appliedServer: server, isBusy: isBusy) }
    func recoverAction(appliedServer: String, isBusy: Bool, serverIsEmbedded: Bool) -> OnlineBattleUIAction? { nil }
    func reconnectAction(appliedServer: String, isBusy: Bool, serverIsEmbedded: Bool) -> OnlineBattleUIAction? { nil }
    func joinAction(appliedServer: String, isBusy: Bool, serverIsEmbedded: Bool) -> OnlineBattleUIAction? {
        guard requirement(appliedServer: appliedServer, isBusy: isBusy) == .ready else { return nil }
        return .join(inviteCode: invite.trimmingCharacters(in: .whitespacesAndNewlines),
                     email: nickname.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
