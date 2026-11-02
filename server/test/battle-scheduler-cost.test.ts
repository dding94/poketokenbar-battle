import { runInDurableObject } from "cloudflare:test";
import { expect, it } from "vitest";
import { BattleStore } from "../src/battle-store";
import { createGroup, leagueStub } from "./helpers";
it("schedules from the live deadline index without reading retained battle history", async () => {
  await createGroup();
  const measured = await runInDurableObject(leagueStub(), (_instance, state) => {
    const sql = state.storage.sql;
    state.storage.transactionSync(() => {
      for (let i = 0; i < 1000; i++) sql.exec("INSERT INTO battle_rooms(id,group_id,p1,p2,state,deadline,data) VALUES(?, 'cost', 'a', 'b', 'COMPLETED', NULL, '{}')", `history-${i}`);
      sql.exec("INSERT INTO battle_rooms(id,group_id,p1,p2,state,deadline,data) VALUES('live','cost','a','b','PENDING',100,'{}')");
    });
    const original = sql.exec.bind(sql); let reads = 0;
    sql.exec = ((query: string, ...values: SqlStorageValue[]) => {
      const cursor = original(query, ...values);
      if (query.includes("MIN(deadline)")) reads += cursor.rowsRead;
      return cursor;
    }) as typeof sql.exec;
    try { return { deadline: new BattleStore(sql).earliest(), reads }; }
    finally { sql.exec = original; }
  });
  expect(measured.deadline).toBe(100);
  expect(measured.reads, "deadline lookup scanned retained history").toBeLessThanOrEqual(2);
});
it("bounds a page read across both participant indexes and preserves the next cursor", async () => {
  await createGroup();
  const measured = await runInDurableObject(leagueStub(), (_instance, state) => {
    const sql = state.storage.sql;
    state.storage.transactionSync(() => {
      sql.exec("DELETE FROM battle_rooms");
      for (let i = 0; i < 1001; i++) sql.exec("INSERT INTO battle_rooms(id,group_id,p1,p2,state,deadline,data) VALUES(?, 'cost', ?, ?, 'COMPLETED', NULL, '{}')", `page-${i}`, i % 2 ? "a" : "b", i % 2 ? "b" : "a");
    });
    const original = sql.exec.bind(sql); const cursors: SqlStorageCursor<Record<string, SqlStorageValue>>[] = [];
    sql.exec = ((query: string, ...values: SqlStorageValue[]) => { const cursor = original(query, ...values); cursors.push(cursor); return cursor; }) as typeof sql.exec;
    try {
      const store = new BattleStore(sql), first = store.list("a", Number.MAX_SAFE_INTEGER);
      const reads = cursors.reduce((sum, cursor) => sum + cursor.rowsRead, 0);
      const next = store.list("a", first[99]!.seq);
      return { reads, first: first.map(r => r.seq), next: next.map(r => r.seq) };
    } finally { sql.exec = original; }
  });
  expect(measured.first).toHaveLength(101); expect(measured.next).toHaveLength(101);
  expect(measured.first).toEqual([...measured.first].sort((a, b) => b - a));
  expect(measured.next[0]).toBe(measured.first[100]);
  expect(measured.reads, "one page read scanned the participant's entire history").toBeLessThanOrEqual(110);
});
