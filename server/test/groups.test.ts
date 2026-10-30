import { describe, expect, it } from "vitest";
import { KEY_RE, RECOVERY_RE, call, expectError, freshEmail, freshIp, operatorSecret } from "./helpers";

function createBody(secret: string, email = freshEmail("host")) {
  return { operatorSecret: secret, groupName: "Team Rocket", displayEmail: email };
}

describe("POST /v1/groups", () => {
  it("creates a group whose creator is the active host", async () => {
    const email = freshEmail("host");
    const res = await call("POST", "/v1/groups", { body: createBody(operatorSecret(), email) });
    expect(res.status, res.text).toBe(200);
    expect(res.body.accessKey).toMatch(KEY_RE);
    expect(res.body.recoveryCode).toMatch(RECOVERY_RE);
    expect(res.body.trainer).toMatchObject({ displayEmail: email, role: "host", status: "active" });
    expect(res.body.group).toMatchObject({ name: "Team Rocket", hostTrainerId: res.body.trainer.trainerId });
    expect(typeof res.body.group.groupId).toBe("string");

    const me = await call("GET", "/v1/me", { key: res.body.accessKey });
    expect(me.status).toBe(200);
    expect(me.body.trainer).toMatchObject({ trainerId: res.body.trainer.trainerId, role: "host", status: "active" });
    expect(me.body.group.groupId).toBe(res.body.group.groupId);
  });

  it("issues a different key and recovery code for every group", async () => {
    const a = await call("POST", "/v1/groups", { body: createBody(operatorSecret()) });
    const b = await call("POST", "/v1/groups", { body: createBody(operatorSecret()) });
    expect(a.body.accessKey).not.toBe(b.body.accessKey);
    expect(a.body.recoveryCode).not.toBe(b.body.recoveryCode);
    expect(a.body.group.groupId).not.toBe(b.body.group.groupId);
  });

  it("rejects a wrong secret with operator_denied and counts it as a failed attempt", async () => {
    const ip = freshIp();
    const wrong = `${operatorSecret()}-wrong`;
    for (let i = 0; i < 10; i += 1) {
      expectError(await call("POST", "/v1/groups", { body: createBody(wrong), ip }), 403, "operator_denied");
    }
    // The ten failures exhaust this IP's operator attempts, even for the right secret.
    const blocked = await call("POST", "/v1/groups", { body: createBody(operatorSecret()), ip });
    expectError(blocked, 429, "too_many_attempts");
  });

  it("is operator_disabled when OPERATOR_SECRET is missing", async () => {
    const res = await call("POST", "/v1/groups", {
      body: createBody(operatorSecret()),
      envOverride: { OPERATOR_SECRET: undefined },
    });
    expectError(res, 503, "operator_disabled");
  });

  it("is operator_disabled when OPERATOR_SECRET is shorter than 32 characters, even if it matches", async () => {
    const short = "s".repeat(31);
    const res = await call("POST", "/v1/groups", { body: createBody(short), envOverride: { OPERATOR_SECRET: short } });
    expectError(res, 503, "operator_disabled");
  });

  it("accepts a 32-character OPERATOR_SECRET", async () => {
    const exact = "s".repeat(32);
    const res = await call("POST", "/v1/groups", { body: createBody(exact), envOverride: { OPERATOR_SECRET: exact } });
    expect(res.status, res.text).toBe(200);
  });

  it("rejects a secret of a different length without error", async () => {
    expectError(await call("POST", "/v1/groups", { body: createBody("x") }), 403, "operator_denied");
    expectError(await call("POST", "/v1/groups", { body: createBody("") }), 403, "operator_denied");
  });

  it("requires every field", async () => {
    const full = createBody(operatorSecret());
    for (const field of ["operatorSecret", "groupName", "displayEmail"] as const) {
      const body: Record<string, unknown> = { ...full };
      delete body[field];
      expectError(await call("POST", "/v1/groups", { body }), 400, "bad_request");
    }
    expectError(await call("POST", "/v1/groups", { body: { ...full, operatorSecret: 42 } }), 400, "bad_request");
  });
});
