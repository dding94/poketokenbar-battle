import AppKit
import SwiftUI

/// The online session survives closing this 360pt popover. Views only dispatch typed user intent.
@MainActor
struct OnlineBattleScreen: View {
    let model: OnlineBattlePresentation
    let l: L
    var artwork = true
    var readInvitationClipboard: () -> String? = { NSPasteboard.general.string(forType: .string) }
    /// Writes a host code to the pasteboard; false when the pasteboard refused it, so the code stays on screen.
    var writeClipboard: (String) -> Bool = { text in
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }
    var speciesNameProvider: any PokemonNameProviding = PokemonNameClient.shared
    var speciesNameStore: PokemonNameDisplayStore = .shared
    var onClosePopover: () -> Void = {}
    let onClose: () -> Void

    var showsGroupBack: Bool {
        !model.showsHistory && !model.showsStandings && model.rematchSourceID == nil && !model.showsHostPanel && [.room, .arena, .verifying].contains(model.phase)
    }
    func returnToGroup() { model.send(.backToLobby) }
    /// The header entry to the host panel: a host in the lobby, while the panel is not already open.
    var showsHostEntry: Bool { model.isHost && model.phase == .lobby && !model.showsHostPanel }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                // Esc leaves the screen, except while pinned: then it closes the popover (the close button owns it).
                Button(action: onClose) { Label(l.home, systemImage: "chevron.left") }
                    .buttonStyle(.borderless).keyboardShortcut(model.popoverPinned ? nil : .cancelAction)
                Spacer(minLength: 4)
                Text(l.onlineTitle).font(.headline)
                Spacer(minLength: 4)
                pinnedHeaderTrailing
            }.frame(height: 22)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if showsGroupBack {
                        Button(action: returnToGroup) { Label(l.onlineDone, systemImage: "person.2") }
                            .buttonStyle(.borderless).font(.caption)
                            .accessibilityIdentifier("online.backToGroup")
                    }
                    if let line = l.onlineConnectionLine(model.connectionStatus) {
                        Label(line, systemImage: "network")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let hint = model.notificationHint {
                        Label(l.onlineNotificationHint(hint), systemImage: "bell.slash")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("online.notificationHint")
                    }
                    if let notice = model.notice {
                        OnlineBattleNoticeBanner(text: notice, l: l) { model.send(.dismissNotice) }
                    }
                    if model.canRetryCredentialSave {
                        Button(l.onlineRetrySave) { model.send(.retryCredentialSave) }
                            .disabled(model.isBusy)
                    }
                    if model.recoveryCode != nil {
                        OnlineBattleRecoveryCodeCard(model: model, l: l, writeClipboard: writeClipboard)
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

    /// A fixed-width slot, so pinning never moves the title or changes the 360pt layout. A host's slot is wider by
    /// the member-management button, whether or not it shows right now, so the title stays put for a host as well.
    private var pinnedHeaderTrailing: some View {
        HStack(spacing: 6) {
            if model.isBusy { ProgressView().controlSize(.small) }
            if showsHostEntry {
                Button { model.send(.host(.open)) } label: { Image(systemName: "person.2.badge.gearshape") }
                    .buttonStyle(.borderless).disabled(!model.canOpenHostPanel)
                    .help(l.onlineHostOpen).accessibilityLabel(l.onlineHostOpen)
                    .accessibilityIdentifier("online.host.open")
            }
            if model.popoverPinned {
                Label(l.onlinePinned, systemImage: "pin.fill")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    .accessibilityElement(children: .ignore).accessibilityLabel(l.onlinePinned)
                    .accessibilityIdentifier("online.pinned")
                Button(action: onClosePopover) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.borderless).keyboardShortcut(.cancelAction)
                    .help(l.close).accessibilityLabel(l.close)
                    .accessibilityIdentifier("online.closePopover")
            }
        }
        .frame(width: model.isHost ? 132 : 104, alignment: .trailing)
    }

    @ViewBuilder private var stage: some View {
        if model.showsHostPanel {
            OnlineBattleHostPanel(model: model, l: l, writeClipboard: writeClipboard)
        } else if model.rematchSourceID != nil {
            OnlineBattleRematchPreparation(model: model, l: l, artwork: artwork)
        } else if model.showsStandings {
            OnlineBattleStandingsScreen(model: model, l: l)
        } else if model.showsHistory {
            OnlineBattleHistory(model: model, l: l, artwork: artwork,
                                speciesNameProvider: speciesNameProvider, speciesNameStore: speciesNameStore)
        } else {
        switch model.phase {
        case .setup:
            if model.showsRestoringAccount {
                OnlineBattleRestoringAccount(model: model, l: l)
            } else {
                OnlineBattleSetupForm(model: model, l: l, readInvitationClipboard: readInvitationClipboard)
            }
        case .lobby: OnlineBattleLobby(model: model, l: l, artwork: artwork)
        case .room: OnlineBattleRoom(model: model, l: l, artwork: artwork, speciesNameProvider: speciesNameProvider, speciesNameStore: speciesNameStore)
        case .arena: OnlineBattleArena(model: model, l: l, artwork: artwork, speciesNameProvider: speciesNameProvider, speciesNameStore: speciesNameStore)
        case .verifying:
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Label(l.onlineVerifying, systemImage: "checkmark.shield").font(.headline)
                    ProgressView().controlSize(.small)
                }
                Text(l.onlineVerifyingHint).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text(l.onlineVerifyingAuto).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("online.verifying.auto")
                // Updates arrive on their own; refreshing is only a manual shortcut.
                Button(l.onlineRefresh) { model.send(.refresh) }
                    .buttonStyle(.borderless).font(.caption).disabled(model.isBusy)
            }.frame(maxWidth: .infinity, alignment: .leading).practiceCard()
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
}

/// A saved account is on its way back. Nothing here is for the person to fill in, so no draft can be lost when it connects.
@MainActor
private struct OnlineBattleRestoringAccount: View {
    let model: OnlineBattlePresentation
    let l: L

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label(l.onlineRestoringTitle, systemImage: "person.crop.circle.badge.checkmark").font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                ProgressView().controlSize(.small)
            }
            Text(l.onlineRestoringHint).font(.callout).fixedSize(horizontal: false, vertical: true)
            Button(l.onlineRetry) { model.send(.refresh) }.disabled(model.isBusy)
                .accessibilityIdentifier("online.restoring.retry")
            Button(l.onlineRestoringOther) { model.send(.showSetupWhileRestoring) }
                .buttonStyle(.borderless).font(.caption)
                .accessibilityIdentifier("online.restoring.other")
        }
        .frame(maxWidth: .infinity, alignment: .leading).practiceCard()
    }
}

@MainActor
private struct OnlineBattleSetupForm: View {
    @Bindable var model: OnlineBattlePresentation
    let l: L
    let readInvitationClipboard: () -> String?
    private var input: OnlineBattleSetupInput { model.setupInput }
    private var requirement: OnlineBattleSetupInput.Requirement {
        input.requirement(isBusy: model.isBusy, serverIsEmbedded: model.serverIsEmbedded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(l.onlineSetup).font(.headline)
            // Only a click reads the clipboard; nothing here ever reads it on its own.
            Button(model.serverIsEmbedded ? l.onlinePasteInvitationEmbedded : l.onlinePasteInvitation) {
                model.setupPasteFailure = model.setupInput.pasteInvitation(
                    readInvitationClipboard(), embeddedServer: model.serverIsEmbedded ? model.serverAddress : nil)
            }
            .disabled(model.isBusy)
            .accessibilityIdentifier("online.pasteInvitation")
            if let failure = model.setupPasteFailure {
                Text(l.onlinePasteFailure(failure)).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("online.pasteFailure")
            }
            VStack(alignment: .leading, spacing: 7) {
                TextField(l.onlineNickname, text: $model.setupInput.nickname).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("online.nickname")
                Text(l.onlineNicknameHint).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField(l.onlineInvite, text: $model.setupInput.invite).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("online.invite")
                Button(l.onlineJoin) {
                    if let join = input.joinAction(appliedServer: model.serverAddress, isBusy: model.isBusy, serverIsEmbedded: model.serverIsEmbedded) {
                        model.send(join)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(requirement != .ready)
                .accessibilityIdentifier("online.join")
                Text(l.onlineSetupRequirement(requirement))
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.practiceCard()
            DisclosureGroup(l.onlineRecovery, isExpanded: $model.setupRecoveryExpanded) {
                VStack(alignment: .leading, spacing: 7) {
                    if !model.serverIsEmbedded, input.serverToApply == nil {
                        Text(l.onlineSetupRequirement(.serverMissing)).font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    SecureField(l.onlineRecoveryCode, text: $model.setupInput.recovery).textFieldStyle(.roundedBorder)
                    Button(l.onlineRecover) {
                        if let recover = input.recoverAction(appliedServer: model.serverAddress, isBusy: model.isBusy, serverIsEmbedded: model.serverIsEmbedded) {
                            model.send(recover)
                        }
                    }
                    .disabled(input.recoverAction(appliedServer: model.serverAddress, isBusy: model.isBusy, serverIsEmbedded: model.serverIsEmbedded) == nil)
                    Divider()
                    SecureField(l.onlineReconnectCode, text: $model.setupInput.reconnect).textFieldStyle(.roundedBorder)
                    Button(l.onlineReconnect) {
                        if let reconnect = input.reconnectAction(appliedServer: model.serverAddress, isBusy: model.isBusy, serverIsEmbedded: model.serverIsEmbedded) {
                            model.send(reconnect)
                        }
                    }
                    .disabled(input.reconnectAction(appliedServer: model.serverAddress, isBusy: model.isBusy, serverIsEmbedded: model.serverIsEmbedded) == nil)
                }.padding(.top, 6)
            }.practiceCard()
            // A build without a fixed server keeps manual entry, collapsed at the very bottom.
            if !model.serverIsEmbedded {
                DisclosureGroup(l.onlineAdvanced, isExpanded: $model.setupAdvancedExpanded) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(l.onlineServerHint).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        TextField(l.onlineServer, text: $model.setupInput.server).textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("online.server")
                        if input.serverToApply != nil, !input.hasAppliedServer(model.serverAddress) {
                            Text(l.onlineServerPending).font(.caption2).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }.padding(.top, 6)
                }.practiceCard()
            }
        }
    }
}
