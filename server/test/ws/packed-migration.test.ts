import { runInDurableObject } from "cloudflare:test";
import { expect, it } from "vitest";
import { BATTLE_SCHEMA, type Battle } from "../../src/battle-store";
import { unpackPair } from "../../src/battle-packing";
import { closeSocketsAfterAll } from "./socket";
import { packedSession } from "./packed-session";
closeSocketsAfterAll();
async function legacy(f: Awaited<ReturnType<typeof packedSession>>, corrupt?: string) {
  return runInDurableObject(f.stub, (instance, state) => {
    const sql = state.storage.sql, row = sql.exec<{ data: string; seq: number }>("SELECT seq,data FROM battle_rooms").one(), b: Battle = JSON.parse(row.data);
    const rounds = b.relay.pairs.map((tuple, index) => {
      const pair = unpackPair(b, tuple, index);
      return { seq: index + 1, deadline: b.mode === "manual" ? pair.releasedAt + 1 : null, p1: pair.p1.kind === "move" ? pair.p1.slot : null, p2: pair.p2.kind === "move" ? pair.p2.slot : null, pair: JSON.stringify(pair) };
    });
    if (b.relay.current) rounds.push({ seq: b.roundSeq, ...b.relay.current, pair: null as unknown as string });
    const { relay: _relay, ...old } = b;
    sql.exec("DROP INDEX battle_running"); sql.exec("ALTER TABLE battle_rooms DROP COLUMN turn_deadline");
    sql.exec(BATTLE_SCHEMA.find(s => s.startsWith("CREATE TABLE battle_rounds"))!);
    for (const r of rounds) sql.exec("INSERT INTO battle_rounds(battle_id,seq,deadline,p1,p2,pair) VALUES(?,?,?,?,?,?)", b.battleId, r.seq, r.deadline, r.p1, r.p2, r.pair);
    sql.exec("UPDATE battle_rooms SET data=?", JSON.stringify(old)); sql.exec("UPDATE meta SET value='3' WHERE key='schema_version'");
    // Corrupt a later room, after the first valid room has already been converted.
    const badId = `${b.battleId}-later`;
    if (corrupt) {
      sql.exec("INSERT INTO battle_rooms(id,group_id,p1,p2,state,deadline,data) SELECT ?,group_id,p1,p2,state,deadline,? FROM battle_rooms WHERE id=?", badId, JSON.stringify({ ...old, battleId: badId }), b.battleId);
      sql.exec("INSERT INTO battle_rounds SELECT ?,seq,deadline,p1,p2,pair FROM battle_rounds WHERE battle_id=?", badId, b.battleId);
    }
    if (corrupt === "missing") sql.exec("DELETE FROM battle_rounds WHERE battle_id=? AND seq=1", badId);
    if (corrupt === "choice") sql.exec("UPDATE battle_rounds SET p1=4 WHERE battle_id=? AND seq=1", badId);
    if (corrupt === "timestamp") {
      const pair = JSON.parse(rounds[0]!.pair); pair.releasedAt = 1.5; sql.exec("UPDATE battle_rounds SET pair=? WHERE battle_id=? AND seq=1", JSON.stringify(pair), badId);
    }
    const before = sql.exec("SELECT * FROM battle_rooms").toArray(), reports = sql.exec("SELECT rowid,* FROM battle_reports ORDER BY rowid").toArray(), records = sql.exec("SELECT * FROM battle_records").toArray();
    let failed = false;
    try { (instance as unknown as { migrate(): void }).migrate(); } catch { failed = true; }
    return { failed, before, after: sql.exec("SELECT * FROM battle_rooms").toArray(), reports, afterReports: sql.exec("SELECT rowid,* FROM battle_reports ORDER BY rowid").toArray(), records, afterRecords: sql.exec("SELECT * FROM battle_records").toArray(), version: sql.exec("SELECT value FROM meta WHERE key='schema_version'").one().value, legacyExists: sql.exec("SELECT name FROM sqlite_master WHERE name='battle_rounds'").toArray().length };
  });
}
async function manual() {
  const f = await packedSession();
  // Signed timestamp deltas remain lossless even if the wall clock moves backwards.
  await f.clock(f.view.startedAt - 1);
  await f.action(0, "choices", { roundSeq: 1, choice: "move 3" }); await f.action(1, "choices", { roundSeq: 1, choice: "move 2" });
  await f.action(0, "advance", { processedRoundSeq: 1 }); await f.action(0, "choices", { roundSeq: 2, choice: "move 4" });
  return f;
}
it("atomically packs v3 history with identical wire, private current choice and creation cursor", async () => {
  const f = await manual(), before = await f.get(), migrated = await legacy(f);
  expect(migrated.failed).toBe(false); expect(migrated.version).toBe("4"); expect(migrated.legacyExists).toBe(0);
  expect(migrated.after[0]!.seq).toBe(migrated.before[0]!.seq); expect(await f.get()).toEqual(before);
  expect((await f.get(1)).ownChoice).toBeNull(); expect((await f.action(0, "choices", { roundSeq: 1, choice: "move 3" })).journal).toEqual(before.journal);
});
it("preserves completed reports' rowids, standings and completion order during v3 packing", async () => {
  const f = await packedSession("auto");
  const report = { readyToken: f.view.config.readyToken, engineHash: f.view.config.engineHash, terminalSeq: 1, winner: "p1", logHash: "c".repeat(64), journalHash: "d".repeat(64), finalHp: { p1: 50, p2: 0 } };
  await f.action(0, "report", report); await f.action(1, "report", report);
  const before = await f.get(), migrated = await legacy(f);
  expect(migrated.failed).toBe(false); expect(migrated.afterReports).toEqual(migrated.reports); expect(migrated.afterRecords).toEqual(migrated.records);
  expect(await f.get()).toEqual(before); expect(await f.action(1, "report", report)).toEqual(before);
});
it.each(["missing", "choice", "timestamp"])("rolls back the complete v3 migration on %s corruption", async corruption => {
  const f = await manual(), migrated = await legacy(f, corruption);
  expect(migrated.failed).toBe(true); expect(migrated.version).toBe("3"); expect(migrated.legacyExists).toBe(1);
  expect(migrated.after).toEqual(migrated.before); expect(migrated.afterReports).toEqual(migrated.reports); expect(migrated.afterRecords).toEqual(migrated.records);
});
