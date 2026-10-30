import { describe, expect, it } from "vitest";
import {
  DAY,
  KEY_RE,
  MINUTE,
  RECONNECT_RE,
  RECOVERY_RE,
  advanceClock,
  call,
  expectError,
  freshEmail,
  issueReconnect,
  join,
  setupGroup,
  useRealClockAfterEach,
} from "./helpers";

useRealClockAfterEach();

function reconnect(reconnectCode: string, displayEmail?: string) {
  return call("POST", "/v1/reconnect", { body: displayEmail === undefined ? { reconnectCode } : { reconnectCode, displayEmail } });
}

describe("POST /v1/reconnect-codes", () => {
  it("is host-only", async () => {
    const { members } = await setupGroup(2);
    const res = await call("POST", "/v1/reconnect-codes", {
      key: members[0]!.accessKey,
      body: { trainerId: members[1]!.trainerId },
    });
    expectError(res, 403, "forbidden");
  });

  it("issues a code for a member that expires after 24 hours", async () => {
    const { host, members } = await setupGroup(1);
    const res = await call("POST", "/v1/reconnect-codes", { key: host.accessKey, body: { trainerId: members[0]!.trainerId } });
    expect(res.status, res.text).toBe(200);
    expect(res.body.reconnectCode).toMatch(RECONNECT_RE);
    expect(res.body.trainerId).toBe(members[0]!.trainerId);
    expect(typeof res.body.expiresAt).toBe("number");
  });

  it("refuses the host's own trainer id", async () => {
    const { host } = await setupGroup(0);
    const res = await call("POST", "/v1/reconnect-codes", { key: host.accessKey, body: { trainerId: host.trainerId } });
    expectError(res, 400, "cannot_target_self");
  });

  it("is not_found for an unknown trainer", async () => {
    const { host } = await setupGroup(0);
    const res = await call("POST", "/v1/reconnect-codes", { key: host.accessKey, body: { trainerId: "tr_missing" } });
    expectError(res, 404, "not_found");
  });
});

describe("POST /v1/reconnect", () => {
  it("rotates the key and recovery code of an active member", async () => {
    const { host, members } = await setupGroup(1);
    const member = members[0]!;
    const code = await issueReconnect(host.accessKey, member.trainerId);
    const res = await reconnect(code);
    expect(res.status, res.text).toBe(200);
    expect(res.body.accessKey).toMatch(KEY_RE);
    expect(res.body.recoveryCode).toMatch(RECOVERY_RE);
    expect(res.body.trainer).toMatchObject({ trainerId: member.trainerId, status: "active", displayEmail: member.email });

    expectError(await call("GET", "/v1/me", { key: member.accessKey }), 401, "unauthorized");
    expectError(await call("POST", "/v1/recover", { body: { recoveryCode: member.recoveryCode } }), 404, "invalid_code");
    expect((await call("GET", "/v1/me", { key: res.body.accessKey })).status).toBe(200);
  });

  it("is one-time", async () => {
    const { host, members } = await setupGroup(1);
    const code = await issueReconnect(host.accessKey, members[0]!.trainerId);
    expect((await reconnect(code)).status).toBe(200);
    expectError(await reconnect(code), 410, "code_used");
  });

  it("works until 24 hours and expires after", async () => {
    const { host, members } = await setupGroup(2);
    const early = await issueReconnect(host.accessKey, members[0]!.trainerId);
    const late = await issueReconnect(host.accessKey, members[1]!.trainerId);
    await advanceClock(DAY - MINUTE);
    expect((await reconnect(early)).status).toBe(200);
    await advanceClock(2 * MINUTE);
    expectError(await reconnect(late), 410, "code_expired");
  });

  it("voids an older unused code when a newer one is issued", async () => {
    const { host, members } = await setupGroup(1);
    const older = await issueReconnect(host.accessKey, members[0]!.trainerId);
    const newer = await issueReconnect(host.accessKey, members[0]!.trainerId);
    expect(newer).not.toBe(older);
    expectError(await reconnect(older), 410, "code_expired");
    expect((await reconnect(newer)).status).toBe(200);
  });

  it("brings a left account back under the same trainer id with its email re-entered", async () => {
    const { host, members } = await setupGroup(1);
    const member = members[0]!;
    expect((await call("POST", "/v1/leave", { key: member.accessKey })).status).toBe(200);

    const code = await issueReconnect(host.accessKey, member.trainerId);
    // A left account must give an email again; the code is not consumed by that mistake.
    expectError(await reconnect(code), 400, "bad_request");

    const newEmail = freshEmail("returning");
    const res = await reconnect(code, newEmail);
    expect(res.status, res.text).toBe(200);
    expect(res.body.trainer).toMatchObject({ trainerId: member.trainerId, status: "active", displayEmail: newEmail, role: "member" });

    const group = await call("GET", "/v1/group", { key: host.accessKey });
    expect(group.body.members.find((m: any) => m.trainerId === member.trainerId)).toMatchObject({
      status: "active",
      displayEmail: newEmail,
    });
    expect((await call("GET", "/v1/me", { key: res.body.accessKey })).status).toBe(200);
    expectError(await call("POST", "/v1/recover", { body: { recoveryCode: member.recoveryCode } }), 404, "invalid_code");
  });

  it("brings a removed account back the same way", async () => {
    const { host, members } = await setupGroup(1);
    const member = members[0]!;
    await call("POST", "/v1/members/remove", { key: host.accessKey, body: { trainerId: member.trainerId } });
    const code = await issueReconnect(host.accessKey, member.trainerId);
    const res = await reconnect(code, freshEmail("back"));
    expect(res.status, res.text).toBe(200);
    expect(res.body.trainer.trainerId).toBe(member.trainerId);
  });

  it("refuses a returning email that another active member uses", async () => {
    const { host, members, inviteCode } = await setupGroup(1);
    const member = members[0]!;
    await call("POST", "/v1/leave", { key: member.accessKey });
    const taker = await join(inviteCode, freshEmail("taker"));
    const code = await issueReconnect(host.accessKey, member.trainerId);
    expectError(await reconnect(code, taker.email.toUpperCase()), 409, "display_email_taken");
    expect((await reconnect(code, freshEmail("other"))).status).toBe(200);
  });

  it("voids unused codes when the account leaves", async () => {
    const { host, members } = await setupGroup(1);
    const member = members[0]!;
    const code = await issueReconnect(host.accessKey, member.trainerId);
    await call("POST", "/v1/leave", { key: member.accessKey });
    expectError(await reconnect(code, freshEmail()), 410, "code_expired");
  });

  it("rejects unknown and malformed codes with invalid_code", async () => {
    expectError(await reconnect("ZZZZ-ZZZZ-ZZZZ-ZZZZ"), 404, "invalid_code");
    expectError(await reconnect("??"), 404, "invalid_code");
  });

  it("records issue and use in an audit log every group member can read", async () => {
    const { host, members } = await setupGroup(2);
    const [target, witness] = [members[0]!, members[1]!];
    const code = await issueReconnect(host.accessKey, target.trainerId);
    expect((await reconnect(code)).status).toBe(200);

    const audit = await call("GET", "/v1/audit", { key: witness.accessKey });
    expect(audit.status, audit.text).toBe(200);
    const kinds = audit.body.entries.map((e: any) => [e.kind, e.actorTrainerId, e.targetTrainerId]);
    expect(kinds).toContainEqual(["reconnect_code_issued", host.trainerId, target.trainerId]);
    expect(kinds).toContainEqual(["reconnect_code_used", target.trainerId, target.trainerId]);
    expect(audit.text).not.toContain(code);
    expect(audit.text).not.toContain(code.replaceAll("-", ""));
  });
});
