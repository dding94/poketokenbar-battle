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
