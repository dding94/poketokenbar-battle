import { env } from "cloudflare:workers";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  freshEmail,
  issueInvite,
  issueReconnect,
  join,
  leaveGroup,
  operatorSecret,
  reconnectWith,
  recoverAccount,
  removeMember,
  secretForms,
  setupGroup,
  transferHost,
} from "../helpers";
import { type Socket, closeSocketsAfterAll, connectRaw, socketFor } from "./socket";

closeSocketsAfterAll();

const METHODS = ["log", "info", "warn", "error", "debug", "trace"] as const;

const ALLOWED_FIELDS: Record<string, string[]> = {
  hello: ["groupId", "online", "trainerId", "type", "v"],
  presence: ["online", "trainerId", "type", "v"],
  group_changed: ["kind", "type", "v"],
};

describe("realtime messages, close reasons and logs", () => {
  let lines: string[] = [];

  beforeEach(() => {
    lines = [];
    for (const method of METHODS) {
      vi.spyOn(console, method).mockImplementation((...args: unknown[]) => {
        lines.push(args.map((a) => (typeof a === "string" ? a : (JSON.stringify(a) ?? String(a)))).join(" "));
      });
    }
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("carry no key, code or email, and log one line per connect", async () => {
    const { host, members, inviteCode } = await setupGroup(3);
    const [b, c, d] = [members[0]!, members[1]!, members[2]!];
    const secrets = [operatorSecret(), env.CODE_PEPPER ?? "", inviteCode];
    const emails = [host.email, b.email, c.email, d.email];
    for (const acc of [host, b, c, d]) secrets.push(acc.accessKey, acc.recoveryCode);

    const sockets: Socket[] = [];
    const open = async (key: string) => {
      const s = await socketFor(key);
      sockets.push(s);
      return s;
    };
    lines = [];
    const watcher = await open(host.accessKey);
    await open(b.accessKey);
    await open(b.accessKey); // replaced
    await open(c.accessKey);
    const dSocket = await open(d.accessKey);
    dSocket.ws.send("unexpected"); // 4400
    const connects = 5;

    const refused = await connectRaw({ key: `ptbk_${"Q".repeat(43)}` });
    expect(refused.status).toBe(401);
    const plain = await connectRaw({ key: host.accessKey, upgrade: null });
    expect(plain.status).toBe(426);

    const newcomerEmail = freshEmail("leak-newcomer");
    emails.push(newcomerEmail);
    const newcomer = await join((await issueInvite(host.accessKey)).inviteCode, newcomerEmail);
    secrets.push(newcomer.accessKey, newcomer.recoveryCode);
    const recovered = await recoverAccount(c);
    secrets.push(recovered.accessKey, recovered.recoveryCode);
    const code = await issueReconnect(host.accessKey, b.trainerId);
    secrets.push(code);
    const back = await reconnectWith(code);
    secrets.push(back.body.accessKey, back.body.recoveryCode);
    await open(back.body.accessKey);
    await leaveGroup(newcomer.accessKey);
    await removeMember(host.accessKey, recovered.trainerId);
    await transferHost(host.accessKey, b.trainerId);
    // host_transfer is the last event, so every earlier message has arrived once it has.
    await watcher.until((m) => m.type === "group_changed" && m.kind === "host_transfer");

    // Every message has only the contract's fields.
    const frames = sockets.flatMap((s) => s.frames.filter((f) => f !== "pong"));
    expect(frames.length).toBeGreaterThan(8);
    for (const message of sockets.flatMap((s) => s.messages)) {
      expect(Object.keys(message).sort()).toEqual(ALLOWED_FIELDS[message.type]);
      expect(message.v).toBe(1);
    }
    const reasons = sockets.map((s) => s.closeInfo?.reason ?? "").filter((r) => r !== "");
    expect(reasons.sort()).toEqual(expect.arrayContaining(["replaced", "revoked", "unexpected_message"]));

    const connectLines = lines.filter((l) => l.includes("/v1/connect"));
    expect(connectLines.map((l) => JSON.parse(l).status).sort()).toEqual([...Array(connects + 1).fill(101), 401, 426].sort());
    for (const line of lines) expect(line).not.toContain("\n");

    const haystacks = [...frames, ...reasons, ...lines];
    for (const text of haystacks) {
      const lower = text.toLowerCase();
      for (const secret of secrets.filter((s) => s.length > 0)) {
        for (const form of secretForms(secret)) expect(lower.includes(form.toLowerCase()), "secret leaked").toBe(false);
      }
      for (const email of emails) expect(lower.includes(email.toLowerCase()), "email leaked").toBe(false);
    }
  });
});
