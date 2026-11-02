import SwiftUI

/// The online session survives closing this 360pt popover. Views only dispatch typed user intent.
@MainActor
struct OnlineBattleScreen: View {
    let model: OnlineBattlePresentation
    let l: L
    var artwork = true
    let onClose: () -> Void

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
        switch model.phase {
        case .setup: OnlineBattleSetupForm(model: model, l: l)
        case .lobby: OnlineBattleLobby(model: model, l: l, artwork: artwork)
        case .room: OnlineBattleRoom(model: model, l: l, artwork: artwork)
        case .arena: OnlineBattleArena(model: model, l: l, artwork: artwork)
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
    @State private var server = ""
    @State private var invite = ""
    @State private var email = ""
    @State private var recovery = ""
    @State private var reconnect = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(l.onlineSetup).font(.headline)
            VStack(alignment: .leading, spacing: 7) {
                Text(l.onlineServerHint).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField(l.onlineServer, text: $server).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("online.server")
                Button(l.onlineSaveServer) { model.send(.configureServer(server)) }
                    .disabled(model.isBusy || (try? OnlineBattleOrigin(server)) == nil)
            }.practiceCard()
            VStack(alignment: .leading, spacing: 7) {
                TextField(l.onlineInvite, text: $invite).textFieldStyle(.roundedBorder)
                TextField(l.onlineEmail, text: $email).textFieldStyle(.roundedBorder)
                Text(l.onlineEmailHint).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(l.onlineJoin) {
                    model.send(.join(inviteCode: invite, email: email)); invite = ""
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy || invite.isEmpty || email.isEmpty || model.serverAddress.isEmpty)
            }.practiceCard()
            DisclosureGroup(l.onlineRecovery) {
                VStack(alignment: .leading, spacing: 7) {
                    SecureField(l.onlineRecoveryCode, text: $recovery).textFieldStyle(.roundedBorder)
                    Button(l.onlineRecover) { model.send(.recover(code: recovery)); recovery = "" }
                        .disabled(model.isBusy || recovery.isEmpty || model.serverAddress.isEmpty)
                    Divider()
                    SecureField(l.onlineReconnectCode, text: $reconnect).textFieldStyle(.roundedBorder)
                    Button(l.onlineReconnect) { model.send(.reconnect(code: reconnect)); reconnect = "" }
                        .disabled(model.isBusy || reconnect.isEmpty || model.serverAddress.isEmpty)
                }.padding(.top, 6)
            }.practiceCard()
        }
        .onAppear { server = model.serverAddress }
    }
}
