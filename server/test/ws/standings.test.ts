import { runInDurableObject } from "cloudflare:test";
import { expect, it } from "vitest";
import { action, getBattle, versions } from "../battle-fixture";
import { call, createGroup, dumpTables, leagueStub, setClock, useRealClockAfterEach } from "../helpers";
import { release, running } from "./battle-session";
import { closeSocketsAfterAll, connect } from "./socket";
closeSocketsAfterAll();
useRealClockAfterEach();
const counter = async () => (await dumpTables()).meta!.find((r) => r.key === "battle_completion_sequence")?.value;
it("commits standings and monotonic order once, broadcasts only its group, and rolls back everything on failure", async () => {
  const f = await running();
  await setClock(f.view.startedAt);
  const view = await release(f),
    id = view.battleId;
  const watcher = await connect(f.third.accessKey),
    outsider = await connect((await createGroup()).accessKey);
  const report = {
    readyToken: view.config.readyToken,
    engineHash: versions.engineHash,
    terminalSeq: view.roundSeq,
    winner: "p1",
    logHash: "c".repeat(64),
    journalHash: "d".repeat(64),
    finalHp: { p1: 50, p2: 0 },
  };
  const before = await counter();
  await action(f.p1, id, "report", report);
  await watcher.socket.sync();
  expect(await counter()).toBe(before);
  await runInDurableObject(leagueStub(), (_i, state) =>
    state.storage.sql.exec(
      "CREATE TRIGGER fail_standings BEFORE DELETE ON battle_locks BEGIN SELECT RAISE(ABORT, 'test_fault'); END",
    ),
  );
  try {
    expect((await action(f.p2, id, "report", report)).status).toBe(500);
  } finally {
    await runInDurableObject(leagueStub(), (_i, state) => state.storage.sql.exec("DROP TRIGGER fail_standings"));
  }
  expect(await counter()).toBe(before);
  await watcher.socket.sync();
  expect((await getBattle(f.p1, id)).body.state).toBe("REPORTED");
  expect((await dumpTables()).battle_locks!.filter((r) => r.battle_id === id)).toHaveLength(2);
  expect((await action(f.p2, id, "report", report)).body.state).toBe("COMPLETED");
  expect(await watcher.socket.next()).toEqual({ v: 1, type: "standings_changed" });
  await watcher.socket.sync();
  await outsider.socket.sync();
  expect(Number(await counter())).toBe(Number(before) + 1);
  const records = (await dumpTables()).battle_records!;
  expect(records.find((r) => r.trainer_id === f.p1.trainerId)?.streak_reached_order).toBe(Number(before) + 1);
  expect(records.find((r) => r.trainer_id === f.p2.trainerId)?.streak_reached_order).toBeNull();
  for (const p of [f.p1, f.p2]) expect((await action(p, id, "report", report)).status).toBe(200);
  expect(Number(await counter())).toBe(Number(before) + 1);
  await watcher.socket.sync();
  expect((await call("GET", "/v1/standings", { key: f.third.accessKey })).body.championTrainerId).toBe(f.p1.trainerId);
});
it("does not allocate completion order or announce standings for VOID", async () => {
  const f = await running(),
    view = await release(f),
    watcher = await connect(f.third.accessKey),
    before = await counter();
  const report = {
    readyToken: view.config.readyToken,
    engineHash: versions.engineHash,
    terminalSeq: view.roundSeq,
    winner: "draw",
    logHash: "c".repeat(64),
    journalHash: "d".repeat(64),
    finalHp: { p1: 10, p2: 10 },
  };
  await action(f.p1, view.battleId, "report", report);
  expect((await action(f.p2, view.battleId, "report", { ...report, logHash: "e".repeat(64) })).body.state).toBe("VOID");
  expect((await watcher.socket.next()).type).toBe("battle_void");
  await watcher.socket.sync();
  expect(await counter()).toBe(before);
});
