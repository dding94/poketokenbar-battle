import AppKit
import SwiftUI

/// The host's group care: invite codes, members, reconnect codes. Drawn instead of the lobby while it is open.
/// A code shown here is the only copy: it stays until it is copied or hidden, and the popover stays open meanwhile.
@MainActor
struct OnlineBattleHostPanel: View {
    let model: OnlineBattlePresentation
    let l: L
    var writeClipboard: (String) -> Bool = { OnlineBattleClipboard.write($0) }

    /// Puts the shown code on the clipboard; only then does the screen forget it.
    func copySecret() {
        guard let secret = model.host.secret else { return }
        let server = model.serverIsEmbedded ? nil : model.serverAddress
        guard writeClipboard(secret.clipboardText(server: server, l: l)) else { return }
        model.send(.host(.copied))
    }

    private func name(of trainerId: String) -> String? {
        model.members.first { $0.trainerId == trainerId }?.displayEmail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { model.send(.host(.close)) } label: { Label(l.onlineHostBack, systemImage: "chevron.left") }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("online.host.back")
                Spacer(minLength: 4)
                if model.host.busy { ProgressView().controlSize(.small) }
            }
            Text(l.onlineHostTitle).font(.headline)
            Text(model.account?.group.name ?? l.onlineTitle)
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            if let text = model.host.notice {
                noticeRow(text)
            }
            if let secret = model.host.secret {
                secretCard(secret)
            } else if let copied = model.host.copied {
                copiedCard(copied)
            }
            invites
            members
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func noticeRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle.fill").foregroundStyle(.secondary).accessibilityHidden(true)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("online.host.notice")
            Button { model.send(.host(.dismissNotice)) } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).font(.caption).accessibilityLabel(l.onlineDismissNotice)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .practiceCard()
    }

    private func secretCard(_ secret: OnlineBattleHostSecret) -> some View {
        let who: String? = { if case .reconnect(let id) = secret.kind { return name(of: id) } else { return nil } }()
        return VStack(alignment: .leading, spacing: 8) {
            Label(l.onlineHostSecretTitle(secret, name: who), systemImage: "key.fill").font(.subheadline.bold())
                .fixedSize(horizontal: false, vertical: true)
            Text(secret.code).font(.system(.title3, design: .monospaced)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("online.host.code")
            Text(l.onlineHostSecretDetail(secret, name: who)).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Label(l.onlineHostStaysOpen, systemImage: "pin.fill").font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(l.onlineHostCopy) { copySecret() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("online.host.copy")
                Button(l.onlineHostHide) { model.send(.host(.dismissSecret)) }
                    .accessibilityIdentifier("online.host.hide")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .practiceCard()
        .privacySensitive()
    }

    private func copiedCard(_ kind: OnlineBattleHostSecret.Kind) -> some View {
        let who: String? = { if case .reconnect(let id) = kind { return name(of: id) } else { return nil } }()
        return Label(l.onlineHostCopied(kind, name: who), systemImage: "checkmark.circle.fill")
            .font(.callout).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .practiceCard()
            .accessibilityIdentifier("online.host.copied")
    }

    @ViewBuilder private var invites: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(l.onlineHostInvitesTitle).font(.subheadline.bold())
            Picker(l.onlineHostInvitesTitle, selection: Binding(get: { model.host.choice },
                                                               set: { model.send(.host(.chooseInvite($0))) })) {
                ForEach(OnlineBattleHostInviteChoice.allCases, id: \.self) { Text(l.onlineHostChoice($0)).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().disabled(model.host.busy)
            .accessibilityIdentifier("online.host.choice")
            Button(l.onlineHostCreateInvite) { model.send(.host(.createInvite(model.host.choice))) }
                .buttonStyle(.borderedProminent).disabled(model.host.busy)
                .accessibilityIdentifier("online.host.create")
            Text(l.onlineHostInviteHint).font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .practiceCard()
        VStack(alignment: .leading, spacing: 8) {
            Text(l.onlineHostActiveInvites).font(.subheadline.bold())
            if model.host.invitesFailed {
                Text(l.onlineHostInvitesFailed).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button(l.onlineRetry) { model.send(.host(.refreshInvites)) }
                    .disabled(model.host.busy)
                    .accessibilityIdentifier("online.host.invites.retry")
            } else if model.host.invites == nil {
                Text(l.onlineHostInvitesLoading).font(.caption).foregroundStyle(.secondary)
            } else if model.host.activeInvites().isEmpty {
                Text(l.onlineHostNoInvites).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.host.activeInvites(), id: \.inviteId) { invite in
                HStack(alignment: .top, spacing: 6) {
                    Text(l.onlineHostInviteLine(invite)).font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(l.onlineHostRevoke) { model.send(.host(.revokeInvite(invite.inviteId))) }
                        .buttonStyle(.borderless).font(.caption).foregroundStyle(.red).disabled(model.host.busy)
                        .accessibilityIdentifier("online.host.revoke.\(invite.inviteId)")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .practiceCard()
    }

    @ViewBuilder private var members: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(l.onlineHostMembers).font(.subheadline.bold())
            if model.hostMembers.isEmpty {
                Text(l.onlineHostNoMembers).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(model.hostMembers, id: \.trainerId) { member in
                let display = member.displayEmail ?? l.onlineAnonymous
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Circle().fill(member.online ? Color.green : Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
                            .accessibilityHidden(true)
                        Text(display).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        Button(l.onlineHostReissue) { model.send(.host(.issueReconnect(member.trainerId))) }
                            .buttonStyle(.borderless).font(.caption).disabled(model.host.busy)
                            .accessibilityIdentifier("online.host.reconnect.\(member.trainerId)")
                        Button(l.onlineHostRemove) { model.send(.host(.askRemove(member.trainerId))) }
                            .buttonStyle(.borderless).font(.caption).foregroundStyle(.red).disabled(model.host.busy)
                            .accessibilityIdentifier("online.host.remove.\(member.trainerId)")
                    }
                    if model.host.pendingRemoval == member.trainerId {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(l.onlineHostConfirmRemove(name: display)).font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack {
                                Button(l.onlineHostConfirmRemoveButton) { model.send(.host(.confirmRemove(member.trainerId))) }
                                    .disabled(model.host.busy)
                                    .accessibilityIdentifier("online.host.remove.confirm")
                                Button(l.onlineHostCancelRemove) { model.send(.host(.cancelRemove)) }
                                    .accessibilityIdentifier("online.host.remove.cancel")
                            }
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.08)))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .practiceCard()
    }
}
