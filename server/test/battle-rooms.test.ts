import { describe, expect, it } from "vitest";
import { runInDurableObject } from "cloudflare:test";
import { League } from "../src/league";
import { DAY, call, createGroup, dumpTables, expectError, leagueStub, setClock, setupGroup, useRealClockAfterEach } from "./helpers";
import { accepted, action, confirmed, createBattle, getBattle, room, snapshot, versions } from "./battle-fixture";
useRealClockAfterEach();
describe("battle rooms", () => {
  it("creates PENDING and reveals only opponent public data", async () => {
    const f = await room();
    expect(f.view).toMatchObject({ state: "PENDING", revision: 1, p1: { trainerId: f.p1.trainerId, snapshot: snapshot() }, p2: { trainerId: f.p2.trainerId } });
    const theirs = await getBattle(f.p2, f.view.battleId); expect(theirs.status).toBe(200);
    expect(theirs.headers.get("cache-control")).toBe("no-store");
    expect(theirs.body.p1).toEqual({ trainerId: f.p1.trainerId, public: snapshot().public, hpPercent: 100 / 110 * 100 });
    expect(theirs.text).not.toContain("thunderbolt");
    const list = await call("GET", "/v1/battles", { key: f.p1.accessKey }); expect(list.status).toBe(200);
    expect(list.body.battles.map((b: any) => b.battleId)).toContain(f.view.battleId);
  });
  it("accepts, requires confirmation and preserves original revision retries", async () => {
    const f = await room(); const id = f.view.battleId; const body = { revision: 1, snapshot: snapshot("other") };
    const first = await action(f.p2, id, "accept", body); expect(first.status).toBe(200);
    expect(first.body).toMatchObject({ state: "ACCEPTED", revision: 2, confirmed: false });
    expectError(await action(f.p1, id, "ready", { revision: 2, connectionId: "missing", ...versions }), 409, "not_ready");
    expect((await action(f.p2, id, "accept", body)).status).toBe(200);
    expectError(await action(f.p2, id, "accept", { ...body, snapshot: snapshot("changed") }), 409, "stale_revision");
    expectError(await action(f.p1, id, "confirm", { revision: 1 }), 409, "stale_revision");
    const done = await action(f.p1, id, "confirm", { revision: 2 }); expect(done.status).toBe(200); expect(done.body.confirmed).toBe(true);
    expect((await action(f.p1, id, "confirm", { revision: 2 })).body).toEqual(done.body);
    expect((await action(f.p2, id, "accept", body)).body.confirmed).toBe(true);
  });
  it("updates only applicant PENDING snapshots and retries the original revision", async () => {
    const f = await room(); const id = f.view.battleId; const body = { revision: 1, snapshot: { ...snapshot(), hp: 99 } };
    expectError(await action(f.p2, id, "update", body), 409, "invalid_state");
    const first = await action(f.p1, id, "update", body); expect(first.status).toBe(200); expect(first.body.revision).toBe(2);
    expect((await action(f.p1, id, "update", body)).body).toEqual(first.body);
    expect((await action(f.p1, id, "update", { ...body, revision: 2 })).body.revision).toBe(2);
    expectError(await action(f.p2, id, "accept", { revision: 1, snapshot: snapshot() }), 409, "stale_revision");
  });
  it("creation keys normalize object order and reject changed requests", async () => {
    const f = await room(); const key = "unique-key"; const first = await createBattle(f.p1, f.p2, "manual", key);
    const retry = await call("POST", "/v1/battles", { key: f.p1.accessKey, body: { snapshot: snapshot(), mode: "manual", targetTrainerId: f.p2.trainerId, requestId: key } });
    expect(first.status).toBe(200); expect(retry.body).toEqual(first.body);
    expectError(await createBattle(f.p1, f.p2, "auto", key), 409, "idempotency_conflict");
  });
  it("hides rooms from third members and other groups", async () => {
    const f = await accepted(); const outside = await createGroup();
    for (const actor of [f.third, outside]) {
      expectError(await getBattle(actor, f.view.battleId), 404, "not_found");
      expectError(await action(actor, f.view.battleId, "cancel", { revision: f.view.revision }), 404, "not_found");
    }
    expectError(await createBattle(f.p1, outside), 404, "not_found"); expectError(await createBattle(f.p1, f.p1), 400, "cannot_target_self");
  });
  it("expires at the original 24h deadline despite a delayed alarm", async () => {
    const t = Date.now(); await setClock(t); const f = await room(); await setClock(t + DAY - 1);
    expect((await action(f.p1, f.view.battleId, "update", { revision: 1, snapshot: { ...snapshot(), hp: 98 } })).status).toBe(200);
    await setClock(t + DAY);
    expectError(await action(f.p2, f.view.battleId, "accept", { revision: 2, snapshot: snapshot() }), 409, "invalid_state");
    expect((await getBattle(f.p1, f.view.battleId)).body.state).toBe("EXPIRED");
  });
  it("declines only target PENDING and cancels idempotently", async () => {
    const f = await room(); const body = { revision: 1 };
    expectError(await action(f.p1, f.view.battleId, "decline", body), 409, "invalid_state");
    expect((await action(f.p2, f.view.battleId, "decline", body)).body.state).toBe("DECLINED");
    expect((await action(f.p2, f.view.battleId, "decline", body)).body.state).toBe("DECLINED");
    const g = await accepted(); const cancel = { revision: g.view.revision };
    expect((await action(g.p2, g.view.battleId, "cancel", cancel)).body.state).toBe("CANCELLED");
    expect((await action(g.p1, g.view.battleId, "cancel", cancel)).body.state).toBe("CANCELLED");
  });
  it("requires a current socket for readiness", async () => {
    const f = await confirmed();
    expectError(await action(f.p1, f.view.battleId, "ready", { revision: f.view.revision, connectionId: "missing", ...versions }), 409, "not_ready");
  });
  it("migrates v1 preserving accounts and invitations", async () => {
    await setupGroup(); const before = await dumpTables();
    await runInDurableObject(leagueStub(), (_instance, state) => {
      const tables = state.storage.sql.exec<{ name: string }>("SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'battle_%'").toArray();
      state.storage.transactionSync(() => {
        for (const { name } of tables) state.storage.sql.exec(`DROP TABLE ${name}`);
        state.storage.sql.exec("UPDATE meta SET value='1' WHERE key='schema_version'");
      }); new League(state, {} as Env);
    });
    const after = await dumpTables(); for (const table of ["trainers", "groups", "invites", "attempts"]) expect(after[table]).toEqual(before[table]);
    expect(after.meta).toContainEqual({ key: "schema_version", value: "2" }); expect(after.battle_locks).toBeDefined();
  });
});
