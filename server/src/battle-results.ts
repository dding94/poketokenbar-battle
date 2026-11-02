import { canonical, type Report, type Side } from "./battle-input";
import { BattleStore, type Battle } from "./battle-store";
import { battleChanged, type BattleEffect } from "./battle-effects";
import { fail, ok, type Result } from "./contract";
/** Caller owns one transaction encompassing reports, room, records and lock release. */
export class BattleResults {
  constructor(private readonly store: BattleStore) {}
  report(b: Battle, side: Side, report: Report, now: number, after: BattleEffect[]): Result<null> {
    // Foreign configurations are rejected even when a prior report or terminal result exists.
    if (!b.config || report.readyToken !== b.config.readyToken) return fail("not_ready");
    if (report.engineHash !== b.config.engineHash) return fail("engine_mismatch");
    if (report.finalHp.p1 > b.snapshots.p1.public.stats.hp || report.finalHp.p2 > b.snapshots.p2!.public.stats.hp || report.winner === "p1" && report.finalHp.p2 !== 0 || report.winner === "p2" && report.finalHp.p1 !== 0) return fail("bad_request");
    const payload = canonical(report);
    const saved = this.store.sql.exec<{ side: Side; payload: string }>("SELECT side,payload FROM battle_reports WHERE battle_id=?", b.battleId).toArray();
    const own = saved.find(r => r.side === side);
    if (own) return own.payload === payload ? ok(null) : fail("report_conflict");
    if (b.state !== "RUNNING" && b.state !== "REPORTED") return fail("invalid_state");
    if (b.state === "RUNNING") {
      const round = this.store.round(b.battleId, b.roundSeq);
      if (report.terminalSeq !== b.roundSeq || !round?.pair) return fail("stale_round");
    }
    // No checks that can return fail remain after this first write.
    this.store.sql.exec("INSERT INTO battle_reports(battle_id,side,payload) VALUES(?,?,?)", b.battleId, side, payload);
    if (saved.length === 0) {
      b.state = "REPORTED"; b.reportedAt = now;
    } else {
      if (saved[0]!.payload === payload) {
        b.state = "COMPLETED"; b.result = report;
        for (const player of ["p1", "p2"] as const) this.record(b[player], report.winner === "draw" ? "draw" : report.winner === player ? "win" : "loss");
      } else {
        b.state = "VOID"; b.reason = "result_mismatch";
        after.push({ recipients: [], groupId: b.groupId, message: { type: "battle_void", battleId: b.battleId, reason: "result_mismatch" } });
      }
      this.store.unlock(b.battleId);
    }
    this.store.put(b); after.push(battleChanged(b)); return ok(null);
  }
  private record(trainerId: string, outcome: "win" | "loss" | "draw"): void {
    const win = outcome === "win" ? 1 : 0, loss = outcome === "loss" ? 1 : 0, draw = outcome === "draw" ? 1 : 0;
    this.store.sql.exec(`INSERT INTO battle_records(trainer_id,wins,losses,draws,streak,best_streak) VALUES(?,?,?,?,?,?)
      ON CONFLICT(trainer_id) DO UPDATE SET wins=wins+excluded.wins, losses=losses+excluded.losses, draws=draws+excluded.draws,
      streak=CASE WHEN excluded.wins=1 THEN streak+1 ELSE 0 END,
      best_streak=MAX(best_streak, CASE WHEN excluded.wins=1 THEN streak+1 ELSE 0 END)`, trainerId, win, loss, draw, win, win);
  }
}
