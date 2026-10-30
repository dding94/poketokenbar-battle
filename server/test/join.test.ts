import { describe, expect, it } from "vitest";
import {
  DAY,
  HOUR,
  INVITE_RE,
  MINUTE,
  KEY_RE,
  RECOVERY_RE,
  advanceClock,
  call,
  createGroup,
  expectError,
  freshEmail,
  freshIp,
  issueInvite,
  join,
  joinRaw,
  useRealClockAfterEach,
} from "./helpers";

useRealClockAfterEach();

describe("POST /v1/invites", () => {
  it("defaults to 7 days and 30 uses, and shows the raw code only once", async () => {
    const host = await createGroup();
    const res = await call("POST", "/v1/invites", { key: host.accessKey, body: {} });
    expect(res.status, res.text).toBe(200);
    expect(res.body.inviteCode).toMatch(INVITE_RE);
    expect(res.body.invite).toMatchObject({ maxUses: 30, uses: 0, revoked: false });
    expect(res.body.invite.expiresAt - res.body.invite.createdAt).toBe(7 * DAY);

    const list = await call("GET", "/v1/invites", { key: host.accessKey });
    expect(list.status).toBe(200);
    expect(list.body.invites).toHaveLength(1);
    expect(list.body.invites[0]).toMatchObject({ inviteId: res.body.invite.inviteId, maxUses: 30, uses: 0, revoked: false });
    expect(list.text).not.toContain(res.body.inviteCode);
    expect(list.text).not.toContain(res.body.inviteCode.replaceAll("-", ""));
  });

  it("accepts custom ttl and uses within bounds", async () => {
    const host = await createGroup();
    const { invite } = await issueInvite(host.accessKey, { ttlSeconds: 3600, maxUses: 100 });
    expect(invite.expiresAt - invite.createdAt).toBe(HOUR);
    expect(invite.maxUses).toBe(100);
  });
});

describe("POST /v1/join", () => {
  it("gives a working key and a recovery code to a new member", async () => {
    const host = await createGroup();
    const { inviteCode } = await issueInvite(host.accessKey);
    const email = freshEmail("member");
    const res = await joinRaw(inviteCode, email);
    expect(res.status, res.text).toBe(200);
    expect(res.body.accessKey).toMatch(KEY_RE);
    expect(res.body.recoveryCode).toMatch(RECOVERY_RE);
    expect(res.body.trainer).toMatchObject({ displayEmail: email, role: "member", status: "active" });
    expect(res.body.group).toMatchObject({ groupId: host.groupId, hostTrainerId: host.trainerId });

    const me = await call("GET", "/v1/me", { key: res.body.accessKey });
    expect(me.status).toBe(200);
    expect(me.body.trainer.trainerId).toBe(res.body.trainer.trainerId);
    expect(me.body.group.groupId).toBe(host.groupId);

    const group = await call("GET", "/v1/group", { key: host.accessKey });
    expect(group.body.members.map((m: any) => m.trainerId).sort()).toEqual(
      [host.trainerId, res.body.trainer.trainerId].sort(),
    );
  });

  it("ignores case, hyphens and spaces in the invite code", async () => {
    const host = await createGroup();
    const { inviteCode } = await issueInvite(host.accessKey);
    const typed = ` ${inviteCode.toLowerCase().replaceAll("-", " ")} `;
    const res = await joinRaw(typed, freshEmail());
    expect(res.status, res.text).toBe(200);
  });

  it("rejects an unknown code with invalid_invite", async () => {
    expectError(await joinRaw("ZZZZ-ZZZZ-ZZZZ", freshEmail()), 404, "invalid_invite");
  });

  it("rejects a malformed code with invalid_invite", async () => {
    expectError(await joinRaw("not a code", freshEmail()), 404, "invalid_invite");
    expectError(await joinRaw("", freshEmail()), 404, "invalid_invite");
    expectError(await joinRaw("AAAA-AAAA-AAA", freshEmail()), 404, "invalid_invite");
  });

  it("rejects an expired invite with invite_expired", async () => {
    const host = await createGroup();
    const { inviteCode } = await issueInvite(host.accessKey, { ttlSeconds: 3600 });
    await advanceClock(HOUR - MINUTE);
    await join(inviteCode);
    await advanceClock(2 * MINUTE);
    expectError(await joinRaw(inviteCode, freshEmail()), 410, "invite_expired");
  });

  it("rejects a revoked invite with invite_revoked", async () => {
    const host = await createGroup();
    const { inviteCode, inviteId } = await issueInvite(host.accessKey);
    const revoke = await call("POST", "/v1/invites/revoke", { key: host.accessKey, body: { inviteId } });
    expect(revoke.status, revoke.text).toBe(200);
    expect(revoke.body.invite).toMatchObject({ inviteId, revoked: true });
    expectError(await joinRaw(inviteCode, freshEmail()), 410, "invite_revoked");
  });

  it("rejects a used-up invite with invite_used_up", async () => {
    const host = await createGroup();
    const { inviteCode } = await issueInvite(host.accessKey, { maxUses: 1 });
    await join(inviteCode);
    expectError(await joinRaw(inviteCode, freshEmail()), 410, "invite_used_up");
  });

  it("lets exactly the remaining number of parallel joins succeed", async () => {
    const host = await createGroup();
    const { inviteCode, inviteId } = await issueInvite(host.accessKey, { maxUses: 5 });
    await join(inviteCode);
    await join(inviteCode);

    const results = await Promise.all(
      Array.from({ length: 12 }, () => joinRaw(inviteCode, freshEmail("racer"), freshIp())),
    );
    const ok = results.filter((r) => r.status === 200);
    const usedUp = results.filter((r) => r.status === 410 && r.body?.error?.code === "invite_used_up");
    expect(ok).toHaveLength(3);
    expect(usedUp).toHaveLength(9);

    const list = await call("GET", "/v1/invites", { key: host.accessKey });
    expect(list.body.invites.find((i: any) => i.inviteId === inviteId).uses).toBe(5);
    const group = await call("GET", "/v1/group", { key: host.accessKey });
    expect(group.body.members).toHaveLength(6);
  });

  it("refuses an email already active in the group without touching the existing account", async () => {
    const host = await createGroup();
    const { inviteCode, inviteId } = await issueInvite(host.accessKey);
    const email = freshEmail("Alice");
    const alice = await join(inviteCode, email);

    const again = await joinRaw(inviteCode, `  ${email.toUpperCase()} `);
    expectError(again, 409, "display_email_taken");
    expect(again.text).not.toContain(alice.accessKey);
    expect(again.text).not.toContain(alice.recoveryCode);
    expect(again.text).not.toContain(alice.trainerId);

    const me = await call("GET", "/v1/me", { key: alice.accessKey });
    expect(me.status).toBe(200);
    expect(me.body.trainer.trainerId).toBe(alice.trainerId);

    const group = await call("GET", "/v1/group", { key: host.accessKey });
    expect(group.body.members).toHaveLength(2);
    const list = await call("GET", "/v1/invites", { key: host.accessKey });
    expect(list.body.invites.find((i: any) => i.inviteId === inviteId).uses).toBe(1);
  });

  it("treats the same email in another group as a separate account", async () => {
    const hostA = await createGroup();
    const hostB = await createGroup();
    const inviteA = await issueInvite(hostA.accessKey);
    const inviteB = await issueInvite(hostB.accessKey);
    const email = freshEmail("shared");
    const inA = await join(inviteA.inviteCode, email);
    const inB = await join(inviteB.inviteCode, email);

    expect(inB.trainerId).not.toBe(inA.trainerId);
    expect(inB.groupId).toBe(hostB.groupId);

    const groupSeenByB = await call("GET", "/v1/group", { key: inB.accessKey });
    expect(groupSeenByB.body.group.groupId).toBe(hostB.groupId);
    const ids = groupSeenByB.body.members.map((m: any) => m.trainerId);
    expect(ids).not.toContain(inA.trainerId);
    expect(ids).not.toContain(hostA.trainerId);

    const meA = await call("GET", "/v1/me", { key: inA.accessKey });
    expect(meA.body.group.groupId).toBe(hostA.groupId);
  });

  it("requires inviteCode and displayEmail", async () => {
    expectError(await call("POST", "/v1/join", { body: { displayEmail: freshEmail() } }), 400, "bad_request");
    expectError(await call("POST", "/v1/join", { body: { inviteCode: "AAAA-AAAA-AAAA" } }), 400, "bad_request");
  });
});
