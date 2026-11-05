import Foundation

/// Setup prerequisites are shared by button availability and action dispatch.
struct OnlineBattleSetupInput: Equatable {
    /// Why the next field is not ready. A build without an embedded server needs an address; there is no
    /// "apply first" state: join, recover and reconnect apply a typed address themselves.
    enum Requirement: Equatable { case busy, serverMissing, nicknameMissing, nicknameInvalid, inviteMissing, ready }
    /// Why a paste changed nothing. Every failure leaves all drafts as they were.
    enum PasteFailure: Equatable { case empty, tooLong, noInviteCode, invalidServer, serverMismatch, serverMissing, ambiguous }
    /// Matches parseDisplayEmail in server/src/http.ts: 1-254 characters after trimming and NFKC.
    static let nicknameMaxLength = 254
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
    static func nicknameIsValid(_ value: String) -> Bool {
        let scalars = value.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCompatibilityMapping.unicodeScalars
        guard !scalars.isEmpty, scalars.count <= nicknameMaxLength else { return false }
        return !scalars.contains { scalar in
            let properties = scalar.properties
            return properties.isWhitespace || properties.isDefaultIgnorableCodePoint || scalar.value == 0x2800
                || properties.generalCategory == .control || properties.generalCategory == .format
        }
    }

    /// All-or-nothing import. An embedded build takes a one-line code (a two-line invitation is accepted only
    /// when its address is the embedded one); a manual build takes address and code, or just the code once an
    /// address is already typed. Anything unclear leaves every draft intact and says why.
    mutating func pasteInvitation(_ text: String?, embeddedServer: String?) -> PasteFailure? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .empty }
        guard text.utf8.count <= 4096 else { return .tooLong }
        var address: String?, code: String?
        if let whole = Self.inviteToken(text) {
            code = whole // The code itself, possibly wrapped or spaced over several lines.
        } else {
            let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
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
                    guard address == nil else { return .ambiguous }; address = origin.url.absoluteString
                } else if kind != "server", let token = Self.inviteToken(value) {
                    guard code == nil else { return .ambiguous }; code = token
                } else if kind == "server" || value.lowercased().hasPrefix("http") {
                    return .invalidServer
                } // Other lines (greetings, labels) are ignored; only a missing code fails below.
            }
        }
        guard let code else { return .noInviteCode }
        if let embeddedServer {
            let fixed = (try? OnlineBattleOrigin(embeddedServer))?.url.absoluteString ?? embeddedServer
            if let address, address != fixed { return .serverMismatch }
        } else if address == nil, serverToApply == nil {
            return .serverMissing
        }
        if embeddedServer == nil, let address { server = address }
        invite = code
        return nil
    }
    mutating func clearCodes() { invite = ""; recovery = ""; reconnect = "" }
    var serverToApply: String? { (try? OnlineBattleOrigin(server.trimmingCharacters(in: .whitespacesAndNewlines)))?.url.absoluteString }
    func hasAppliedServer(_ applied: String) -> Bool {
        guard let draft = serverToApply, let current = try? OnlineBattleOrigin(applied) else { return false }
        return draft == current.url.absoluteString
    }
    func requirement(isBusy: Bool, serverIsEmbedded: Bool) -> Requirement {
        if isBusy { return .busy }
        if !serverIsEmbedded, serverToApply == nil { return .serverMissing }
        if nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .nicknameMissing }
        if !Self.nicknameIsValid(nickname) { return .nicknameInvalid }
        if invite.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .inviteMissing }
        return .ready
    }
    func joinAction(appliedServer: String, isBusy: Bool, serverIsEmbedded: Bool) -> OnlineBattleUIAction? {
        guard requirement(isBusy: isBusy, serverIsEmbedded: serverIsEmbedded) == .ready else { return nil }
        return withServer(.join(inviteCode: invite.trimmingCharacters(in: .whitespacesAndNewlines),
                                email: nickname.trimmingCharacters(in: .whitespacesAndNewlines)),
                          appliedServer: appliedServer, serverIsEmbedded: serverIsEmbedded)
    }
    func recoverAction(appliedServer: String, isBusy: Bool, serverIsEmbedded: Bool) -> OnlineBattleUIAction? {
        let code = recovery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isBusy, !code.isEmpty else { return nil }
        return withServer(.recover(code: code), appliedServer: appliedServer, serverIsEmbedded: serverIsEmbedded)
    }
    func reconnectAction(appliedServer: String, isBusy: Bool, serverIsEmbedded: Bool) -> OnlineBattleUIAction? {
        let code = reconnect.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isBusy, !code.isEmpty else { return nil }
        return withServer(.reconnect(code: code), appliedServer: appliedServer, serverIsEmbedded: serverIsEmbedded)
    }
    /// An embedded build already has its address. Otherwise a typed address that differs from the applied one
    /// is applied by the action itself, so a stale address can never block or mis-route a join or recovery.
    private func withServer(_ action: OnlineBattleUIAction, appliedServer: String, serverIsEmbedded: Bool) -> OnlineBattleUIAction? {
        if serverIsEmbedded { return action }
        guard let draft = serverToApply else { return nil }
        return hasAppliedServer(appliedServer) ? action : .applyingServer(draft, action)
    }
}
