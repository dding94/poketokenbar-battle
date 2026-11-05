import AppKit
import SwiftUI

/// Setup prerequisites are shared by button availability and action dispatch.
struct OnlineBattleSetupInput: Equatable {
    enum Requirement: Equatable { case busy, serverMissing, serverChanged, inviteMissing, nicknameMissing, ready }
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
    mutating func pasteInvitation(_ text: String?) -> Bool {
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
    func joinAction(appliedServer: String, isBusy: Bool) -> OnlineBattleUIAction? {
        guard requirement(appliedServer: appliedServer, isBusy: isBusy) == .ready else { return nil }
        return .join(inviteCode: invite.trimmingCharacters(in: .whitespacesAndNewlines),
                     email: nickname.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// The online session survives closing this 360pt popover. Views only dispatch typed user intent.
@MainActor
struct OnlineBattleScreen: View {
    let model: OnlineBattlePresentation
    let l: L
    var artwork = true
    var readInvitationClipboard: () -> String? = { NSPasteboard.general.string(forType: .string) }
    var speciesNameProvider: any PokemonNameProviding = PokemonNameClient.shared
    var speciesNameStore: PokemonNameDisplayStore = .shared
    let onClose: () -> Void

    var showsGroupBack: Bool { !model.showsHistory && !model.showsStandings && model.rematchSourceID == nil && [.room, .arena, .verifying].contains(model.phase) }
    func returnToGroup() { model.send(.backToLobby) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button(action: onClose) { Label(l.home, systemImage: "chevron.left") }
                    .buttonStyle(.borderless).keyboardShortcut(.cancelAction)
                Spacer(minLength: 4)
                Text(l.onlineTitle).font(.headline)
                Spacer(minLength: 4)
                if model.isBusy { ProgressView().controlSize(.small) }
            }.frame(height: 22)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if showsGroupBack {
                        Button(action: returnToGroup) { Label(l.onlineDone, systemImage: "person.2") }
                            .buttonStyle(.borderless).font(.caption)
                            .accessibilityIdentifier("online.backToGroup")
                    }
                    if !model.connectionStatus.isEmpty {
                        Label(model.connectionStatus, systemImage: "network")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let notice = model.notice {
                        Text(notice).font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true).practiceCard()
                    }
                    if model.canRetryCredentialSave {
                        Button(l.onlineRetrySave) { model.send(.retryCredentialSave) }
                            .disabled(model.isBusy)
                    }
                    if let code = model.recoveryCode {
                        recoveryCode(code)
                    } else {
                        stage
                    }
                }
                .frame(width: PopoverMetrics.scrollContentWidth, alignment: .leading)
                .reservesScrollerLane()
            }
            .frame(width: PopoverMetrics.contentWidth, height: 520)
            Label(l.onlineCaption, systemImage: "lock.shield")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity).frame(height: 16)
        }
        .frame(width: PopoverMetrics.contentWidth)
        .padding(PopoverMetrics.padding)
    }

    @ViewBuilder private var stage: some View {
        if model.rematchSourceID != nil {
            OnlineBattleRematchPreparation(model: model, l: l, artwork: artwork)
        } else if model.showsStandings {
            OnlineBattleStandingsScreen(model: model, l: l)
        } else if model.showsHistory {
            OnlineBattleHistory(model: model, l: l, artwork: artwork,
                                speciesNameProvider: speciesNameProvider, speciesNameStore: speciesNameStore)
        } else {
        switch model.phase {
        case .setup: OnlineBattleSetupForm(model: model, l: l, readInvitationClipboard: readInvitationClipboard)
        case .lobby: OnlineBattleLobby(model: model, l: l, artwork: artwork)
        case .room: OnlineBattleRoom(model: model, l: l, artwork: artwork, speciesNameProvider: speciesNameProvider, speciesNameStore: speciesNameStore)
        case .arena: OnlineBattleArena(model: model, l: l, artwork: artwork, speciesNameProvider: speciesNameProvider, speciesNameStore: speciesNameStore)
        case .verifying:
            VStack(alignment: .leading, spacing: 10) {
                Label(l.onlineVerifying, systemImage: "checkmark.shield").font(.headline)
                Text(l.onlineVerifyingHint).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Button(l.onlineRefresh) { model.send(.refresh) }.disabled(model.isBusy)
            }.practiceCard()
        case .result:
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: model.result?.isVoid == true ? "minus.circle" : "flag.checkered")
                    .font(.largeTitle).foregroundStyle(.secondary)
                Text(model.result?.title ?? l.onlineResult).font(.title3.bold())
                if let result = model.result {
                    Text(result.detail).font(.callout).fixedSize(horizontal: false, vertical: true)
                    if result.xpAwarded > 0 { Text(l.onlineXP(result.xpAwarded)).font(.headline).foregroundStyle(.green) }
                    Label(result.hpApplied ? l.onlineHPApplied : l.onlineNoEffects,
                          systemImage: result.hpApplied ? "heart.fill" : "shield")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let room = model.room, room.state == .completed,
                   room.side(for: model.account?.trainer.trainerId ?? "") != nil {
                    Button(l.onlineRematch) { model.send(.prepareRematch(room.battleId)) }
                        .disabled(!model.canRematch(room))
                        .accessibilityIdentifier("online.result.rematch")
                    if !model.canRematch(room) {
                        Text(l.onlineRematchUnavailable).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Button(l.onlineDone) { model.send(.dismissResult) }
                    .buttonStyle(.borderedProminent).disabled(model.isBusy)
            }
            .frame(maxWidth: .infinity, alignment: .leading).practiceCard()
        }
        }
    }

    private func recoveryCode(_ code: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(l.onlineRecoveryTitle, systemImage: "key").font(.headline)
            Text(l.onlineRecoveryHint).font(.callout).fixedSize(horizontal: false, vertical: true)
            Text(code).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Button(l.onlineRecoverySaved) { model.send(.acknowledgeRecoveryCode) }
                .buttonStyle(.borderedProminent)
        }.practiceCard()
        .privacySensitive()
    }
}

@MainActor
private struct OnlineBattleSetupForm: View {
    @Bindable var model: OnlineBattlePresentation
    let l: L
    let readInvitationClipboard: () -> String?
    private var input: OnlineBattleSetupInput { model.setupInput }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(l.onlineSetup).font(.headline)
            Button(l.onlinePasteInvitation) {
                model.setupPasteFailed = !model.setupInput.pasteInvitation(readInvitationClipboard())
            }
            .disabled(model.isBusy)
            .accessibilityIdentifier("online.pasteInvitation")
            if model.setupPasteFailed {
                Text(l.onlinePasteInvitationFailed).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(l.onlineServerHint).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField(l.onlineServer, text: $model.setupInput.server).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("online.server")
                Button(l.onlineSaveServer) {
                    if let address = input.serverToApply { model.send(.configureServer(address)) }
                }
                .disabled(model.isBusy || input.serverToApply == nil)
                if input.hasAppliedServer(model.serverAddress) {
                    Text(l.onlineServerSaved).font(.caption2).foregroundStyle(.secondary)
                }
            }.practiceCard()
            VStack(alignment: .leading, spacing: 7) {
                TextField(l.onlineInvite, text: $model.setupInput.invite).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("online.invite")
                TextField(l.onlineNickname, text: $model.setupInput.nickname).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("online.nickname")
                Text(l.onlineNicknameHint).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(l.onlineJoin) {
                    if let action = input.joinAction(appliedServer: model.serverAddress, isBusy: model.isBusy) {
                        model.send(action)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(input.requirement(appliedServer: model.serverAddress, isBusy: model.isBusy) != .ready)
                Text(l.onlineSetupRequirement(input.requirement(appliedServer: model.serverAddress, isBusy: model.isBusy)))
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.practiceCard()
            DisclosureGroup(l.onlineRecovery, isExpanded: $model.setupRecoveryExpanded) {
                VStack(alignment: .leading, spacing: 7) {
                    SecureField(l.onlineRecoveryCode, text: $model.setupInput.recovery).textFieldStyle(.roundedBorder)
                    Button(l.onlineRecover) { model.send(.recover(code: input.recovery)) }
                        .disabled(model.isBusy || input.recovery.isEmpty || !input.hasAppliedServer(model.serverAddress))
                    Divider()
                    SecureField(l.onlineReconnectCode, text: $model.setupInput.reconnect).textFieldStyle(.roundedBorder)
                    Button(l.onlineReconnect) { model.send(.reconnect(code: input.reconnect)) }
                        .disabled(model.isBusy || input.reconnect.isEmpty || !input.hasAppliedServer(model.serverAddress))
                }.padding(.top, 6)
            }.practiceCard()
        }
    }
}
