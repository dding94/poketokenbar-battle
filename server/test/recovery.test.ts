import { describe, expect, it } from "vitest";
import { KEY_RE, RECOVERY_RE, call, expectError, recoverAccount, setupGroup } from "./helpers";

describe("POST /v1/recover", () => {
  it("rotates the key and the recovery code and rejects both old ones", async () => {
    const { members } = await setupGroup(1);
    const member = members[0]!;
    const res = await call("POST", "/v1/recover", { body: { recoveryCode: member.recoveryCode } });
    expect(res.status, res.text).toBe(200);
    expect(res.body.accessKey).toMatch(KEY_RE);
    expect(res.body.recoveryCode).toMatch(RECOVERY_RE);
    expect(res.body.accessKey).not.toBe(member.accessKey);
    expect(res.body.recoveryCode).not.toBe(member.recoveryCode);
    expect(res.body.trainer.trainerId).toBe(member.trainerId);
    expect(res.body.group.groupId).toBe(member.groupId);

    expectError(await call("GET", "/v1/me", { key: member.accessKey }), 401, "unauthorized");
    expectError(await call("POST", "/v1/recover", { body: { recoveryCode: member.recoveryCode } }), 404, "invalid_code");

    const me = await call("GET", "/v1/me", { key: res.body.accessKey });
    expect(me.status).toBe(200);
    expect(me.body.trainer.trainerId).toBe(member.trainerId);
  });

  it("works for the host and keeps the host role", async () => {
    const { host } = await setupGroup(0);
    const recovered = await recoverAccount(host);
    const me = await call("GET", "/v1/me", { key: recovered.accessKey });
    expect(me.body.trainer.role).toBe("host");
  });

  it("ignores case, hyphens and spaces in the recovery code", async () => {
    const { members } = await setupGroup(1);
    const typed = members[0]!.recoveryCode.toLowerCase().replaceAll("-", " ");
    const res = await call("POST", "/v1/recover", { body: { recoveryCode: typed } });
    expect(res.status, res.text).toBe(200);
  });

  it("rejects unknown and malformed codes with invalid_code", async () => {
    expectError(await call("POST", "/v1/recover", { body: { recoveryCode: "ZZZZ-ZZZZ-ZZZZ-ZZZZ" } }), 404, "invalid_code");
    expectError(await call("POST", "/v1/recover", { body: { recoveryCode: "short" } }), 404, "invalid_code");
  });

  it("rejects the code of an account that left with account_left", async () => {
    const { members } = await setupGroup(1);
    const member = members[0]!;
    expect((await call("POST", "/v1/leave", { key: member.accessKey })).status).toBe(200);
    expectError(await call("POST", "/v1/recover", { body: { recoveryCode: member.recoveryCode } }), 403, "account_left");
  });

  it("rejects the code of a removed account with account_left", async () => {
    const { host, members } = await setupGroup(1);
    const member = members[0]!;
    const removed = await call("POST", "/v1/members/remove", { key: host.accessKey, body: { trainerId: member.trainerId } });
    expect(removed.status, removed.text).toBe(200);
    expectError(await call("POST", "/v1/recover", { body: { recoveryCode: member.recoveryCode } }), 403, "account_left");
  });

  it("requires recoveryCode", async () => {
    expectError(await call("POST", "/v1/recover", { body: {} }), 400, "bad_request");
  });
});
