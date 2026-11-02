import { evictDurableObject, runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { action, getBattle } from "../battle-fixture";
import { DAY, call, dumpTables, expectError, freshEmail, freshIp, joinRaw, leagueStub, setClock, useRealClockAfterEach } from "../helpers";
import { closeSocketsAfterAll, connect } from "./socket";
import { release, running } from "./battle-session";
closeSocketsAfterAll(); useRealClockAfterEach();
describe("lockstep relay", () => {
  it("opens round1 and never exposes the first choice or submission signal to its opponent", async () => {
    const f = await running(); const id = f.view.battleId;
    expect(f.view.roundSeq).toBe(1); expect(f.view.deadline).toBe(f.view.startedAt + 30000);
    const before = (await getBattle(f.p2, id)).body;
    const one = await action(f.p1, id, "choices", { roundSeq: 1, choice: "move 3" }); expect(one.status).toBe(200); expect(one.body.ownChoice).toBe("move 3");
    expect((await getBattle(f.p2, id)).body).toEqual(before); await f.a.socket.sync(); await f.b.socket.sync();
    const retry = await action(f.p1, id, "choices", { roundSeq: 1, choice: "move 3" }); expect(retry.body).toEqual(one.body);
    expectError(await action(f.p1, id, "choices", { roundSeq: 1, choice: "move 2" }), 409, "choice_conflict");
    const two = await action(f.p2, id, "choices", { roundSeq: 1, choice: "move 2" }); expect(two.status).toBe(200);
    expect(two.body.journal).toEqual([{ roundSeq: 1, p1: { kind: "move", slot: 3 }, p2: { kind: "move", slot: 2 }, releasedAt: expect.any(Number) }]);
    for (const socket of [f.a.socket, f.b.socket]) expect((await socket.until(m => m.type === "battle_round")).pair).toEqual(two.body.journal[0]);
    const view = (await getBattle(f.p1, id)).body; expect(view.ownChoice).toBeNull();
    expect((await action(f.p1, id, "choices", { roundSeq: 1, choice: "move 3" })).body.journal).toHaveLength(1);
  });
  it("restores private own choice, config and journal after hibernation and reconnect", async () => {
    const f = await running(); const id = f.view.battleId;
    expect((await action(f.p1, id, "choices", { roundSeq: 1, choice: "move 4" })).status).toBe(200);
    await evictDurableObject(leagueStub(), { webSockets: "hibernate" });
    await connect(f.p2.accessKey);
    const peer = await getBattle(f.p2, id); expect(peer.body.ownChoice).toBeNull(); expect(peer.body.journal).toEqual([]); expect(peer.body.config).toEqual(f.view.config);
    expect((await getBattle(f.p1, id)).body.ownChoice).toBe("move 4");
    expect((await action(f.p2, id, "choices", { roundSeq: 1, choice: "move 1" })).body.journal).toHaveLength(1);
  });
  it("accepts just before 30s and records timeout exactly at deadline without a running alarm", async () => {
    const f = await running(); const id = f.view.battleId; expect(f.view.roundSeq).toBe(1);
    await setClock(f.view.deadline - 1);
    expect((await action(f.p1, id, "choices", { roundSeq: 1, choice: "move 4" })).status).toBe(200);
    await setClock(f.view.deadline);
    expectError(await action(f.p2, id, "choices", { roundSeq: 1, choice: "move 2" }), 409, "stale_round");
    const after = (await getBattle(f.p2, id)).body;
    expect(after.journal[0]).toEqual({ roundSeq: 1, p1: { kind: "move", slot: 4 }, p2: { kind: "timeout" }, releasedAt: f.view.deadline });
    expect(after.roundSeq).toBe(1); expect(after.deadline).toBeNull();
  });
  it("releases two timeouts once and waits for advance without generating idle rounds", async () => {
    const f = await running(); await setClock(f.view.deadline);
    expect(await runDurableObjectAlarm(leagueStub())).toBe(true);
    const view = (await getBattle(f.p1, f.view.battleId)).body;
    expect(view.journal).toHaveLength(1); expect(view.journal[0].p1).toEqual({ kind: "timeout" }); expect(view.journal[0].p2).toEqual({ kind: "timeout" });
    await runInDurableObject(leagueStub(), i => i.alarm());
    expect((await getBattle(f.p1, f.view.battleId)).body.journal).toHaveLength(1);
    const next = await action(f.p1, f.view.battleId, "advance", { processedRoundSeq: 1 }); expect(next.status).toBe(200); expect(next.body.roundSeq).toBe(2);
    expect((await action(f.p2, f.view.battleId, "advance", { processedRoundSeq: 1 })).body.roundSeq).toBe(2);
  });
  it("auto releases closed policy tokens and rejects client choices", async () => {
    const f = await running("auto"); const id = f.view.battleId;
    expect(f.view.journal).toHaveLength(1); expect(f.view.journal[0].p1).toEqual({ kind: "policy" }); expect(f.view.journal[0].p2).toEqual({ kind: "policy" });
    expectError(await action(f.p1, id, "choices", { roundSeq: 1, choice: "move 1" }), 409, "invalid_state");
    const next = await action(f.p2, id, "advance", { processedRoundSeq: 1 }); expect(next.status).toBe(200); expect(next.body.journal).toHaveLength(2);
    expect((await action(f.p1, id, "advance", { processedRoundSeq: 1 })).body.journal).toHaveLength(2);
  });
  it("rejects malicious choices and premature or future advancement on a running room", async () => {
    const f = await running(); const id = f.view.battleId;
    for (const choice of ["auto", "team 1", ">eval 1", "move 1\n>eval 1", "move 0", "move 5", " move 1", { kind: "timeout" }]) expectError(await action(f.p1, id, "choices", { roundSeq: 1, choice }), 400, "invalid_choice");
    expectError(await action(f.p1, id, "advance", { processedRoundSeq: 1 }), 409, "stale_round");
    expectError(await action(f.p1, id, "choices", { roundSeq: 2, choice: "move 1" }), 409, "stale_round");
    expectError(await action(f.third, id, "choices", { roundSeq: 1, choice: "move 1" }), 404, "not_found");
    expect((await getBattle(f.p1, id)).body.journal).toEqual([]);
  });
  it("stops advancing after 200 and preserves ordered immutable replay", async () => {
    const f = await running("auto"); const id = f.view.battleId;
    for (let seq = 1; seq < 200; seq++) { const next = await action(f.p1, id, "advance", { processedRoundSeq: seq }); expect(next.status).toBe(200); }
    expectError(await action(f.p1, id, "advance", { processedRoundSeq: 200 }), 409, "invalid_state");
    const final = (await getBattle(f.p2, id)).body; expect(final.journal).toHaveLength(200); expect(final.journal.map((r: any) => r.roundSeq)).toEqual(Array.from({ length: 200 }, (_, i) => i + 1));
    expect(final.config).toEqual(f.view.config);
  });
  it("shares its alarm with attempt cleanup and expires zero reports after 72h", async () => {
    const f = await running(); const t = f.view.startedAt;
    expectError(await joinRaw("ZZZZ-ZZZZ-ZZZZ", freshEmail(), freshIp()), 404, "invalid_invite");
    const alarm = () => runInDurableObject(leagueStub(), (_i, state) => state.storage.getAlarm());
    expect(await alarm()).toBe(f.view.deadline);
    await setClock(t + DAY + 2000); expect(await runDurableObjectAlarm(leagueStub())).toBe(true);
    expect((await dumpTables()).attempts).toEqual([]); expect((await getBattle(f.p1, f.view.battleId)).body.journal).toHaveLength(1);
    await setClock(t + 3 * DAY); expectError(await action(f.p1, f.view.battleId, "advance", { processedRoundSeq: 1 }), 409, "invalid_state");
    const final = (await getBattle(f.p1, f.view.battleId)).body; expect(final.state).toBe("VOID"); expect(final.reason).toBe("report_timeout");
    expect((await dumpTables()).battle_locks!.filter(r => r.battle_id === f.view.battleId)).toEqual([]);
  });
});
