import XCTest
@testable import PokeTokenBar

/// T10: what the host panel offers, says and holds. The session's I/O is in OnlineBattleSessionTests; here the
/// presentation guards, the words, the clipboard text and the popover rules around a code that has to be copied.
@MainActor
final class OnlineBattleHostPanelTests: XCTestCase {
    private func model(role: OnlineBattleTrainer.Role = .host, phase: OnlineBattlePresentation.Phase = .lobby) -> OnlineBattlePresentation {
        let model = OnlineBattlePresentation()
        model.account = .init(trainer: .init(trainerId: "me", displayEmail: "나래", role: role, status: .active),
                              group: .init(groupId: "g", name: "동료들", hostTrainerId: "me"))
        model.members = [.init(trainerId: "me", displayEmail: "나래", role: role, status: .active, joinedAt: 0, online: true),
                         .init(trainerId: "foe", displayEmail: "한별", role: .member, status: .active, joinedAt: 0, online: true),
                         .init(trainerId: "gone", displayEmail: "떠난사람", role: .member, status: .left, joinedAt: 0, online: false)]
        model.phase = phase
        return model
    }
    private func record(_ model: OnlineBattlePresentation) -> () -> [OnlineBattleHostAction] {
        var sent: [OnlineBattleHostAction] = []
        model.onAction = { if case .host(let action) = $0 { sent.append(action) } }
        return { sent }
    }
    private func secret(_ kind: OnlineBattleHostSecret.Kind = .invite(maxUses: 30), code: String = "ABCDEFGHJKMN") -> OnlineBattleHostSecret {
        .init(kind: kind, code: code, expiresAt: 1_793_683_500_000 + 7 * 86_400_000)
    }

    // MARK: who gets the panel

    func testOnlyAHostInTheLobbyCanOpenThePanel() {
        XCTAssertTrue(model().canOpenHostPanel)
        XCTAssertFalse(model(role: .member).canOpenHostPanel)
        for phase in [OnlineBattlePresentation.Phase.setup, .room, .arena, .verifying, .result] {
            XCTAssertFalse(model(phase: phase).canOpenHostPanel, "\(phase)")
        }
        let covered = model(); covered.showsHistory = true
        XCTAssertFalse(covered.canOpenHostPanel)
        let busy = model(); busy.isBusy = true
        XCTAssertFalse(busy.canOpenHostPanel)
    }

    func testAMemberNeverSendsAHostAction() {
        let member = model(role: .member)
        let sent = record(member)
        member.host.visible = true
        for action: OnlineBattleHostAction in [.open, .refreshInvites, .createInvite(.group), .revokeInvite("inv"), .issueReconnect("foe"), .confirmRemove("foe")] {
            member.send(.host(action))
        }
        XCTAssertTrue(sent().isEmpty)
        XCTAssertFalse(member.showsHostPanel, "the flag alone shows nothing to a member")
    }

    func testTheHostReachesTheSessionOnlyForThingsTheSessionMustDo() {
        let host = model()
        let sent = record(host)
        host.send(.host(.open))
        XCTAssertEqual(sent(), [.open])
        host.host.visible = true
        host.send(.host(.createInvite(.single))); host.send(.host(.revokeInvite("inv"))); host.send(.host(.issueReconnect("foe")))
        host.send(.host(.refreshInvites))
        XCTAssertEqual(sent(), [.open, .createInvite(.single), .revokeInvite("inv"), .issueReconnect("foe"), .refreshInvites])
    }

    func testNothingReachesTheSessionWhileAHostCallIsRunningOrTheTargetIsNotAMember() {
        let host = model()
        host.host.visible = true
        let sent = record(host)
        host.host.busy = true
        host.send(.host(.createInvite(.group))); host.send(.host(.revokeInvite("inv"))); host.send(.host(.issueReconnect("foe")))
        host.host.busy = false
        host.send(.host(.issueReconnect("me")))     // the host itself
        host.send(.host(.issueReconnect("gone")))   // someone who left
        host.send(.host(.issueReconnect("nobody")))
        XCTAssertTrue(sent().isEmpty)
    }

    // MARK: choosing, copying and the second step of a removal stay on the screen

    func testTheInviteChoiceCopyAndHideNeverReachTheSession() {
        let host = model()
        host.host.visible = true
        let sent = record(host)
        host.send(.host(.chooseInvite(.single)))
        XCTAssertEqual(host.host.choice, .single)
        host.host.secret = secret()
        host.send(.host(.copied))
        XCTAssertNil(host.host.secret, "a copied code is gone from the screen")
        XCTAssertEqual(host.host.copied, .invite(maxUses: 30), "only the fact stays")
        host.host.secret = secret(); host.host.copied = nil
        host.send(.host(.dismissSecret))
        XCTAssertNil(host.host.secret)
        XCTAssertNil(host.host.copied)
        host.host.notice = "x"
        host.send(.host(.dismissNotice))
        XCTAssertNil(host.host.notice)
        XCTAssertTrue(sent().isEmpty)
    }

    func testCopiedWithNothingOnScreenChangesNothing() {
        let host = model()
        host.host.visible = true
        host.send(.host(.copied))
        XCTAssertNil(host.host.copied)
    }

    func testRemovingAMemberIsAskedThenConfirmedForTheSameMember() {
        let host = model()
        host.host.visible = true
        let sent = record(host)
        host.send(.host(.confirmRemove("foe")))
        XCTAssertTrue(sent().isEmpty, "confirming what was never asked does nothing")
        host.send(.host(.askRemove("me")))
        host.send(.host(.askRemove("gone")))
        XCTAssertNil(host.host.pendingRemoval, "the host and a member who left cannot be asked about")
        host.send(.host(.askRemove("foe")))
        XCTAssertEqual(host.host.pendingRemoval, "foe")
        host.send(.host(.cancelRemove))
        XCTAssertNil(host.host.pendingRemoval)
        host.send(.host(.askRemove("foe")))
        host.send(.host(.confirmRemove("somebody-else")))
        XCTAssertTrue(sent().isEmpty)
        host.send(.host(.confirmRemove("foe")))
        XCTAssertEqual(sent(), [.confirmRemove("foe")])
    }

    func testClosingThePanelForgetsEverythingItHeld() {
        let host = model()
        host.host.visible = true; host.host.secret = secret(); host.host.pendingRemoval = "foe"; host.host.notice = "x"
        host.host.choice = .single; host.host.invites = []
        host.send(.host(.close))
        XCTAssertFalse(host.showsHostPanel)
        XCTAssertNil(host.host.secret); XCTAssertNil(host.host.pendingRemoval); XCTAssertNil(host.host.notice)
        XCTAssertNil(host.host.invites)
        XCTAssertEqual(host.host.choice, .group, "the safe default comes back")
    }

    func testAnotherAccountOrALostRoleTakesThePanelAway() {
        let host = model()
        host.host.visible = true; host.host.secret = secret()
        host.account = .init(trainer: .init(trainerId: "me", displayEmail: "나래", role: .host, status: .active),
                             group: .init(groupId: "g", name: "이름이 바뀐 그룹", hostTrainerId: "me"))
        XCTAssertTrue(host.hostSecretShowing, "a refresh of the same host keeps the unsaved code")
        host.account = .init(trainer: .init(trainerId: "me", displayEmail: "나래", role: .member, status: .active),
                             group: .init(groupId: "g", name: "동료들", hostTrainerId: "other"))
        XCTAssertNil(host.host.secret)
        XCTAssertFalse(host.host.visible)
    }

    // MARK: the invite list

    func testAnInviteIsActiveUntilRevokedExpiredOrUsedUp() {
        let now = Date(timeIntervalSince1970: 1_793_683_500)
        func invite(maxUses: Int = 30, uses: Int = 0, revoked: Bool = false, expiresAt: Double = 1_793_683_500_000 + 1) -> OnlineBattleInvite {
            .init(inviteId: "i", createdAt: 1, expiresAt: expiresAt, maxUses: maxUses, uses: uses, revoked: revoked, revokedAt: nil)
        }
        XCTAssertTrue(invite().isActive(now: now))
        XCTAssertFalse(invite(revoked: true).isActive(now: now))
        XCTAssertFalse(invite(expiresAt: 1_793_683_500_000).isActive(now: now), "expiring right now is expired")
        XCTAssertFalse(invite(maxUses: 1, uses: 1).isActive(now: now))
        XCTAssertTrue(invite(maxUses: 2, uses: 1).isActive(now: now))
    }

    // MARK: what goes on the clipboard

    func testAnInviteOnAnEmbeddedBuildCopiesTheCodeAlone() {
        for l in [L(.ko), L(.en)] {
            XCTAssertEqual(secret().clipboardText(server: nil, l: l), "ABCDEFGHJKMN")
            XCTAssertEqual(secret(.reconnect(trainerId: "foe"), code: "RECONNECTCODE16").clipboardText(server: "https://battle.example.invalid", l: l), "RECONNECTCODE16",
                           "a reconnect code is just the code, whatever the build")
        }
    }

    /// The text a manual build copies must be exactly what the join form's paste accepts.
    func testAnInviteOnAManualBuildCopiesAddressAndCodeThatTheJoinFormPastesBack() {
        for l in [L(.ko), L(.en)] {
            let text = secret().clipboardText(server: "https://battle.example.invalid", l: l)
            XCTAssertTrue(text.contains("ABCDEFGHJKMN")); XCTAssertTrue(text.contains("https://battle.example.invalid"))
            var input = OnlineBattleSetupInput()
            XCTAssertNil(input.pasteInvitation(text, embeddedServer: nil))
            XCTAssertEqual(input.invite, "ABCDEFGHJKMN")
            XCTAssertEqual(input.serverToApply, "https://battle.example.invalid")
        }
    }

    // MARK: words

    func testEveryHostWordIsWrittenInKoreanAndEnglish() {
        let ko = L(.ko), en = L(.en)
        let invite = OnlineBattleInvite(inviteId: "i", createdAt: 1_793_683_500_000, expiresAt: 1_793_683_500_000 + 7 * 86_400_000, maxUses: 30, uses: 4, revoked: false, revokedAt: nil)
        let zone = TimeZone(identifier: "Asia/Seoul")!
        let pairs: [(String, String)] = [
            (ko.onlineHostOpen, en.onlineHostOpen), (ko.onlineHostTitle, en.onlineHostTitle), (ko.onlineHostBack, en.onlineHostBack),
            (ko.onlineHostInvitesTitle, en.onlineHostInvitesTitle),
            (ko.onlineHostChoice(.group), en.onlineHostChoice(.group)), (ko.onlineHostChoice(.single), en.onlineHostChoice(.single)),
            (ko.onlineHostCreateInvite, en.onlineHostCreateInvite), (ko.onlineHostInviteHint, en.onlineHostInviteHint),
            (ko.onlineHostSecretTitle(secret(), name: nil), en.onlineHostSecretTitle(secret(), name: nil)),
            (ko.onlineHostSecretTitle(secret(.reconnect(trainerId: "foe")), name: "한별"), en.onlineHostSecretTitle(secret(.reconnect(trainerId: "foe")), name: "한별")),
            (ko.onlineHostSecretDetail(secret(), name: nil, timeZone: zone), en.onlineHostSecretDetail(secret(), name: nil, timeZone: zone)),
            (ko.onlineHostSecretDetail(secret(.invite(maxUses: 1)), name: nil, timeZone: zone), en.onlineHostSecretDetail(secret(.invite(maxUses: 1)), name: nil, timeZone: zone)),
            (ko.onlineHostSecretDetail(secret(.reconnect(trainerId: "foe")), name: "한별", timeZone: zone), en.onlineHostSecretDetail(secret(.reconnect(trainerId: "foe")), name: "한별", timeZone: zone)),
            (ko.onlineHostStaysOpen, en.onlineHostStaysOpen), (ko.onlineHostCopy, en.onlineHostCopy), (ko.onlineHostHide, en.onlineHostHide),
            (ko.onlineHostCopied(.invite(maxUses: 30), name: nil), en.onlineHostCopied(.invite(maxUses: 30), name: nil)),
            (ko.onlineHostCopied(.reconnect(trainerId: "foe"), name: "한별"), en.onlineHostCopied(.reconnect(trainerId: "foe"), name: "한별")),
            (ko.onlineHostActiveInvites, en.onlineHostActiveInvites), (ko.onlineHostNoInvites, en.onlineHostNoInvites),
            (ko.onlineHostInviteLine(invite, timeZone: zone), en.onlineHostInviteLine(invite, timeZone: zone)),
            (ko.onlineHostRevoke, en.onlineHostRevoke), (ko.onlineHostRevoked, en.onlineHostRevoked),
            (ko.onlineHostInvitesFailed, en.onlineHostInvitesFailed), (ko.onlineHostInvitesLoading, en.onlineHostInvitesLoading),
            (ko.onlineHostMembers, en.onlineHostMembers), (ko.onlineHostNoMembers, en.onlineHostNoMembers),
            (ko.onlineHostReissue, en.onlineHostReissue), (ko.onlineHostRemove, en.onlineHostRemove),
            (ko.onlineHostConfirmRemove(name: "한별"), en.onlineHostConfirmRemove(name: "한별")),
            (ko.onlineHostConfirmRemoveButton, en.onlineHostConfirmRemoveButton), (ko.onlineHostCancelRemove, en.onlineHostCancelRemove),
            (ko.onlineHostRemoved(name: "한별", revokedInvites: 0), en.onlineHostRemoved(name: "한별", revokedInvites: 0)),
            (ko.onlineHostRemoved(name: "한별", revokedInvites: 3), en.onlineHostRemoved(name: "한별", revokedInvites: 3)),
        ]
        for (index, pair) in pairs.enumerated() {
            XCTAssertFalse(pair.0.isEmpty, "ko #\(index)"); XCTAssertFalse(pair.1.isEmpty, "en #\(index)")
            XCTAssertNotEqual(pair.0, pair.1, "#\(index)")
        }
        for code in [OnlineBattleServerCode.forbidden, .notFound, .cannotTargetSelf] {
            let error = OnlineBattleServerError(code: code, retryAfter: nil)
            XCTAssertNotNil(ko.onlineHostServerError(error), "\(code)")
            XCTAssertNotEqual(ko.onlineHostServerError(error), en.onlineHostServerError(error), "\(code)")
        }
        XCTAssertNil(ko.onlineHostServerError(.init(code: .internal, retryAfter: nil)), "an unknown refusal falls back to the general notice")
    }

    func testTheWordsNameWhoAndWhatTheyAreAbout() {
        for l in [L(.ko), L(.en)] {
            XCTAssertTrue(l.onlineHostConfirmRemove(name: "한별").contains("한별"))
            XCTAssertTrue(l.onlineHostSecretTitle(secret(.reconnect(trainerId: "foe")), name: "한별").contains("한별"))
            XCTAssertTrue(l.onlineHostRemoved(name: "한별", revokedInvites: 3).contains("3"))
            XCTAssertTrue(l.onlineHostRemoved(name: "한별", revokedInvites: 3).contains("한별"))
            XCTAssertFalse(l.onlineHostRemoved(name: "한별", revokedInvites: 0).contains("0 "), "no count when none were open")
            XCTAssertNotEqual(l.onlineHostRemoved(name: "한별", revokedInvites: 0), l.onlineHostRemoved(name: "한별", revokedInvites: 3))
            XCTAssertTrue(l.onlineHostSecretDetail(secret(.invite(maxUses: 30)), name: nil).contains("30"))
            XCTAssertNotEqual(l.onlineHostChoice(.group), l.onlineHostChoice(.single))
        }
    }

    // MARK: banner and routing while the panel covers the room

    func testTheHostPanelCoversTheRoomSoTheBannerStaysAndAnOpeningLandsOnIt() {
        let host = model(phase: .room)
        let room = OnlineBattleView(battleId: "bt-in", state: .pending, revision: 1, mode: .manual,
                                    p1: .init(trainerId: "foe", snapshot: nil, publicInfo: nil, hpPercent: nil),
                                    p2: .init(trainerId: "me", snapshot: nil, publicInfo: nil, hpPercent: nil),
                                    createdAt: 1, expiresAt: Date().timeIntervalSince1970 * 1000 + 3_600_000, startedAt: nil, reportedAt: nil,
                                    confirmed: false, config: nil, roundSeq: 0, deadline: nil, ownChoice: nil, journal: [], result: nil, reason: nil, rematchOf: nil)
        host.battles = [room]; host.room = room
        let source = OnlineAttentionSource(presentation: host)
        XCTAssertNil(source.banner(onlineScreenShowing: true), "the room is on screen")
        host.host.visible = true
        XCTAssertEqual(source.banner(onlineScreenShowing: true)?.battleId, "bt-in", "the panel covers it")
        host.host.visible = false
        XCTAssertNil(source.banner(onlineScreenShowing: true))
        // A code on screen is gone for good if it is not copied: the opening lands on the screen that shows it.
        host.host.visible = true; host.host.secret = secret()
        host.phase = .lobby; host.battles = []; host.room = nil
        XCTAssertEqual(source.openRoute(), .init(battleId: nil))
        host.host.secret = nil
        XCTAssertNil(source.openRoute())
    }
}
