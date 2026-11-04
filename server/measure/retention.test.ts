import { runInDurableObject } from "cloudflare:test";
import { expect, it } from "vitest";
import { BATTLE_SCHEMA, BattleStore, type Battle } from "../src/battle-store";
import { unpackPair } from "../src/battle-packing";
import { battleView } from "../src/battle-view";
import { closeSocketsAfterAll } from "../test/ws/socket";
import { packedSession } from "../test/ws/packed-session";
closeSocketsAfterAll();
it("measures retained SQLite pages and a 1000-room legacy migration from a synthetic completed template", async () => {
  const print = console.log.bind(console), f = await packedSession("manual");
  let view = f.view;
  for (let seq = 1; seq <= 200; seq++) {
    await f.clock(f.view.startedAt + seq * 29_000);
    await f.action(0, "choices", { roundSeq: seq, choice: "move 1" });
    view = await f.action(1, "choices", { roundSeq: seq, choice: "move 2" });
    if (seq < 200) view = await f.action(0, "advance", { processedRoundSeq: seq });
  }
  const report = { readyToken: view.config.readyToken, engineHash: view.config.engineHash, terminalSeq: 200, winner: "p1", logHash: "c".repeat(64), journalHash: "d".repeat(64), finalHp: { p1: 50, p2: 0 } };
  await f.action(0, "report", report); await f.action(1, "report", report);
  const result = await runInDurableObject(f.stub, (instance, state) => {
    const sql = state.storage.sql, original = sql.exec<{ data: string }>("SELECT data FROM battle_rooms").one(), template: Battle = JSON.parse(original.data);
    const baselineBytes = sql.databaseSize, checkpoints: { additionalGames: number; bytes: number; deltaBytes: number }[] = [];
    state.storage.transactionSync(() => {
      for (let i = 1; i <= 1000; i++) {
        const id = `bt_${crypto.randomUUID().replaceAll("-", "")}`, data = JSON.stringify({ ...template, battleId: id });
        sql.exec("INSERT INTO battle_rooms(id,group_id,p1,p2,state,deadline,turn_deadline,data) SELECT ?,group_id,p1,p2,state,deadline,turn_deadline,? FROM battle_rooms WHERE id=?", id, data, template.battleId);
        sql.exec("INSERT INTO battle_reports(battle_id,side,payload) SELECT ?,side,payload FROM battle_reports WHERE battle_id=?", id, template.battleId);
        sql.exec("INSERT INTO battle_receipts(battle_id,actor,action,revision,payload) SELECT ?,actor,action,revision,payload FROM battle_receipts WHERE battle_id=?", id, template.battleId);
        sql.exec("INSERT INTO battle_requests(trainer_id,request_id,payload,battle_id) SELECT trainer_id,?,payload,? FROM battle_requests WHERE battle_id=?", `retention-${i}`, id, template.battleId);
        if (i === 100 || i === 1000) checkpoints.push({ additionalGames: i, bytes: sql.databaseSize, deltaBytes: sql.databaseSize - baselineBytes });
      }
      sql.exec("UPDATE battle_records SET wins=1001,streak=1001,best_streak=1001,streak_reached_order=1001 WHERE trainer_id=?", template.p1);
      sql.exec("UPDATE battle_records SET losses=1001 WHERE trainer_id=?", template.p2);
      sql.exec("UPDATE meta SET value='1001' WHERE key='battle_completion_sequence'");
    });
    const packedBytes = sql.databaseSize;
    const store = new BattleStore(sql), cursors: SqlStorageCursor<Record<string, SqlStorageValue>>[] = [], exec = sql.exec.bind(sql);
    sql.exec = ((query: string, ...values: SqlStorageValue[]) => { const cursor = exec(query, ...values); cursors.push(cursor); return cursor; }) as typeof sql.exec;
    let pageRowsRead = 0, pageResponseBytes = 0;
    try {
      const page = store.list(template.p1, Number.MAX_SAFE_INTEGER);
      pageResponseBytes = new TextEncoder().encode(JSON.stringify({ battles: page.slice(0, 100).map(r => battleView(store, JSON.parse(r.data), template.p1)), before: String(page[99]!.seq) })).length;
      pageRowsRead = cursors.reduce((sum, cursor) => sum + cursor.rowsRead, 0);
    } finally { sql.exec = exec; }
    // Rebuild a real v3 layout only in this unique local fixture; preserve each report rowid.
    const reportsBefore = sql.exec("SELECT rowid,* FROM battle_reports ORDER BY rowid").toArray();
    state.storage.transactionSync(() => {
      sql.exec("DROP INDEX battle_running"); sql.exec("ALTER TABLE battle_rooms DROP COLUMN turn_deadline");
      sql.exec(BATTLE_SCHEMA.find(s => s.startsWith("CREATE TABLE battle_rounds"))!);
      for (const row of sql.exec<{ id: string; data: string }>("SELECT id,data FROM battle_rooms").toArray()) {
        const b: Battle = JSON.parse(row.data);
        for (const [index, tuple] of b.relay.pairs.entries()) {
          const pair = unpackPair(b, tuple, index);
          sql.exec("INSERT INTO battle_rounds(battle_id,seq,deadline,p1,p2,pair) VALUES(?,?,?,?,?,?)", row.id, index + 1, pair.releasedAt + 1000, pair.p1.kind === "move" ? pair.p1.slot : null, pair.p2.kind === "move" ? pair.p2.slot : null, JSON.stringify(pair));
        }
        const { relay: _relay, ...legacy } = b; sql.exec("UPDATE battle_rooms SET data=? WHERE id=?", JSON.stringify(legacy), row.id);
      }
      sql.exec("UPDATE meta SET value='3' WHERE key='schema_version'");
    });
    const legacyBytes = sql.databaseSize, started = performance.now();
    (instance as unknown as { migrate(): void }).migrate();
    const migrationWallMs = performance.now() - started, migratedBytes = sql.databaseSize;
    expect(sql.exec("SELECT rowid,* FROM battle_reports ORDER BY rowid").toArray()).toEqual(reportsBefore);
    expect(sql.exec("SELECT value FROM meta WHERE key='schema_version'").one().value).toBe("4");
    return { fixtureOnly: true, completedHTTPGames: 1, templateMode: "manual", templateTurnMs: 29_000, clonedRetainedGames: 1000, roundsPerGame: 200, baselineBytes, checkpoints, packedBytes, pageRowsRead, pageResponseBytes, legacyRows: 200_200, legacyBytes, migratedBytes, migrationWallMs };
  });
  print(JSON.stringify({ localWorkerdOnly: true, scenario: "retention-and-v3-migration", ...result }));
  expect(result.pageRowsRead).toBeLessThanOrEqual(110);
  // Projection is bytes/page growth, not a hosted capacity or migration-CPU guarantee.
  expect(result.checkpoints[1]!.deltaBytes / 1000 * 36_500).toBeLessThan(1_000_000_000);
});
