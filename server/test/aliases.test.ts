import { describe, expect, it } from "vitest";
import { normalizeCode } from "../src/secrets";
import {
  type ApiResponse,
  call,
  createGroup,
  expectError,
  freshEmail,
  freshIp,
  issueInvite,
  issueReconnect,
  joinRaw,
  setupGroup,
} from "./helpers";

// Typed codes accept Crockford aliases: O reads as 0, I and L read as 1. U stays invalid.

const hasAliasable = (code: string) => /[01]/.test(code);

/** Rewrites every 0 as O and every 1 alternately as I and L, in lowercase. */
function aliased(code: string): string {
  let one = 0;
  return code
    .replace(/[01]/g, (c) => (c === "0" ? "O" : one++ % 2 === 0 ? "I" : "L"))
    .toLowerCase();
}

async function until<T>(make: () => Promise<T>, code: (value: T) => string): Promise<T> {
  for (let i = 0; i < 40; i += 1) {
    const value = await make();
    if (hasAliasable(code(value))) return value;
  }
  throw new Error("no code with 0 or 1 in 40 tries");
}

describe("normalizeCode", () => {
  it("maps O to 0 and I, L to 1 after dropping case, hyphens and spaces", () => {
    expect(normalizeCode("oiLl-0123 abcd", 12)).toBe("0111" + "0123ABCD");
    expect(normalizeCode("o0o0-i1i1-l1l1-OIL0", 16)).toBe("0000111111110110");
  });

  it("still rejects U and other non-Crockford characters", () => {
    expect(normalizeCode("UUUU-0000-0000", 12)).toBeNull();
    expect(normalizeCode("0000-0000-000u", 12)).toBeNull();
    expect(normalizeCode("0000-0000-000!", 12)).toBeNull();
  });
});

describe("typed codes with aliases", () => {
  it("accepts a lowercase, aliased invite code", async () => {
    const host = await createGroup();
    const { inviteCode } = await until(() => issueInvite(host.accessKey), (v) => v.inviteCode);
    const res = await joinRaw(aliased(inviteCode), freshEmail());
    expect(res.status, res.text).toBe(200);
  });

  it("accepts a lowercase, aliased recovery code", async () => {
    const { members } = await setupGroup(1);
    let recoveryCode = members[0]!.recoveryCode;
    for (let i = 0; i < 40 && !hasAliasable(recoveryCode); i += 1) {
      const rotated = await call("POST", "/v1/recover", { body: { recoveryCode } });
      expect(rotated.status, rotated.text).toBe(200);
      recoveryCode = rotated.body.recoveryCode;
    }
    expect(hasAliasable(recoveryCode)).toBe(true);
    const res = await call("POST", "/v1/recover", { body: { recoveryCode: aliased(recoveryCode) } });
    expect(res.status, res.text).toBe(200);
    expect(res.body.trainer.trainerId).toBe(members[0]!.trainerId);
  });

  it("accepts a lowercase, aliased reconnect code", async () => {
    const { host, members } = await setupGroup(1);
    const code = await until(() => issueReconnect(host.accessKey, members[0]!.trainerId), (v) => v);
    const res = await call("POST", "/v1/reconnect", { body: { reconnectCode: aliased(code) } });
    expect(res.status, res.text).toBe(200);
  });
});

describe("codes containing U", () => {
  const cases: Array<[string, (ip: string) => Promise<ApiResponse>, number, string]> = [
    ["invite", (ip) => joinRaw("UUUU-0000-0000", freshEmail(), ip), 404, "invalid_invite"],
    ["recovery", (ip) => call("POST", "/v1/recover", { ip, body: { recoveryCode: "UUUU-0000-0000-0000" } }), 404, "invalid_code"],
    ["reconnect", (ip) => call("POST", "/v1/reconnect", { ip, body: { reconnectCode: "UUUU-0000-0000-0000" } }), 404, "invalid_code"],
  ];

  for (const [kind, request, status, code] of cases) {
    it(`fail as ${code} and count as ${kind} attempts`, async () => {
      const ip = freshIp();
      for (let i = 0; i < 10; i += 1) expectError(await request(ip), status, code);
      expectError(await request(ip), 429, "too_many_attempts");
    });
  }
});
