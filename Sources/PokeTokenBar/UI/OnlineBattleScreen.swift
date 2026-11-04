import SwiftUI

/// Setup prerequisites are shared by button availability and action dispatch.
struct OnlineBattleSetupInput {
    enum Requirement: Equatable { case busy, serverMissing, serverChanged, inviteMissing, nicknameMissing, ready }
    var server = ""
    var invite = ""
    var nickname = ""
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
    var speciesNameProvider: any PokemonNameProviding = PokemonNameClient.shared
    var speciesNameStore: PokemonNameDisplayStore = .shared
    let onClose: () -> Void

    var showsGroupBack: Bool { !model.showsHistory && [.room, .arena, .verifying].contains(model.phase) }
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
        if model.showsHistory {
            OnlineBattleHistory(model: model, l: l, artwork: artwork,
                                speciesNameProvider: speciesNameProvider, speciesNameStore: speciesNameStore)
        } else {
        switch model.phase {
        case .setup: OnlineBattleSetupForm(model: model, l: l)
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
    let model: OnlineBattlePresentation
    let l: L
    @State private var input = OnlineBattleSetupInput()
    @State private var recovery = ""
    @State private var reconnect = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(l.onlineSetup).font(.headline)
            VStack(alignment: .leading, spacing: 7) {
                Text(l.onlineServerHint).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField(l.onlineServer, text: $input.server).textFieldStyle(.roundedBorder)
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
                TextField(l.onlineInvite, text: $input.invite).textFieldStyle(.roundedBorder)
                TextField(l.onlineNickname, text: $input.nickname).textFieldStyle(.roundedBorder)
                Text(l.onlineNicknameHint).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(l.onlineJoin) {
                    if let action = input.joinAction(appliedServer: model.serverAddress, isBusy: model.isBusy) {
                        model.send(action); input.invite = ""
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(input.requirement(appliedServer: model.serverAddress, isBusy: model.isBusy) != .ready)
                Text(l.onlineSetupRequirement(input.requirement(appliedServer: model.serverAddress, isBusy: model.isBusy)))
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.practiceCard()
            DisclosureGroup(l.onlineRecovery) {
                VStack(alignment: .leading, spacing: 7) {
                    SecureField(l.onlineRecoveryCode, text: $recovery).textFieldStyle(.roundedBorder)
                    Button(l.onlineRecover) { model.send(.recover(code: recovery)); recovery = "" }
                        .disabled(model.isBusy || recovery.isEmpty || !input.hasAppliedServer(model.serverAddress))
                    Divider()
                    SecureField(l.onlineReconnectCode, text: $reconnect).textFieldStyle(.roundedBorder)
                    Button(l.onlineReconnect) { model.send(.reconnect(code: reconnect)); reconnect = "" }
                        .disabled(model.isBusy || reconnect.isEmpty || !input.hasAppliedServer(model.serverAddress))
                }.padding(.top, 6)
            }.practiceCard()
        }
        .onAppear { input.server = model.serverAddress }
    }
}
