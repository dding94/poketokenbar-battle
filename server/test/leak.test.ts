import { env } from "cloudflare:workers";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  type ApiResponse,
  call,
  createGroup,
  freshEmail,
  freshIp,
  issueInvite,
  issueReconnect,
  join,
  joinRaw,
  operatorSecret,
  secretForms,
} from "./helpers";

const METHODS = ["log", "info", "warn", "error", "debug", "trace"] as const;

describe("no secret or email reaches logs or error bodies", () => {
  let lines: string[] = [];

  beforeEach(() => {
    lines = [];
    for (const method of METHODS) {
      vi.spyOn(console, method).mockImplementation((...args: unknown[]) => {
        lines.push(args.map((a) => (typeof a === "string" ? a : JSON.stringify(a) ?? String(a))).join(" "));
      });
    }
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("holds across a full scenario", async () => {
    const secrets: string[] = [operatorSecret(), env.CODE_PEPPER ?? "", "operator-wrong-value-xxxxxxxxxxxxxxxxx"];
    const emails: string[] = [];
    const ips: string[] = [];
    const errors: ApiResponse[] = [];
    let requests = 0;

    const track = async (p: Promise<ApiResponse>): Promise<ApiResponse> => {
      requests += 1;
      const res = await p;
      if (res.status >= 400) errors.push(res);
      return res;
    };
    const ip = () => {
      const value = freshIp();
      ips.push(value);
      return value;
    };

    // Host and group.
    const hostEmail = freshEmail("leak-host");
    emails.push(hostEmail);
    requests += 1;
    const host = await createGroup({ email: hostEmail, ip: ip() });
    secrets.push(host.accessKey, host.recoveryCode);

    await track(
      call("POST", "/v1/groups", {
        ip: ip(),
        body: { operatorSecret: "operator-wrong-value-xxxxxxxxxxxxxxxxx", groupName: "G", displayEmail: freshEmail() },
      }),
    );

    requests += 1;
    const invite = await issueInvite(host.accessKey);
    secrets.push(invite.inviteCode);

    const memberEmail = freshEmail("leak-member");
    const leaverEmail = freshEmail("leak-leaver");
    emails.push(memberEmail, leaverEmail);
    requests += 2;
    const member = await join(invite.inviteCode, memberEmail, ip());
    const leaver = await join(invite.inviteCode, leaverEmail, ip());
    secrets.push(member.accessKey, member.recoveryCode, leaver.accessKey, leaver.recoveryCode);

    // Duplicate email and bad codes: these must not be echoed back.
    await track(joinRaw(invite.inviteCode, memberEmail.toUpperCase(), ip()));
    const fakeInvite = "QQQQ-RRRR-SSSS";
    const fakeCode = "WWWW-XXXX-YYYY-ZZZZ";
    secrets.push(fakeInvite, fakeCode);
    await track(joinRaw(fakeInvite, freshEmail(), ip()));
    await track(call("POST", "/v1/recover", { ip: ip(), body: { recoveryCode: fakeCode } }));
    await track(call("POST", "/v1/reconnect", { ip: ip(), body: { reconnectCode: fakeCode } }));
    const badEmail = "not-an-email-leak-check";
    secrets.push(badEmail);
    await track(joinRaw(invite.inviteCode, badEmail, ip()));
    const fakeKey = `ptbk_${"Q".repeat(43)}`;
    secrets.push(fakeKey);
    await track(call("GET", "/v1/me", { key: fakeKey, ip: ip() }));
    await track(call("POST", "/v1/join", { ip: ip(), rawBody: `{"inviteCode":"${fakeInvite}"` }));

    // Recovery, reconnect, leave, remove, transfer.
    const recovered = await track(call("POST", "/v1/recover", { ip: ip(), body: { recoveryCode: member.recoveryCode } }));
    secrets.push(recovered.body.accessKey, recovered.body.recoveryCode);
    requests += 1;
    const reconnectCode = await issueReconnect(host.accessKey, member.trainerId);
    secrets.push(reconnectCode);
    const reconnected = await track(call("POST", "/v1/reconnect", { ip: ip(), body: { reconnectCode } }));
    secrets.push(reconnected.body.accessKey, reconnected.body.recoveryCode);
    await track(call("POST", "/v1/reconnect", { ip: ip(), body: { reconnectCode } }));

    await track(call("POST", "/v1/leave", { key: leaver.accessKey, ip: ip() }));
    await track(call("POST", "/v1/recover", { ip: ip(), body: { recoveryCode: leaver.recoveryCode } }));
    const returnCode = await track(call("POST", "/v1/reconnect-codes", { key: host.accessKey, body: { trainerId: leaver.trainerId } }));
    secrets.push(returnCode.body.reconnectCode);
    const returnEmail = freshEmail("leak-return");
    emails.push(returnEmail);
    const returned = await track(
      call("POST", "/v1/reconnect", { ip: ip(), body: { reconnectCode: returnCode.body.reconnectCode, displayEmail: returnEmail } }),
    );
    secrets.push(returned.body.accessKey, returned.body.recoveryCode);
    await track(call("POST", "/v1/members/remove", { key: host.accessKey, body: { trainerId: leaver.trainerId } }));
    await track(call("POST", "/v1/host/transfer", { key: host.accessKey, body: { trainerId: member.trainerId } }));
    await track(call("GET", "/v1/group", { key: reconnected.body.accessKey }));
    await track(call("GET", "/v1/audit", { key: reconnected.body.accessKey }));
    // Operator host reconnect, right and wrong secret.
    const operatorCode = await track(
      call("POST", "/v1/operator/host-reconnect", { ip: ip(), body: { operatorSecret: operatorSecret(), groupId: host.groupId } }),
    );
    expect(operatorCode.status, operatorCode.text).toBe(200);
    secrets.push(operatorCode.body.reconnectCode);
    await track(
      call("POST", "/v1/operator/host-reconnect", {
        ip: ip(),
        body: { operatorSecret: "operator-wrong-value-xxxxxxxxxxxxxxxxx", groupId: host.groupId },
      }),
    );
    const operatorReturn = await track(call("POST", "/v1/reconnect", { ip: ip(), body: { reconnectCode: operatorCode.body.reconnectCode } }));
    expect(operatorReturn.status, operatorReturn.text).toBe(200);
    secrets.push(operatorReturn.body.accessKey, operatorReturn.body.recoveryCode);

    await track(call("POST", "/v1/leave", { key: host.accessKey }));

    // The capture works and the Worker logs at most one line per request.
    expect(lines.length).toBeGreaterThan(0);
    expect(lines.length).toBeLessThanOrEqual(requests);
    expect(lines.some((l) => l.includes("/v1/join"))).toBe(true);
    for (const line of lines) expect(line).not.toContain("\n");

    const logText = lines.join("\n");
    const logLower = logText.toLowerCase();
    for (const secret of secrets.filter((s) => s.length > 0)) {
      for (const form of secretForms(secret)) {
        expect(logText.includes(form) || logLower.includes(form.toLowerCase()), "secret in logs").toBe(false);
      }
    }
    for (const email of emails) expect(logLower.includes(email.toLowerCase()), "email in logs").toBe(false);
    for (const value of ips) expect(logText.includes(value), "ip in logs").toBe(false);

    expect(errors.length).toBeGreaterThan(5);
    for (const res of errors) {
      expect(Object.keys(res.body ?? {})).toEqual(["error"]);
      expect(Object.keys(res.body.error)).toEqual(["code"]);
      for (const secret of secrets.filter((s) => s.length > 0)) {
        for (const form of secretForms(secret)) expect(res.text.includes(form), "secret in error body").toBe(false);
      }
      for (const email of emails) expect(res.text.toLowerCase().includes(email.toLowerCase())).toBe(false);
    }
  });
});
