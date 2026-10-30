import { describe, expect, it } from "vitest";
import {
  call,
  freshEmail,
  issueInvite,
  issueReconnect,
  join,
  leaveGroup,
  reconnectWith,
  recoverAccount,
  removeMember,
  setupGroup,
  transferHost,
} from "../helpers";
import { closeSocketsAfterAll, connectRaw, groupChanged, presence, socketFor } from "./socket";

closeSocketsAfterAll();

const REVOKED = { code: 4003, reason: "revoked" };

describe("group_changed", () => {
  it("follows a join", async () => {
    const { host, members, inviteCode } = await setupGroup(1);
    const hostSocket = await socketFor(host.accessKey);
    const memberSocket = await socketFor(members[0]!.accessKey);
    expect(await hostSocket.next()).toEqual(presence(members[0]!.trainerId, true));

    await join(inviteCode);
    expect(await hostSocket.next()).toEqual(groupChanged("join"));
    expect(await memberSocket.next()).toEqual(groupChanged("join"));
  });

  it("follows a host transfer, to every member including the old host", async () => {
    const { host, members } = await setupGroup(1);
    const b = members[0]!;
    const hostSocket = await socketFor(host.accessKey);
    const memberSocket = await socketFor(b.accessKey);
    expect(await hostSocket.next()).toEqual(presence(b.trainerId, true));

    expect((await transferHost(host.accessKey, b.trainerId)).status).toBe(200);
    expect(await hostSocket.next()).toEqual(groupChanged("host_transfer"));
    expect(await memberSocket.next()).toEqual(groupChanged("host_transfer"));
    expect(hostSocket.closeInfo).toBeNull();
  });

  it("follows a left account's return", async () => {
    const { host, members } = await setupGroup(1);
    const b = members[0]!;
    expect((await leaveGroup(b.accessKey)).status).toBe(200);
    const hostSocket = await socketFor(host.accessKey);
    const code = await issueReconnect(host.accessKey, b.trainerId);

    const back = await reconnectWith(code, freshEmail("back"));
    expect(back.status, back.text).toBe(200);
    expect(await hostSocket.next()).toEqual(groupChanged("return"));

    // The returned account connects with its new key.
    await socketFor(back.body.accessKey);
    expect(await hostSocket.next()).toEqual(presence(b.trainerId, true));
  });

  it("is not sent for invites, failed operations or recovery", async () => {
    const { host, members } = await setupGroup(1);
    const b = members[0]!;
    const hostSocket = await socketFor(host.accessKey);
    const { inviteId } = await issueInvite(host.accessKey);
    await call("POST", "/v1/invites/revoke", { key: host.accessKey, body: { inviteId } });
    expect((await leaveGroup(host.accessKey)).status).toBe(409);
    expect((await removeMember(host.accessKey, host.trainerId)).status).toBe(400);
    expect((await transferHost(b.accessKey, host.trainerId)).status).toBe(403);
    await recoverAccount(b);
    await hostSocket.sync();
    expect(hostSocket.messages.map((m) => m.type)).toEqual(["hello"]);
    expect(hostSocket.closeInfo).toBeNull();
  });
});

describe("revocation closes the trainer's sockets with 4003 after the change commits", () => {
  it("on recover", async () => {
    const { host, members } = await setupGroup(1);
    const b = members[0]!;
    const watcher = await socketFor(host.accessKey);
    const socket = await socketFor(b.accessKey);
    expect(await watcher.next()).toEqual(presence(b.trainerId, true));

    const fresh = await recoverAccount(b);
    expect(await socket.closed()).toEqual(REVOKED);
    expect(await watcher.next()).toEqual(presence(b.trainerId, false));
    // Recovery is not a group change; the new key connects normally.
    await socketFor(fresh.accessKey);
    expect(await watcher.next()).toEqual(presence(b.trainerId, true));
  });

  it("on reconnect of an active account", async () => {
    const { host, members } = await setupGroup(1);
    const b = members[0]!;
    const watcher = await socketFor(host.accessKey);
    const socket = await socketFor(b.accessKey);
    expect(await watcher.next()).toEqual(presence(b.trainerId, true));

    const res = await reconnectWith(await issueReconnect(host.accessKey, b.trainerId));
    expect(res.status, res.text).toBe(200);
    expect(await socket.closed()).toEqual(REVOKED);
    expect(await watcher.next()).toEqual(presence(b.trainerId, false));
    await watcher.sync();
    await socketFor(res.body.accessKey);
    expect(await watcher.next()).toEqual(presence(b.trainerId, true));
  });

  it("on leave, before peers hear of the change", async () => {
    const { host, members } = await setupGroup(1);
    const b = members[0]!;
    const watcher = await socketFor(host.accessKey);
    const socket = await socketFor(b.accessKey);
    expect(await watcher.next()).toEqual(presence(b.trainerId, true));

    expect((await leaveGroup(b.accessKey)).status).toBe(200);
    expect(await socket.closed()).toEqual(REVOKED);
    expect(await watcher.next()).toEqual(presence(b.trainerId, false));
    expect(await watcher.next()).toEqual(groupChanged("leave"));
    // The leaver hears nothing after hello.
    expect(socket.messages.map((m) => m.type)).toEqual(["hello"]);
  });

  it("on remove", async () => {
    const { host, members } = await setupGroup(2);
    const [b, c] = [members[0]!, members[1]!];
    const watcher = await socketFor(host.accessKey);
    const peer = await socketFor(c.accessKey);
    const socket = await socketFor(b.accessKey);
    expect(await watcher.next()).toEqual(presence(c.trainerId, true));
    expect(await watcher.next()).toEqual(presence(b.trainerId, true));
    expect(await peer.next()).toEqual(presence(b.trainerId, true));

    expect((await removeMember(host.accessKey, b.trainerId)).status).toBe(200);
    expect(await socket.closed()).toEqual(REVOKED);
    for (const s of [watcher, peer]) {
      expect(await s.next()).toEqual(presence(b.trainerId, false));
      expect(await s.next()).toEqual(groupChanged("remove"));
    }
    expect(socket.messages.map((m) => m.type)).toEqual(["hello"]);
    expect((await connectRaw({ key: b.accessKey })).status).toBe(401);
  });

  it("not when the operation fails", async () => {
    const { host, members } = await setupGroup(1);
    const b = members[0]!;
    const socket = await socketFor(b.accessKey);
    const watcher = await socketFor(host.accessKey);
    // A bad recovery code, a bad reconnect code, a refused removal.
    expect((await call("POST", "/v1/recover", { body: { recoveryCode: "ZZZZ-ZZZZ-ZZZZ-ZZZZ" } })).status).toBe(404);
    expect((await reconnectWith("ZZZZ-ZZZZ-ZZZZ-ZZZZ")).status).toBe(404);
    expect((await removeMember(b.accessKey, host.trainerId)).status).toBe(403);
    await socket.sync();
    expect(socket.closeInfo).toBeNull();
    await watcher.sync();
    expect(watcher.messages.map((m) => m.type)).toEqual(["hello"]);
  });
});
