import { canonical } from "./battle-input";
import type { Battle } from "./battle-store";

export interface Standing {
  trainerId: string; displayName: string; wins: number; losses: number; draws: number;
  streak: number; bestStreak: number; winRate: number | null;
}
export interface Standings { groupId: string; championTrainerId: string | null; rows: Standing[] }
type RecordRow = { trainer_id: string; wins: number; losses: number; draws: number; streak: number; best_streak: number };
type HistoricalRecord = Omit<RecordRow, "trainer_id"> & { order: number | null };
const emptyRecord = (): HistoricalRecord => ({ wins: 0, losses: 0, draws: 0, streak: 0, best_streak: 0, order: null });
const inconsistent = (): never => { throw new Error("inconsistent battle history during standings migration"); };

/** Called only inside the schema transaction. Never repairs or resets contradictory history. */
export function migrateStandings(sql: SqlStorage): void {
  const history = sql.exec<{ id: string; p1: string; p2: string; data: string; completion_order: number | null; reports: number; p1_report: string | null; p2_report: string | null }>(`
    SELECT b.id,b.p1,b.p2,b.data,MAX(r.rowid) AS completion_order,COUNT(r.side) AS reports,
      MAX(CASE WHEN r.side='p1' THEN r.payload END) AS p1_report,
      MAX(CASE WHEN r.side='p2' THEN r.payload END) AS p2_report
    FROM battle_rooms b LEFT JOIN battle_reports r ON r.battle_id=b.id
    WHERE b.state='COMPLETED' GROUP BY b.id ORDER BY completion_order`).toArray();
  const expected = new Map<string, HistoricalRecord>();
  for (const row of history) {
    const battle = JSON.parse(row.data) as Battle;
    if (row.reports !== 2 || row.p1_report === null || row.p2_report === null || row.completion_order === null
      || row.p1_report !== row.p2_report || !battle.result || canonical(battle.result) !== canonical(JSON.parse(row.p1_report))
      || battle.state !== "COMPLETED" || battle.battleId !== row.id || battle.p1 !== row.p1 || battle.p2 !== row.p2 || row.p1 === row.p2
      || !["p1", "p2", "draw"].includes(battle.result.winner)) inconsistent();
    for (const side of ["p1", "p2"] as const) {
      const record = expected.get(battle[side]) ?? emptyRecord();
      if (battle.result!.winner === side) {
        record.wins++; record.streak++; record.best_streak = Math.max(record.best_streak, record.streak); record.order = row.completion_order;
      } else {
        if (battle.result!.winner === "draw") record.draws++; else record.losses++;
        record.streak = 0; record.order = null;
      }
      expected.set(battle[side], record);
    }
  }
  const records = sql.exec<RecordRow>("SELECT trainer_id,wins,losses,draws,streak,best_streak FROM battle_records").toArray();
  const seen = new Set<string>();
  for (const record of records) {
    const computed = expected.get(record.trainer_id) ?? emptyRecord();
    for (const field of ["wins", "losses", "draws", "streak", "best_streak"] as const) if (record[field] !== computed[field]) inconsistent();
    seen.add(record.trainer_id);
  }
  if ([...expected.keys()].some(id => !seen.has(id))) inconsistent();
  sql.exec("ALTER TABLE battle_records ADD COLUMN streak_reached_order INTEGER");
  // The final win of a current positive streak is necessarily its latest completed outcome.
  for (const record of records.filter(r => r.streak > 0)) {
    sql.exec("UPDATE battle_records SET streak_reached_order=? WHERE trainer_id=?", expected.get(record.trainer_id)!.order, record.trainer_id);
  }
  const max = sql.exec<{ maximum: number }>("SELECT COALESCE(MAX(rowid),0) AS maximum FROM battle_reports").toArray()[0]!.maximum;
  sql.exec("INSERT INTO meta(key,value) VALUES('battle_completion_sequence',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", String(max));
}

/** Synchronous group-scoped aggregate read; no report, snapshot or journal is read. */
export function readStandings(sql: SqlStorage, groupId: string): Standings {
  const records = sql.exec<RecordRow & { display_email: string }>(`
    SELECT t.id AS trainer_id,t.display_email,COALESCE(r.wins,0) AS wins,COALESCE(r.losses,0) AS losses,
      COALESCE(r.draws,0) AS draws,COALESCE(r.streak,0) AS streak,COALESCE(r.best_streak,0) AS best_streak
    FROM trainers t LEFT JOIN battle_records r ON r.trainer_id=t.id
    WHERE t.group_id=? AND t.status='active'
    ORDER BY streak DESC,CASE WHEN r.streak>0 THEN r.streak_reached_order END ASC,
      CASE WHEN COALESCE(r.streak,0)=0 THEN COALESCE(r.wins,0) END DESC,t.id ASC`, groupId).toArray();
  const rows = records.map(r => ({ trainerId: r.trainer_id, displayName: r.display_email, wins: r.wins, losses: r.losses,
    draws: r.draws, streak: r.streak, bestStreak: r.best_streak, winRate: r.wins+r.losses+r.draws >= 5 ? r.wins/(r.wins+r.losses+r.draws) : null }));
  return { groupId, championTrainerId: rows[0] && rows[0].streak > 0 ? rows[0].trainerId : null, rows };
}
