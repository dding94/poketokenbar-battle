import { runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { call, createGroup, expectError, leagueStub, setupGroup } from "./helpers";

describe("group standings", () => {
  it("requires authentication and rejects unsupported filters and methods", async () => {
    const f = await setupGroup();
    expectError(await call("GET", "/v1/standings"), 401, "unauthorized");
    for (const query of ["groupId=other", "before=1", "trainerId=x", "sort=wins", "limit=10"]) {
      expectError(await call("GET", `/v1/standings?${query}`, { key: f.host.accessKey }), 400, "bad_request");
    }
    expectError(await call("POST", "/v1/standings", { key: f.host.accessKey }), 405, "method_not_allowed");
  });
  it("includes only active own-group members, with a closed public DTO and no champion at zero", async () => {
    const f = await setupGroup(2), other = await createGroup();
    await call("POST", "/v1/leave", { key: f.members[1]!.accessKey });
    const result = await call("GET", "/v1/standings", { key: f.members[0]!.accessKey });
    expect(result.status).toBe(200);
    expect(result.headers.get("cache-control")).toBe("no-store");
    expect(result.body).toEqual({ groupId: f.host.groupId, championTrainerId: null, rows: [f.host, f.members[0]!].sort((a,b) => a.trainerId.localeCompare(b.trainerId)).map(a => ({ trainerId: a.trainerId, displayName: a.email, wins: 0, losses: 0, draws: 0, streak: 0, bestStreak: 0, winRate: null })) });
    expect(result.text).not.toContain(other.trainerId);
    expectError(await call("GET", "/v1/standings", { key: f.members[1]!.accessKey }), 401, "unauthorized");
  });
  it("orders positive ties by reaching order, zero ties by wins then ID, and counts draws in five-game rates", async () => {
    const f = await setupGroup(5), all = [f.host, ...f.members];
    // Seed aggregates to isolate reading/sorting from completion tests in the ws project.
    await runInDurableObject(leagueStub(), (_i, state) => {
      const rows = [[3,1,1,2,3,20], [3,0,1,2,2,10], [4,1,0,0,4,null], [1,0,0,1,1,5], [2,2,1,0,2,null], [2,2,1,0,2,null]];
      const columns = state.storage.sql.exec<{name:string}>("PRAGMA table_info(battle_records)").toArray().map(r=>r.name);
      rows.forEach((r,i) => { state.storage.sql.exec("INSERT INTO battle_records(trainer_id,wins,losses,draws,streak,best_streak) VALUES(?,?,?,?,?,?)", all[i]!.trainerId, ...r.slice(0,5)); if(columns.includes("streak_reached_order")) state.storage.sql.exec("UPDATE battle_records SET streak_reached_order=? WHERE trainer_id=?", r[5]!, all[i]!.trainerId); });
    });
    const res = await call("GET", "/v1/standings", { key: f.host.accessKey });
    expect(res.status).toBe(200);
    expect(res.body.championTrainerId).toBe(all[1]!.trainerId);
    expect(res.body.rows.map((r:any)=>r.trainerId)).toEqual([all[1]!.trainerId, all[0]!.trainerId, all[3]!.trainerId, all[2]!.trainerId, ...all.slice(4).map(a=>a.trainerId).sort()]);
    expect(res.body.rows.map((r:any)=>r.winRate)).toEqual([null, .6, null, .8, .4, .4]);
    await call("POST", "/v1/leave", { key: all[1]!.accessKey });
    expect((await call("GET", "/v1/standings", { key: f.host.accessKey })).body.championTrainerId).toBe(f.host.trainerId);
  });
});
