import { evictDurableObject, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import type { League } from "../../src/league";
import { call, issueInvite, join, leagueStub, setupGroup } from "../helpers";
import { closeSocketsAfterAll, connect, groupChanged, presence, socketFor } from "./socket";

closeSocketsAfterAll();

const MARK = "__ptbTestMark";

/** Evicts the League with its sockets hibernated, and proves the in-memory instance was replaced. */
async function hibernate(): Promise<void> {
  await runInDurableObject(leagueStub(), (instance: League) => {
    (instance as unknown as Record<string, unknown>)[MARK] = true;
  });
  await evictDurableObject(leagueStub(), { webSockets: "hibernate" });
  const marked = await runInDurableObject(leagueStub(), (instance: League) => (instance as unknown as Record<string, unknown>)[MARK]);
  expect(marked, "the League instance survived eviction").toBeUndefined();
}

describe("after hibernation", () => {
  it("keeps presence for hello, GET /v1/group and peers", async () => {
    const { host, members } = await setupGroup(2);
    const [b, c] = [members[0]!, members[1]!];
    const watcher = await socketFor(host.accessKey);
    await socketFor(b.accessKey);
    expect(await watcher.next()).toEqual(presence(b.trainerId, true));

    await hibernate();

    const res = await call("GET", "/v1/group", { key: host.accessKey });
    const online = Object.fromEntries(res.body.members.map((m: { trainerId: string; online: boolean }) => [m.trainerId, m.online]));
    expect(online).toEqual({ [host.trainerId]: true, [b.trainerId]: true, [c.trainerId]: false });

    const third = await connect(c.accessKey);
    expect([...(third.hello.online as string[])].sort()).toEqual([host.trainerId, b.trainerId, c.trainerId].sort());
    expect(await watcher.next()).toEqual(presence(c.trainerId, true));
  });

  it("still answers ping and still refuses other messages", async () => {
    const { host, members } = await setupGroup(1);
    const b = members[0]!;
    const watcher = await socketFor(host.accessKey);
    const socket = await socketFor(b.accessKey);
    expect(await watcher.next()).toEqual(presence(b.trainerId, true));
    await hibernate();

    await socket.sync();
    socket.ws.send("hello");
    expect(await socket.closed()).toEqual({ code: 4400, reason: "unexpected_message" });
    expect(await watcher.next()).toEqual(presence(b.trainerId, false));
  });

  it("reports a client close that arrives while hibernated", async () => {
    const { host, members } = await setupGroup(1);
    const b = members[0]!;
    const watcher = await socketFor(host.accessKey);
    const socket = await socketFor(b.accessKey);
    expect(await watcher.next()).toEqual(presence(b.trainerId, true));
    await hibernate();

    socket.close();
    expect(await watcher.next()).toEqual(presence(b.trainerId, false));
    await watcher.sync();
  });

  it("replaces an older hibernated socket without a presence flap", async () => {
    const { host, members } = await setupGroup(2);
    const [b, c] = [members[0]!, members[1]!];
    const watcher = await socketFor(host.accessKey);
    const older = await socketFor(b.accessKey);
    expect(await watcher.next()).toEqual(presence(b.trainerId, true));
    await hibernate();

    await socketFor(b.accessKey);
    expect((await older.closed()).code).toBe(4001);
    await socketFor(c.accessKey);
    expect(await watcher.next()).toEqual(presence(c.trainerId, true));
  });

  it("revokes and notifies hibernated sockets", async () => {
    const { host, members } = await setupGroup(1);
    const b = members[0]!;
    const watcher = await socketFor(host.accessKey);
    const socket = await socketFor(b.accessKey);
    expect(await watcher.next()).toEqual(presence(b.trainerId, true));
    await hibernate();

    expect((await call("POST", "/v1/leave", { key: b.accessKey })).status).toBe(200);
    expect(await socket.closed()).toEqual({ code: 4003, reason: "revoked" });
    expect(await watcher.next()).toEqual(presence(b.trainerId, false));
    expect(await watcher.next()).toEqual(groupChanged("leave"));

    await hibernate();
    await join((await issueInvite(host.accessKey)).inviteCode);
    expect(await watcher.next()).toEqual(groupChanged("join"));
  });
});
