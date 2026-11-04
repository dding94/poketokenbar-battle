import { runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { action, createBattle, getBattle, snapshot, versions } from "../battle-fixture";
import { DAY, call, dumpTables, expectError, leagueStub, recoverAccount, setClock, useRealClockAfterEach } from "../helpers";
import { closeSocketsAfterAll, connect } from "./socket";
import { release, running } from "./battle-session";
closeSocketsAfterAll(); useRealClockAfterEach();
export const reportFor = (view: any, overrides = {}) => ({ readyToken: view.config.readyToken, engineHash: versions.engineHash, terminalSeq: view.roundSeq, winner: "p1", logHash: "c".repeat(64), journalHash: "d".repeat(64), finalHp: { p1: 50, p2: 0 }, ...overrides });
async function terminal() { const f = await running(); const view = await release(f); return { ...f, view }; }
async function locks(id: string) { return (await dumpTables()).battle_locks!.filter(r => r.battle_id === id); }
async function records(id: string) { return (await dumpTables()).battle_records!.find(r => r.trainer_id === id); }
describe("result comparison and atomic records", () => {
  it("keeps first report private and commits matching results exactly once with both locks", async () => {
    const f = await terminal(); const id = f.view.battleId; const body = reportFor(f.view);
    expect(await locks(id)).toHaveLength(2);
    const one = await action(f.p1, id, "report", body); expect(one.status, one.text).toBe(200); expect(one.body.state).toBe("REPORTED"); expect(one.body.result).toBeNull();
    expect((await getBattle(f.p2, id)).text).not.toContain(body.logHash); expect(await records(f.p1.trainerId)).toBeUndefined();
    expectError(await action(f.p2, id, "advance", { processedRoundSeq: 1 }), 409, "invalid_state");
    const done = await action(f.p2, id, "report", body); expect(done.status).toBe(200); expect(done.body.state).toBe("COMPLETED"); expect(done.body.result).toEqual(body);
    expect(await locks(id)).toEqual([]);
    expect(await records(f.p1.trainerId)).toMatchObject({ wins: 1, losses: 0, draws: 0, streak: 1, best_streak: 1 });
    expect(await records(f.p2.trainerId)).toMatchObject({ wins: 0, losses: 1, draws: 0, streak: 0, best_streak: 0 });
    for (const who of [f.p1, f.p2]) expect((await action(who, id, "report", body)).body).toEqual(done.body);
    expect(await records(f.p1.trainerId)).toMatchObject({ wins: 1, streak: 1 });
    expectError(await action(f.p1, id, "report", { ...body, logHash: "e".repeat(64) }), 409, "report_conflict");
  });
  it.each(["terminalSeq", "winner", "logHash", "journalHash", "finalHp"])("VOID for two valid reports differing in %s, without touching records", async field => {
    const f = await terminal(); const id = f.view.battleId; const watcher = await connect(f.third.accessKey);
    const body = reportFor(f.view);
    const changes: Record<string, object> = { terminalSeq: { terminalSeq: 2 }, winner: { winner: "draw" }, logHash: { logHash: "e".repeat(64) }, journalHash: { journalHash: "e".repeat(64) }, finalHp: { finalHp: { p1: 49, p2: 0 } } };
    expect((await action(f.p1, id, "report", body)).status).toBe(200);
    const other = await action(f.p2, id, "report", { ...body, ...changes[field] }); expect(other.status).toBe(200); expect(other.body).toMatchObject({ state: "VOID", reason: "result_mismatch", result: null });
    expect(await watcher.socket.next()).toEqual({ v: 1, type: "battle_void", battleId: id, reason: "result_mismatch" }); await watcher.socket.sync();
    expect(await records(f.p1.trainerId)).toBeUndefined(); expect(await locks(id)).toEqual([]);
  });
  it("rejects foreign config before comparing an opponent report or existing retry", async () => {
    const f = await terminal(); const id = f.view.battleId; const body = reportFor(f.view);
    expect((await action(f.p1, id, "report", body)).body.state).toBe("REPORTED");
    for (const who of [f.p1, f.p2]) {
      expectError(await action(who, id, "report", { ...body, readyToken: "wrong" }), 409, "not_ready");
      expectError(await action(who, id, "report", { ...body, engineHash: "b".repeat(64) }), 409, "engine_mismatch");
    }
    expect((await getBattle(f.p1, id)).body.state).toBe("REPORTED"); expect(await locks(id)).toHaveLength(2);
    expect((await action(f.p2, id, "report", body)).body.state).toBe("COMPLETED");
  });
  it("rejects unprocessed rounds and impossible finalHP before storing a first report", async () => {
    const f = await running(); const id = f.view.battleId; const body = reportFor(f.view);
    expectError(await action(f.p1, id, "report", body), 409, "stale_round");
    await release(f);
    expectError(await action(f.p1, id, "report", { ...body, finalHp: { p1: 111, p2: 0 } }), 400, "bad_request");
    expectError(await action(f.p1, id, "report", { ...body, finalHp: { p1: 50, p2: 1 } }), 400, "bad_request");
    expectError(await action(f.p1, id, "report", { ...body, terminalSeq: 2 }), 409, "stale_round");
    expect((await action(f.p2, id, "advance", { processedRoundSeq: 1 })).status).toBe(200);
    expectError(await action(f.p1, id, "report", body), 409, "stale_round");
    expect((await getBattle(f.p1, id)).body.state).toBe("RUNNING");
  });
  it("uses 72h from first report and rejects a delayed opponent report exactly at its deadline", async () => {
    const f = await terminal(); const id = f.view.battleId; const body = reportFor(f.view); const firstAt = f.view.startedAt + 3 * DAY - 1;
    await setClock(firstAt); expect((await action(f.p1, id, "report", body)).body.state).toBe("REPORTED");
    await setClock(firstAt + 3 * DAY - 1); expect((await getBattle(f.p2, id)).body.state).toBe("REPORTED");
    await setClock(firstAt + 3 * DAY); expectError(await action(f.p2, id, "report", body), 409, "invalid_state");
    expect((await getBattle(f.p1, id)).body).toMatchObject({ state: "VOID", reason: "report_timeout" }); expect(await records(f.p1.trainerId)).toBeUndefined(); expect(await locks(id)).toEqual([]);
  });
  it("rolls back result, second report, records and BOTH locks on an injected final write failure", async () => {
    const f = await terminal(); const id = f.view.battleId; const body = reportFor(f.view);
    expect((await action(f.p1, id, "report", body)).status).toBe(200);
    await runInDurableObject(leagueStub(), (_i, state) => state.storage.sql.exec("CREATE TRIGGER fail_battle_unlock BEFORE DELETE ON battle_locks BEGIN SELECT RAISE(ABORT, 'test_fault'); END"));
    try { expectError(await action(f.p2, id, "report", body), 500, "internal"); }
    finally { await runInDurableObject(leagueStub(), (_i, state) => state.storage.sql.exec("DROP TRIGGER fail_battle_unlock")); }
    expect((await getBattle(f.p1, id)).body.state).toBe("REPORTED"); expect(await records(f.p1.trainerId)).toBeUndefined(); expect(await locks(id)).toHaveLength(2);
    expect((await dumpTables()).battle_reports!.filter(r => r.battle_id === id)).toHaveLength(1);
    expect((await action(f.p2, id, "report", body)).body.state).toBe("COMPLETED"); expect(await locks(id)).toEqual([]);
  });
  it("creates rematches with fresh snapshots and preserves win/best streak through a draw", async () => {
    const f = await terminal(); const id = f.view.battleId; const body = reportFor(f.view);
    await action(f.p1, id, "report", body); expect((await action(f.p2, id, "report", body)).body.state).toBe("COMPLETED");
    const request = { requestId: "rematch-1", snapshot: { ...snapshot(), hp: 60 } };
    const rematch = await action(f.p1, id, "rematch", request); expect(rematch.status).toBe(200); expect(rematch.body).toMatchObject({ state: "PENDING", rematchOf: id, mode: "manual", p2: { trainerId: f.p2.trainerId } });
    expect(rematch.body.p2.snapshot).toBeUndefined(); expect((await action(f.p1, id, "rematch", request)).body.battleId).toBe(rematch.body.battleId);
    expectError(await action(f.p1, id, "rematch", { ...request, snapshot: snapshot() }), 409, "idempotency_conflict");
    const next = rematch.body.battleId;
    await action(f.p2, next, "accept", { revision: 1, snapshot: snapshot("recovered") }); await action(f.p1, next, "confirm", { revision: 2 });
    for (const [who, socket] of [[f.p1, f.a], [f.p2, f.b]] as const) expect((await action(who, next, "ready", { revision: 2, connectionId: socket.hello.connectionId, ...versions })).status).toBe(200);
    const config = (await getBattle(f.p1, next)).body.config;
    for (const [who, socket] of [[f.p1, f.a], [f.p2, f.b]] as const) expect((await action(who, next, "start", { revision: 2, connectionId: socket.hello.connectionId, readyToken: config.readyToken, engineHash: versions.engineHash })).status).toBe(200);
    const nf = { ...f, view: (await getBattle(f.p1, next)).body }; const view = await release(nf);
    const draw = reportFor(view, { winner: "draw", finalHp: { p1: 40, p2: 30 } }); await action(f.p1, next, "report", draw); expect((await action(f.p2, next, "report", draw)).body.state).toBe("COMPLETED");
    expect(await records(f.p1.trainerId)).toMatchObject({ wins: 1, draws: 1, streak: 0, best_streak: 1, streak_reached_order: null }); expect(await records(f.p2.trainerId)).toMatchObject({ losses: 1, draws: 1, streak: 0 });
  });
  it.each(["leave", "remove"])("atomically voids running battle and cancels pending challenges on %s", async kind => {
    const f = await terminal(); const id = f.view.battleId;
    const pending = await createBattle(f.p2, f.third, "manual", "new", snapshot("unused")); expect(pending.status).toBe(200);
    const res = kind === "leave" ? await call("POST", "/v1/leave", { key: f.p2.accessKey }) : await call("POST", "/v1/members/remove", { key: f.p1.accessKey, body: { trainerId: f.p2.trainerId } }); expect(res.status).toBe(200);
    expect((await getBattle(f.p1, id)).body).toMatchObject({ state: "VOID", reason: "participant_left" }); expect(await locks(id)).toEqual([]);
    expect((await getBattle(f.third, pending.body.battleId)).body.state).toBe("CANCELLED"); expect(await records(f.p1.trainerId)).toBeUndefined();
  });
  it.each(["leave", "remove"])("preserves completed history and records after %s", async kind => {
    const f = await terminal(); const id = f.view.battleId; const body = reportFor(f.view);
    expect((await action(f.p1, id, "report", body)).body.state).toBe("REPORTED");
    const completed = await action(f.p2, id, "report", body); expect(completed.body.state).toBe("COMPLETED");
    const before = [await records(f.p1.trainerId), await records(f.p2.trainerId)];
    const res = kind === "leave" ? await call("POST", "/v1/leave", { key: f.p2.accessKey }) : await call("POST", "/v1/members/remove", { key: f.p1.accessKey, body: { trainerId: f.p2.trainerId } }); expect(res.status).toBe(200);
    expect((await getBattle(f.p1, id)).body).toEqual(completed.body);
    expect([await records(f.p1.trainerId), await records(f.p2.trainerId)]).toEqual(before);
  });
  it("requires a completed source and supports reverse-initiator rematches", async () => {
    const f = await terminal(); const id = f.view.battleId;
    expectError(await action(f.p2, id, "rematch", { requestId: "reverse", snapshot: snapshot("fresh") }), 409, "invalid_state");
    const report = reportFor(f.view); await action(f.p1, id, "report", report); expect((await action(f.p2, id, "report", report)).body.state).toBe("COMPLETED");
    const rematch = await action(f.p2, id, "rematch", { requestId: "reverse", snapshot: snapshot("fresh") }); expect(rematch.status).toBe(200);
    expect(rematch.body).toMatchObject({ state: "PENDING", rematchOf: id, p1: { trainerId: f.p2.trainerId, snapshot: snapshot("fresh") }, p2: { trainerId: f.p1.trainerId } });
    expect(rematch.body.config).toBeNull(); expect(rematch.body.p2.snapshot).toBeUndefined();
  });
  it("increments consecutive wins and retains the best streak after losing", async () => {
    const f = await terminal(); let view = f.view;
    await setClock(f.view.startedAt);
    let lastOrder = 0;
    for (const [index, winner] of ["p1", "p1", "p2"].entries()) {
      if (index > 0) {
        const created = await createBattle(f.p1, f.p2); expect(created.status).toBe(200); const id = created.body.battleId;
        expect((await action(f.p2, id, "accept", { revision: 1, snapshot: snapshot("original_2") })).status).toBe(200);
        expect((await action(f.p1, id, "confirm", { revision: 2 })).status).toBe(200);
        for (const [who, socket] of [[f.p1, f.a], [f.p2, f.b]] as const) expect((await action(who, id, "ready", { revision: 2, connectionId: socket.hello.connectionId, ...versions })).status).toBe(200);
        const config = (await getBattle(f.p1, id)).body.config;
        for (const [who, socket] of [[f.p1, f.a], [f.p2, f.b]] as const) expect((await action(who, id, "start", { revision: 2, connectionId: socket.hello.connectionId, readyToken: config.readyToken, engineHash: versions.engineHash })).status).toBe(200);
        view = await release({ ...f, view: (await getBattle(f.p1, id)).body });
      }
      const body = reportFor(view, { winner, finalHp: winner === "p1" ? { p1: 50, p2: 0 } : { p1: 0, p2: 50 } });
      expect((await action(f.p1, view.battleId, "report", body)).status).toBe(200);
      expect((await action(f.p2, view.battleId, "report", body)).body.state).toBe("COMPLETED");
      const winnerRecord = await records(winner === "p1" ? f.p1.trainerId : f.p2.trainerId);
      expect(Number(winnerRecord!.streak_reached_order)).toBeGreaterThan(lastOrder);
      lastOrder = Number(winnerRecord!.streak_reached_order);
      if (index === 1) expect(await records(f.p1.trainerId)).toMatchObject({ wins: 2, streak: 2, best_streak: 2 });
    }
    expect(await records(f.p1.trainerId)).toMatchObject({ wins: 2, losses: 1, draws: 0, streak: 0, best_streak: 2, streak_reached_order: null });
    expect(await records(f.p2.trainerId)).toMatchObject({ wins: 1, losses: 2, streak: 1, best_streak: 1 });
  });
  it("restores the same battle under a recovered key", async () => {
    const f = await terminal(); const recovered = await recoverAccount(f.p2); await connect(recovered.accessKey);
    expectError(await getBattle(f.p2, f.view.battleId), 401, "unauthorized");
    const view = (await getBattle(recovered, f.view.battleId)).body; expect(view.config).toEqual(f.view.config); expect(view.journal).toEqual(f.view.journal); expect(await locks(f.view.battleId)).toHaveLength(2);
  });
});
