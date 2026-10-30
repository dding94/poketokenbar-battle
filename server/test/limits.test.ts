import { runDurableObjectAlarm } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import {
  DAY,
  MINUTE,
  type ApiResponse,
  advanceClock,
  call,
  createGroup,
  dumpTables,
  expectError,
  freshEmail,
  freshIp,
  issueInvite,
  issueReconnect,
  joinRaw,
  leagueStub,
  operatorSecret,
  setupGroup,
  useRealClockAfterEach,
} from "./helpers";

useRealClockAfterEach();

type Kind = "operator" | "invite" | "recovery" | "reconnect";

const failing: Record<Kind, { request(ip: string): Promise<ApiResponse>; status: number; code: string }> = {
  operator: {
    request: (ip) =>
      call("POST", "/v1/groups", {
        ip,
        body: { operatorSecret: "operator-wrong-value-xxxxxxxxxxxxxxxxx", groupName: "G", displayEmail: freshEmail() },
      }),
    status: 403,
    code: "operator_denied",
  },
  invite: { request: (ip) => joinRaw("ZZZZ-ZZZZ-ZZZZ", freshEmail(), ip), status: 404, code: "invalid_invite" },
  recovery: {
    request: (ip) => call("POST", "/v1/recover", { ip, body: { recoveryCode: "ZZZZ-ZZZZ-ZZZZ-ZZZZ" } }),
    status: 404,
    code: "invalid_code",
  },
  reconnect: {
    request: (ip) => call("POST", "/v1/reconnect", { ip, body: { reconnectCode: "ZZZZ-ZZZZ-ZZZZ-ZZZZ" } }),
    status: 404,
    code: "invalid_code",
  },
};

async function exhaust(kind: Kind, ip: string): Promise<void> {
  for (let i = 0; i < 10; i += 1) {
    const res = await failing[kind].request(ip);
    expectError(res, failing[kind].status, failing[kind].code);
  }
}

function expectLimited(res: ApiResponse): void {
  expectError(res, 429, "too_many_attempts");
  const retryAfter = Number(res.headers.get("retry-after"));
  expect(Number.isInteger(retryAfter)).toBe(true);
  expect(retryAfter).toBeGreaterThan(0);
  expect(retryAfter).toBeLessThanOrEqual(15 * 60);
}

describe("attempt limits", () => {
  for (const kind of Object.keys(failing) as Kind[]) {
    it(`blocks the 11th ${kind} failure within 15 minutes from one IP`, async () => {
      const ip = freshIp();
      await exhaust(kind, ip);
      expectLimited(await failing[kind].request(ip));
      // Another IP is unaffected.
      expectError(await failing[kind].request(freshIp()), failing[kind].status, failing[kind].code);
    });
  }

  it("keeps kinds separate for the same IP", async () => {
    const ip = freshIp();
    await exhaust("invite", ip);
    expectLimited(await failing.invite.request(ip));
    for (const other of ["operator", "recovery", "reconnect"] as const) {
      const res = await failing[other].request(ip);
      expectError(res, failing[other].status, failing[other].code);
    }
  });

  it("blocks a correct code once the IP is limited, and lets other IPs use it", async () => {
    const host = await createGroup();
    const { inviteCode } = await issueInvite(host.accessKey);
    const ip = freshIp();
    await exhaust("invite", ip);
    expectLimited(await joinRaw(inviteCode, freshEmail(), ip));
    expect((await joinRaw(inviteCode, freshEmail(), freshIp())).status).toBe(200);
  });

  it("reports Retry-After until the oldest failure leaves the window", async () => {
    const ip = freshIp();
    await exhaust("recovery", ip);
    await advanceClock(5 * MINUTE);
    const res = await failing.recovery.request(ip);
    expectLimited(res);
    const retryAfter = Number(res.headers.get("retry-after"));
    expect(retryAfter).toBeGreaterThan(9 * 60);
    expect(retryAfter).toBeLessThanOrEqual(10 * 60);
  });

  it("resets after the 15-minute window passes", async () => {
    const host = await createGroup();
    const { inviteCode } = await issueInvite(host.accessKey);
    const ip = freshIp();
    await exhaust("invite", ip);
    expectLimited(await joinRaw(inviteCode, freshEmail(), ip));
    await advanceClock(15 * MINUTE + 1000);
    const res = await joinRaw(inviteCode, freshEmail(), ip);
    expect(res.status, res.text).toBe(200);
  });

  it("does not count successes", async () => {
    const host = await createGroup();
    const { inviteCode } = await issueInvite(host.accessKey);
    const ip = freshIp();
    for (let i = 0; i < 12; i += 1) {
      expect((await joinRaw(inviteCode, freshEmail(), ip)).status).toBe(200);
    }
    await exhaust("invite", ip);
    expectLimited(await failing.invite.request(ip));
  });

  it("does not count bad_request", async () => {
    const ip = freshIp();
    for (let i = 0; i < 15; i += 1) {
      expectError(await call("POST", "/v1/join", { ip, body: { displayEmail: freshEmail() } }), 400, "bad_request");
      expectError(await call("POST", "/v1/recover", { ip, body: { recoveryCode: 7 } }), 400, "bad_request");
    }
    await exhaust("invite", ip);
    await exhaust("recovery", ip);
  });

  it("counts expired, revoked and used-up invites as failures", async () => {
    const host = await createGroup();
    const { inviteCode, inviteId } = await issueInvite(host.accessKey);
    await call("POST", "/v1/invites/revoke", { key: host.accessKey, body: { inviteId } });
    const ip = freshIp();
    for (let i = 0; i < 10; i += 1) expectError(await joinRaw(inviteCode, freshEmail(), ip), 410, "invite_revoked");
    expectLimited(await joinRaw(inviteCode, freshEmail(), ip));
  });

  it("counts used reconnect codes as failures", async () => {
    const { host, members } = await setupGroup(1);
    const code = await issueReconnect(host.accessKey, members[0]!.trainerId);
    const ip = freshIp();
    expect((await call("POST", "/v1/reconnect", { ip, body: { reconnectCode: code } })).status).toBe(200);
    for (let i = 0; i < 10; i += 1) {
      expectError(await call("POST", "/v1/reconnect", { ip, body: { reconnectCode: code } }), 410, "code_used");
    }
    expectLimited(await call("POST", "/v1/reconnect", { ip, body: { reconnectCode: code } }));
  });

  it("does not count operator_disabled", async () => {
    const ip = freshIp();
    for (let i = 0; i < 12; i += 1) {
      const res = await call("POST", "/v1/groups", {
        ip,
        body: { operatorSecret: operatorSecret(), groupName: "G", displayEmail: freshEmail() },
        envOverride: { OPERATOR_SECRET: undefined },
      });
      expectError(res, 503, "operator_disabled");
    }
    const ok = await call("POST", "/v1/groups", {
      ip,
      body: { operatorSecret: operatorSecret(), groupName: "G", displayEmail: freshEmail() },
    });
    expect(ok.status, ok.text).toBe(200);
  });

  it("deletes attempt records a day later", async () => {
    await exhaust("invite", freshIp());
    expect((await dumpTables()).attempts?.length ?? 0).toBeGreaterThan(0);
    await advanceClock(DAY + 60 * MINUTE);
    expect(await runDurableObjectAlarm(leagueStub())).toBe(true);
    expect((await dumpTables()).attempts).toEqual([]);
  });
});
