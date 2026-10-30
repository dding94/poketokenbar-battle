import { describe, expect, it } from "vitest";
import { call, createGroup, expectError, freshEmail, issueInvite, join, joinRaw, operatorSecret } from "./helpers";

// Display emails and group names are trimmed, NFKC-normalised, and refused when they hold
// whitespace, control (Cc) or format (Cf) characters such as zero-width or bidi controls.

const ZWSP = "​";
const RLO = "‮";
const BOM = "﻿";
const ZWJ = "‍";
const SOFT_HYPHEN = "­";

/** Full-width form of an ASCII string (NFKC maps it back). */
function fullWidth(ascii: string): string {
  return [...ascii].map((c) => (c >= "!" && c <= "~" ? String.fromCodePoint(c.codePointAt(0)! + 0xfee0) : c)).join("");
}

describe("display email look-alikes", () => {
  async function groupWithMember() {
    const host = await createGroup();
    const { inviteCode } = await issueInvite(host.accessKey);
    const local = `victim${crypto.randomUUID().slice(0, 8)}`;
    const victim = await join(inviteCode, `${local}@example.test`);
    return { host, inviteCode, local, victim };
  }

  for (const [label, insert] of [
    ["ZWSP", ZWSP],
    ["RLO", RLO],
    ["BOM", BOM],
    ["ZWJ", ZWJ],
    ["soft hyphen", SOFT_HYPHEN],
  ] as const) {
    it(`rejects an email containing ${label}`, async () => {
      const { inviteCode, local } = await groupWithMember();
      expectError(await joinRaw(inviteCode, `${local}${insert}@example.test`), 400, "bad_request");
      expectError(await joinRaw(inviteCode, `${local}@example.test${insert}x`), 400, "bad_request");
    });
  }

  it("rejects an RTL-override variant of an existing email", async () => {
    const { inviteCode, local } = await groupWithMember();
    expectError(await joinRaw(inviteCode, `${RLO}${local}@example.test`), 400, "bad_request");
  });

  it("treats a full-width variant of an existing email as taken", async () => {
    const { host, inviteCode, local } = await groupWithMember();
    expectError(await joinRaw(inviteCode, fullWidth(`${local.toUpperCase()}@example.test`)), 409, "display_email_taken");
    const group = await call("GET", "/v1/group", { key: host.accessKey });
    expect(group.body.members).toHaveLength(2);
  });

  it("stores the NFKC form", async () => {
    const host = await createGroup();
    const { inviteCode } = await issueInvite(host.accessKey);
    const ascii = freshEmail("wide");
    const res = await joinRaw(inviteCode, fullWidth(ascii));
    expect(res.status, res.text).toBe(200);
    expect(res.body.trainer.displayEmail).toBe(ascii);
  });
});

describe("group name look-alikes", () => {
  for (const [label, insert] of [
    ["ZWSP", ZWSP],
    ["RLO", RLO],
    ["ZWJ", ZWJ],
  ] as const) {
    it(`rejects a name containing ${label}`, async () => {
      const res = await call("POST", "/v1/groups", {
        body: { operatorSecret: operatorSecret(), groupName: `Team${insert}Rocket`, displayEmail: freshEmail() },
      });
      expectError(res, 400, "bad_request");
    });
  }

  it("stores the NFKC form of the name", async () => {
    const res = await call("POST", "/v1/groups", {
      body: { operatorSecret: operatorSecret(), groupName: fullWidth("Rocket"), displayEmail: freshEmail() },
    });
    expect(res.status, res.text).toBe(200);
    expect(res.body.group.name).toBe("Rocket");
  });
});
