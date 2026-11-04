import { evictDurableObject, runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { expect, it } from "vitest";
import { closeSocketsAfterAll } from "./socket";
import { measured, packedSession } from "./packed-session";
closeSocketsAfterAll();
it("persists each manual input once without changing lifecycle index or exposing the first choice", async () => {
  const f = await packedSession(), before = await f.get(1);
  const first = await measured(f, () => f.action(0, "choices", { roundSeq: 1, choice: "move 3" }));
  expect(await f.get(1)).toEqual(before); await f.sockets[1]!.socket.sync();
  const second = await measured(f, () => f.action(1, "choices", { roundSeq: 1, choice: "move 2" }));
  const next = await measured(f, () => f.action(0, "advance", { processedRoundSeq: 1 }));
  const duplicate = await measured(f, () => f.action(1, "advance", { processedRoundSeq: 1 }));
  expect(first.writes).toBe(1); expect(second.writes).toBe(1); expect(next.writes).toBe(1); expect(duplicate.writes).toBe(0);
  const deadline = await runInDurableObject(f.stub, (_i, s) => s.storage.sql.exec("SELECT deadline FROM battle_rooms").one().deadline);
  expect(deadline).toBe(f.view.startedAt + 72 * 3600_000);
  expect(second.value.journal[0]).toMatchObject({ p1: { kind: "move", slot: 3 }, p2: { kind: "move", slot: 2 } });
});
it("reads a 200-round wire journal in a bounded number of SQL rows", async () => {
  const f = await packedSession("auto"); let view = f.view;
  for (let seq = 1; seq < 200; seq++) view = await f.action(0, "advance", { processedRoundSeq: seq });
  const read = await measured(f, () => f.get(1));
  expect(read.value.journal).toEqual(view.journal); expect(read.value.journal).toHaveLength(200);
  expect(read.reads).toBeLessThanOrEqual(20); expect(read.writes).toBe(0);
  expect(Object.keys(read.value)).not.toContain("relay");
});
it("keeps an earlier alarm and rearms without SQL writes, then enforces the exact next deadline", async () => {
  const f = await packedSession(), firstDeadline = f.view.deadline;
  await f.clock(firstDeadline - 1000);
  await f.action(0, "choices", { roundSeq: 1, choice: "move 1" });
  await f.action(1, "choices", { roundSeq: 1, choice: "move 2" });
  const next = await f.action(0, "advance", { processedRoundSeq: 1 });
  expect(await f.alarm()).toBe(firstDeadline);
  await f.clock(firstDeadline);
  const early = await measured(f, () => runDurableObjectAlarm(f.stub));
  expect(early.value).toBe(true); expect(early.writes).toBe(0);
  expect((await f.get()).journal).toHaveLength(1); expect(await f.alarm()).toBe(next.deadline);
  await f.clock(next.deadline);
  const late = await f.request("POST", `${f.path}/choices`, f.players[0].accessKey, { roundSeq: 2, choice: "move 1" });
  expect(late.status).toBe(409);
  expect((await f.get()).journal[1]).toEqual({ roundSeq: 2, p1: { kind: "timeout" }, p2: { kind: "timeout" }, releasedAt: next.deadline });
});
it("reconstructs scheduling and private pending choices after hibernation without SQL alarm metadata", async () => {
  const f = await packedSession();
  await f.action(0, "choices", { roundSeq: 1, choice: "move 4" });
  const before = await f.get(); const alarm = await f.alarm();
  await evictDurableObject(f.stub, { webSockets: "hibernate" });
  expect(await f.get()).toEqual(before); expect(await f.alarm()).toBe(alarm);
  const metadata = await runInDurableObject(f.stub, (_i, state) => state.storage.sql.exec("SELECT value FROM meta WHERE key='attempts_alarm_at'").toArray());
  expect(metadata).toEqual([]); expect((await f.get(1)).ownChoice).toBeNull();
});
it("preserves a private current round on VOID and accepts old published move retries", async () => {
  const f = await packedSession();
  await f.action(0, "choices", { roundSeq: 1, choice: "move 3" }); await f.action(1, "choices", { roundSeq: 1, choice: "move 2" });
  await f.action(0, "advance", { processedRoundSeq: 1 }); await f.action(0, "choices", { roundSeq: 2, choice: "move 4" });
  const before = await f.get();
  expect((await f.request("POST", "/v1/leave", f.players[1].accessKey)).status).toBe(200);
  const after = await f.get(); expect(after.state).toBe("VOID"); expect(after.deadline).toBe(before.deadline); expect(after.ownChoice).toBe("move 4");
  expect((await f.action(0, "choices", { roundSeq: 1, choice: "move 3" })).journal).toEqual(before.journal);
});
