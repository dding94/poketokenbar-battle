import { env } from "cloudflare:workers";
import { runInDurableObject } from "cloudflare:test";
import { expect, it } from "vitest";
import { League } from "../src/league";
import { BATTLE_SCHEMA } from "../src/battle-store";

// Real SQLite v2 layout; unique DO per scenario.
async function migrate(corrupt: string | null = null) {
  const stub=env.LEAGUE.get(env.LEAGUE.idFromName(`migration-${crypto.randomUUID()}`));
  return runInDurableObject(stub, (_i,state)=>{
    const sql=state.storage.sql;
    for(const {name} of sql.exec<{name:string}>("SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'battle_%'").toArray()) sql.exec(`DROP TABLE ${name}`);
    for(const statement of BATTLE_SCHEMA) sql.exec(statement);
    sql.exec("UPDATE meta SET value='2' WHERE key='schema_version'");
    sql.exec("DELETE FROM meta WHERE key='battle_completion_sequence'");
    const result={winner:"p1"};
    // Creation A,B; first reports A,B; completion B,A. Same timestamps.
    for(const id of ["a","b"]) {
      const b={battleId:id,groupId:"g",p1:id,p2:`loser-${id}`,state:"COMPLETED",result,createdAt:100,reportedAt:100};
      sql.exec("INSERT INTO battle_rooms(id,group_id,p1,p2,state,data) VALUES(?,?,?,?,?,?)",id,"g",b.p1,b.p2,b.state,JSON.stringify(b));
      sql.exec("INSERT INTO battle_records(trainer_id,wins,streak,best_streak) VALUES(?,1,1,1)",id);
      sql.exec("INSERT INTO battle_records(trainer_id,losses) VALUES(?,1)",b.p2);
    }
    for(const [id,side] of [["a","p1"],["b","p2"],["b","p1"],["a","p2"]]) sql.exec("INSERT INTO battle_reports(battle_id,side,payload) VALUES(?,?,?)",id!,side!,JSON.stringify(result));
    sql.exec("INSERT INTO battle_reports(battle_id,side,payload) VALUES('pending','p1',?)",JSON.stringify(result));
    if(corrupt === "missing") sql.exec("DELETE FROM battle_reports WHERE battle_id='a' AND side='p2'");
    if(corrupt === "mismatch") sql.exec("UPDATE battle_reports SET payload=? WHERE battle_id='a' AND side='p2'",JSON.stringify({winner:"p2"}));
    if(corrupt === "counts") sql.exec("UPDATE battle_records SET wins=9 WHERE trainer_id='a'");
    if(corrupt === "streak") sql.exec("UPDATE battle_records SET streak=0 WHERE trainer_id='a'");
    if(corrupt === "absent-record") sql.exec("DELETE FROM battle_records WHERE trainer_id='a'");
    const before=sql.exec("SELECT * FROM battle_records ORDER BY trainer_id").toArray();
    let failed=false; try { new League(state, {} as Env); } catch { failed=true; }
    return {failed,before,records:sql.exec("SELECT * FROM battle_records ORDER BY trainer_id").toArray(),meta:sql.exec("SELECT * FROM meta").toArray(),columns:sql.exec<{name:string}>("PRAGMA table_info(battle_records)").toArray().map(r=>r.name)};
  });
}
it("migrates v2 using second report order, preserving aggregates and seeding above all reports", async()=>{
  const r=await migrate(); expect(r.failed).toBe(false);
  expect(r.meta).toContainEqual({key:"schema_version",value:"3"});
  expect(r.meta).toContainEqual({key:"battle_completion_sequence",value:"5"});
  expect(r.records).toEqual(r.before.map(row=>({...row,streak_reached_order:row.trainer_id==="a"?4:row.trainer_id==="b"?3:null})));
});
it.each(["missing","mismatch","counts","streak","absent-record"])("atomically rejects inconsistent v2 %s without resetting records",async corrupt=>{
  const r=await migrate(corrupt); expect(r.failed).toBe(true);
  expect(r.meta).toContainEqual({key:"schema_version",value:"2"});
  expect(r.meta.some(row=>row.key==="battle_completion_sequence")).toBe(false);
  expect(r.columns).not.toContain("streak_reached_order"); expect(r.records).toEqual(r.before);
});
