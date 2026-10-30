import { describe, expect, it } from "vitest";
import {
  DAY,
  MINUTE,
  KEY_RE,
  RECONNECT_RE,
  advanceClock,
  call,
  expectError,
  freshEmail,
  freshIp,
  operatorSecret,
  setupGroup,
  useRealClockAfterEach,
} from "./helpers";

// POST /v1/operator/host-reconnect: the operator recovers a host who lost both key and recovery code.

useRealClockAfterEach();

const WRONG = "operator-wrong-value-xxxxxxxxxxxxxxxxx";

function hostReconnect(groupId: unknown, opts: { secret?: unknown; ip?: string; envOverride?: Partial<Env> } = {}) {
  return call("POST", "/v1/operator/host-reconnect", {
    body: { operatorSecret: opts.secret === undefined ? operatorSecret() : opts.secret, groupId },
    ip: opts.ip,
    envOverride: opts.envOverride,
  });
}

function redeem(reconnectCode: string) {
  return call("POST", "/v1/reconnect", { body: { reconnectCode } });
}

describe("POST /v1/operator/host-reconnect", () => {
  it("issues a code that rotates the host's key and recovery code", async () => {
    const { host } = await setupGroup(1);
    const res = await hostReconnect(host.groupId);
    expect(res.status, res.text).toBe(200);
    expect(res.body.trainerId).toBe(host.trainerId);
    expect(res.body.reconnectCode).toMatch(RECONNECT_RE);
    expect(typeof res.body.expiresAt).toBe("number");

    const back = await redeem(res.body.reconnectCode);
    expect(back.status, back.text).toBe(200);
    expect(back.body.accessKey).toMatch(KEY_RE);
    expect(back.body.trainer).toMatchObject({ trainerId: host.trainerId, role: "host", status: "active" });

    expectError(await call("GET", "/v1/me", { key: host.accessKey }), 401, "unauthorized");
    expectError(await call("POST", "/v1/recover", { body: { recoveryCode: host.recoveryCode } }), 404, "invalid_code");
    expect((await call("GET", "/v1/me", { key: back.body.accessKey })).body.trainer.role).toBe("host");
  });

  it("issues one-time codes that supersede older ones and expire after 24 hours", async () => {
    const { host } = await setupGroup(0);
    const older = (await hostReconnect(host.groupId)).body.reconnectCode;
    const newer = (await hostReconnect(host.groupId)).body.reconnectCode;
    expectError(await redeem(older), 410, "code_expired");
    expect((await redeem(newer)).status).toBe(200);
    expectError(await redeem(newer), 410, "code_used");

    const late = (await hostReconnect(host.groupId)).body.reconnectCode;
    await advanceClock(DAY + MINUTE);
    expectError(await redeem(late), 410, "code_expired");
  });

  it("counts a wrong secret as an operator attempt, then answers 429", async () => {
    const { host } = await setupGroup(0);
    const ip = freshIp();
    for (let i = 0; i < 10; i += 1) {
      expectError(await hostReconnect(host.groupId, { secret: WRONG, ip }), 403, "operator_denied");
    }
    const blocked = await hostReconnect(host.groupId, { ip });
    expectError(blocked, 429, "too_many_attempts");
    expect(Number(blocked.headers.get("retry-after"))).toBeGreaterThan(0);
    // The same operator bucket also blocks group creation from this IP.
    const create = await call("POST", "/v1/groups", {
      ip,
      body: { operatorSecret: operatorSecret(), groupName: "G", displayEmail: freshEmail() },
    });
    expectError(create, 429, "too_many_attempts");
  });

  it("is operator_disabled when the secret is missing or short", async () => {
    const { host } = await setupGroup(0);
    expectError(await hostReconnect(host.groupId, { envOverride: { OPERATOR_SECRET: undefined } }), 503, "operator_disabled");
    const short = "s".repeat(31);
    expectError(await hostReconnect(host.groupId, { secret: short, envOverride: { OPERATOR_SECRET: short } }), 503, "operator_disabled");
  });

  it("is not_found for an unknown group, but only with the right secret", async () => {
    expectError(await hostReconnect("gr_missing"), 404, "not_found");
    expectError(await hostReconnect("gr_missing", { secret: WRONG }), 403, "operator_denied");
  });

  it("requires operatorSecret and groupId", async () => {
    const { host } = await setupGroup(0);
    expectError(await hostReconnect(undefined), 400, "bad_request");
    expectError(await hostReconnect(42), 400, "bad_request");
    const res = await call("POST", "/v1/operator/host-reconnect", { body: { groupId: host.groupId } });
    expectError(res, 400, "bad_request");
  });

  it("targets the current host after a transfer", async () => {
    const { host, members } = await setupGroup(1);
    const heir = members[0]!;
    expect((await call("POST", "/v1/host/transfer", { key: host.accessKey, body: { trainerId: heir.trainerId } })).status).toBe(200);
    const res = await hostReconnect(host.groupId);
    expect(res.body.trainerId).toBe(heir.trainerId);
    const back = await redeem(res.body.reconnectCode);
    expect(back.body.trainer).toMatchObject({ trainerId: heir.trainerId, role: "host" });
    expectError(await call("GET", "/v1/me", { key: heir.accessKey }), 401, "unauthorized");
    expect((await call("GET", "/v1/me", { key: host.accessKey })).status).toBe(200);
  });

  it("leaves an audit entry members can see", async () => {
    const { host, members } = await setupGroup(1);
    const res = await hostReconnect(host.groupId);
    expect(res.status).toBe(200);
    const audit = await call("GET", "/v1/audit", { key: members[0]!.accessKey });
    const entries = audit.body.entries.map((e: any) => [e.kind, e.actorTrainerId, e.targetTrainerId]);
    expect(entries).toContainEqual(["operator_host_reconnect", null, host.trainerId]);
    expect(audit.text).not.toContain(res.body.reconnectCode);
  });

  it("does not answer GET", async () => {
    expectError(await call("GET", "/v1/operator/host-reconnect"), 405, "method_not_allowed");
  });
});
