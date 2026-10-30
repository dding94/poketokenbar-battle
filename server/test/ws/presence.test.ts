import { runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import type { League } from "../../src/league";
import { call, issueInvite, join, leagueStub, setupGroup } from "../helpers";
import { closeSocketsAfterAll, connect, groupChanged, presence, socketFor } from "./socket";

closeSocketsAfterAll();

async function onlineMap(key: string): Promise<Record<string, boolean>> {
  const res = await call("GET", "/v1/group", { key });
  expect(res.status, res.text).toBe(200);
  return Object.fromEntries(res.body.members.map((m: { trainerId: string; online: boolean }) => [m.trainerId, m.online]));
}

describe("presence", () => {
  it("tells group peers when a trainer comes online and goes offline", async () => {
    const { host, members } = await setupGroup(1);
    const b = members[0]!;
    const watcher = await socketFor(host.accessKey);

    const socket = await socketFor(b.accessKey);
    expect(await watcher.next()).toEqual(presence(b.trainerId, true));
    socket.close();
    expect(await watcher.next()).toEqual(presence(b.trainerId, false));
    await watcher.sync();

    // The trainer never hears about itself.
    await socket.closed();
    expect(socket.messages.map((m) => m.type)).toEqual(["hello"]);
  });

  it("adds online to every member in GET /v1/group", async () => {
    const { host, members } = await setupGroup(2);
    const [b, c] = [members[0]!, members[1]!];
    expect(await onlineMap(host.accessKey)).toEqual({ [host.trainerId]: false, [b.trainerId]: false, [c.trainerId]: false });

    const socket = await socketFor(b.accessKey);
    expect(await onlineMap(host.accessKey)).toEqual({ [host.trainerId]: false, [b.trainerId]: true, [c.trainerId]: false });

    const res = await call("GET", "/v1/group", { key: host.accessKey });
    for (const member of res.body.members) expect(typeof member.online).toBe("boolean");

    socket.close();
    await socket.closed();
    const watcher = await socketFor(host.accessKey);
    await watcher.sync();
    expect(await onlineMap(host.accessKey)).toEqual({ [host.trainerId]: true, [b.trainerId]: false, [c.trainerId]: false });
  });

  it("drops a socket from presence as soon as the server closes it", async () => {
    const { host, members } = await setupGroup(1);
    const b = members[0]!;
    const watcher = await socketFor(host.accessKey);
    const socket = await socketFor(b.accessKey);
    expect(await watcher.next()).toEqual(presence(b.trainerId, true));

    socket.ws.send("not a ping");
    expect(await watcher.next()).toEqual(presence(b.trainerId, false));
    expect((await socket.closed()).code).toBe(4400);
    expect((await onlineMap(host.accessKey))[b.trainerId]).toBe(false);
    await watcher.sync();
  });

  it("treats a socket error like a close", async () => {
    const { host, members } = await setupGroup(1);
    const b = members[0]!;
    const watcher = await socketFor(host.accessKey);
    await socketFor(b.accessKey);
    expect(await watcher.next()).toEqual(presence(b.trainerId, true));

    await runInDurableObject(leagueStub(), (instance: League, state: DurableObjectState) => {
      const ws = state.getWebSockets().find((s) => (s.deserializeAttachment() as { trainerId?: string }).trainerId === b.trainerId);
      expect(ws).toBeDefined();
      instance.webSocketError?.(ws!, new Error("test error"));
    });
    expect(await watcher.next()).toEqual(presence(b.trainerId, false));
    expect((await onlineMap(host.accessKey))[b.trainerId]).toBe(false);
    await watcher.sync();
  });
});

describe("latest connection wins", () => {
  it("closes the older socket with 4001 replaced and sends no presence", async () => {
    const { host, members } = await setupGroup(2);
    const [b, c] = [members[0]!, members[1]!];
    const watcher = await socketFor(host.accessKey);
    const older = await socketFor(b.accessKey);
    expect(await watcher.next()).toEqual(presence(b.trainerId, true));

    const newer = await connect(b.accessKey);
    expect(await older.closed()).toEqual({ code: 4001, reason: "replaced" });
    expect([...(newer.hello.online as string[])].sort()).toEqual([host.trainerId, b.trainerId].sort());
    expect((await onlineMap(host.accessKey))[b.trainerId]).toBe(true);

    // The watcher's next message is about someone else: no offline/online flap for b.
    await socketFor(c.accessKey);
    expect(await watcher.next()).toEqual(presence(c.trainerId, true));

    newer.socket.close();
    expect(await watcher.next()).toEqual(presence(b.trainerId, false));
    await watcher.sync();
  });

  it("keeps one open socket after several quick reconnects", async () => {
    const { host, members } = await setupGroup(1);
    const b = members[0]!;
    const watcher = await socketFor(host.accessKey);
    const sockets = [];
    for (let i = 0; i < 4; i += 1) sockets.push(await socketFor(b.accessKey));
    for (const old of sockets.slice(0, -1)) expect((await old.closed()).code).toBe(4001);
    expect(await watcher.next()).toEqual(presence(b.trainerId, true));
    await watcher.sync();
    sockets.at(-1)!.close();
    expect(await watcher.next()).toEqual(presence(b.trainerId, false));
  });
});

describe("group boundary", () => {
  it("never sends one group's events to another group", async () => {
    const one = await setupGroup(1);
    const two = await setupGroup(1);
    const outsider = await socketFor(two.host.accessKey);

    // Presence, replacement, rejection and group changes in group one.
    const watcher = await socketFor(one.host.accessKey);
    const b = await socketFor(one.members[0]!.accessKey);
    await socketFor(one.members[0]!.accessKey);
    expect((await b.closed()).code).toBe(4001);
    const newcomer = await join((await issueInvite(one.host.accessKey)).inviteCode);
    await socketFor(newcomer.accessKey);
    expect(await watcher.next()).toEqual(presence(one.members[0]!.trainerId, true));
    expect(await watcher.next()).toEqual(groupChanged("join"));
    expect(await watcher.next()).toEqual(presence(newcomer.trainerId, true));

    // The outsider's first message is its own group's event.
    await socketFor(two.members[0]!.accessKey);
    expect(await outsider.next()).toEqual(presence(two.members[0]!.trainerId, true));
    await outsider.sync();
    expect(outsider.messages.map((m) => m.type)).toEqual(["hello", "presence"]);
  });

  it("lists only the caller's group in hello", async () => {
    const one = await setupGroup(1);
    const two = await setupGroup(0);
    await socketFor(one.members[0]!.accessKey);
    const { hello } = await connect(two.host.accessKey);
    expect(hello.online).toEqual([two.host.trainerId]);
  });
});
