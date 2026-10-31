import { describe, expect, it } from "vitest";
import { createGroup, recoverAccount, leaveGroup, setupGroup } from "../helpers";
import { sha256Hex } from "../../src/secrets";
import { type Refusal, closeSocketsAfterAll, connect, connectRefused, socketFor } from "./socket";

closeSocketsAfterAll();

function expectRefused(res: Refusal, status: number, code: string): void {
  expect(res.upgraded, "no upgrade on refusal").toBe(false);
  expect(res.status).toBe(status);
  expect(res.body).toEqual({ error: { code } });
  expect(res.headers.get("cache-control")).toBe("no-store");
}

describe("GET /v1/connect", () => {
  it("answers a request without an Upgrade header with 426 upgrade_required", async () => {
    const host = await createGroup();
    expectRefused(await connectRefused({ key: host.accessKey, upgrade: null }), 426, "upgrade_required");
    expectRefused(await connectRefused({ upgrade: null }), 426, "upgrade_required");
    expectRefused(await connectRefused({ key: host.accessKey, upgrade: "h2c" }), 426, "upgrade_required");
  });

  it("allows only GET", async () => {
    // workerd delivers any request carrying "Upgrade: websocket" as a GET, so this checks the
    // route table without the header.
    const host = await createGroup();
    for (const method of ["POST", "PUT", "DELETE"]) {
      const res = await connectRefused({ key: host.accessKey, method, upgrade: null });
      expectRefused(res, 405, "method_not_allowed");
      expect(res.headers.get("allow")).toBe("GET");
    }
  });

  it("refuses a missing, malformed or unknown key with 401 and no upgrade", async () => {
    expectRefused(await connectRefused(), 401, "unauthorized");
    expectRefused(await connectRefused({ authorization: "Bearer nope" }), 401, "unauthorized");
    expectRefused(await connectRefused({ authorization: "Basic abc" }), 401, "unauthorized");
    expectRefused(await connectRefused({ key: `ptbk_${"Q".repeat(43)}` }), 401, "unauthorized");
  });

  it("refuses a replaced key and a left account's key", async () => {
    const { members } = await setupGroup(2);
    const [replaced, leaver] = [members[0]!, members[1]!];
    await recoverAccount(replaced);
    expectRefused(await connectRefused({ key: replaced.accessKey }), 401, "unauthorized");
    expect((await leaveGroup(leaver.accessKey)).status).toBe(200);
    expectRefused(await connectRefused({ key: leaver.accessKey }), 401, "unauthorized");
  });

  it("does not trust a client-sent key hash header", async () => {
    // A valid key for A plus B's key hash in the header the Worker uses to tell the League who
    // connects. The Worker must overwrite it: in any case, sent once or repeated.
    const { host: a, members } = await setupGroup(1);
    const b = members[0]!;
    const hashB = await sha256Hex(b.accessKey);
    const smuggled: Array<Array<[string, string]>> = [
      [["X-Ptb-Key-Hash", hashB]],
      [
        ["X-PTB-KEY-HASH", hashB],
        ["x-ptb-key-hash", hashB],
      ],
    ];
    for (const headers of smuggled) {
      const { socket, hello } = await connect({ key: a.accessKey, headers });
      expect(hello.trainerId).toBe(a.trainerId);
      socket.close();
      expect((await socket.closed()).code).toBe(1000);
    }
  });

  it("accepts an active key and sends hello with the group's online trainers", async () => {
    const { host, members } = await setupGroup(1);
    const first = await connect(host.accessKey);
    expect(first.hello).toEqual({ v: 1, type: "hello", trainerId: host.trainerId, groupId: host.groupId, online: [host.trainerId] });

    const second = await connect(members[0]!.accessKey);
    expect(second.hello.trainerId).toBe(members[0]!.trainerId);
    expect(second.hello.groupId).toBe(host.groupId);
    expect([...(second.hello.online as string[])].sort()).toEqual([host.trainerId, members[0]!.trainerId].sort());
  });

  it("accepts the Bearer scheme in any case", async () => {
    const host = await createGroup();
    const { hello } = await connect({ authorization: `bEaReR ${host.accessKey}` });
    expect(hello.trainerId).toBe(host.trainerId);
  });
});

describe("client messages", () => {
  it("answers ping with pong", async () => {
    const host = await createGroup();
    const socket = await socketFor(host.accessKey);
    await socket.sync();
    await socket.sync();
    expect(socket.closeInfo).toBeNull();
  });

  for (const [label, payload] of [
    ["other text", "hello"],
    ["JSON", JSON.stringify({ type: "ping" })],
    ["ping in another case", "PING"],
    ["ping with spaces", " ping"],
    ["binary", new Uint8Array([112, 105, 110, 103])],
  ] as const) {
    it(`closes with 4400 unexpected_message on ${label}`, async () => {
      const host = await createGroup();
      const socket = await socketFor(host.accessKey);
      socket.ws.send(payload);
      expect(await socket.closed()).toEqual({ code: 4400, reason: "unexpected_message" });
    });
  }
});
