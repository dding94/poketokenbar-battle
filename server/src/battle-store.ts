import { canonical, type BattleMode, type Report, type Side, type Snapshot } from "./battle-input";
export type BattleState = "PENDING" | "ACCEPTED" | "READY" | "RUNNING" | "REPORTED" | "COMPLETED" | "DECLINED" | "CANCELLED" | "EXPIRED" | "VOID";
export const PRESTART = new Set<BattleState>(["PENDING", "ACCEPTED", "READY"]);
export const ACTIVE = new Set<BattleState>([...PRESTART, "RUNNING", "REPORTED"]);
export const CHALLENGE_MS = 24 * 60 * 60 * 1000;
export const REPORT_MS = 72 * 60 * 60 * 1000;
export const TURN_MS = 30_000;
export interface ReadyAck { connectionId: string; engineHash: string }
export interface FrozenConfig {
  readyToken: string; engineHash: string; rulesVersion: string; policyVersion: string; relayVersion: string;
  seed: number[]; policySeed: number;
  p1: { name: "p1"; set: Snapshot["set"]; hp: number; policy: "standard" };
  p2: { name: "p2"; set: Snapshot["set"]; hp: number; policy: "standard" };
}
export interface Battle {
  battleId: string; groupId: string; p1: string; p2: string; state: BattleState; revision: number;
  mode: BattleMode; createdAt: number; expiresAt: number; startedAt: number | null; reportedAt: number | null;
  confirmed: boolean; snapshots: { p1: Snapshot; p2: Snapshot | null };
  ready: Partial<Record<Side, ReadyAck>>; starts: Partial<Record<Side, string>>;
  config: FrozenConfig | null; roundSeq: number; result: Report | null; reason: string | null; rematchOf: string | null;
}
export type RelayToken = { kind: "move"; slot: number } | { kind: "timeout" } | { kind: "policy" };
export interface Pair { roundSeq: number; p1: RelayToken; p2: RelayToken; releasedAt: number }
export type Round = { battle_id: string; seq: number; deadline: number | null; p1: number | null; p2: number | null; pair: string | null };
export type StoredBattle = { seq: number; data: string };
export const BATTLE_SCHEMA = [
  `CREATE TABLE battle_rooms (seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE, group_id TEXT NOT NULL, p1 TEXT NOT NULL, p2 TEXT NOT NULL, state TEXT NOT NULL, deadline INTEGER, data TEXT NOT NULL)`,
  `CREATE INDEX battle_p1 ON battle_rooms(p1, seq)`, `CREATE INDEX battle_p2 ON battle_rooms(p2, seq)`,
  `CREATE INDEX battle_deadline ON battle_rooms(deadline) WHERE deadline IS NOT NULL`,
  `CREATE TABLE battle_locks (trainer_id TEXT NOT NULL, instance_id TEXT NOT NULL, battle_id TEXT NOT NULL, PRIMARY KEY(trainer_id, instance_id))`,
  `CREATE INDEX battle_lock_room ON battle_locks(battle_id)`,
  `CREATE TABLE battle_requests (trainer_id TEXT NOT NULL, request_id TEXT NOT NULL, payload TEXT NOT NULL, battle_id TEXT NOT NULL, PRIMARY KEY(trainer_id, request_id))`,
  `CREATE TABLE battle_receipts (battle_id TEXT NOT NULL, actor TEXT NOT NULL, action TEXT NOT NULL, revision INTEGER NOT NULL, payload TEXT NOT NULL, PRIMARY KEY(battle_id, actor, action, revision))`,
  `CREATE TABLE battle_rounds (battle_id TEXT NOT NULL, seq INTEGER NOT NULL, deadline INTEGER, p1 INTEGER, p2 INTEGER, pair TEXT, PRIMARY KEY(battle_id, seq))`,
  `CREATE TABLE battle_reports (battle_id TEXT NOT NULL, side TEXT NOT NULL, payload TEXT NOT NULL, PRIMARY KEY(battle_id, side))`,
  `CREATE TABLE battle_records (trainer_id TEXT PRIMARY KEY, wins INTEGER NOT NULL DEFAULT 0, losses INTEGER NOT NULL DEFAULT 0, draws INTEGER NOT NULL DEFAULT 0, streak INTEGER NOT NULL DEFAULT 0, best_streak INTEGER NOT NULL DEFAULT 0)`,
];
/** All methods are synchronous and run inside the League's transaction. */
export class BattleStore {
  constructor(readonly sql: SqlStorage) {}
  get(id: string): Battle | null { const row = this.sql.exec<StoredBattle>("SELECT data FROM battle_rooms WHERE id=?", id).toArray()[0]; return row ? JSON.parse(row.data) : null; }
  put(b: Battle): void {
    const deadline = this.deadline(b);
    // Read the persisted deadline inside the caller's transaction, after any round changes.
    // UPSERT would consume an AUTOINCREMENT value even for an existing room.
    const existing = this.sql.exec<{ deadline: number | null }>("SELECT deadline FROM battle_rooms WHERE id=?", b.battleId).toArray()[0];
    const data = JSON.stringify(b);
    if (!existing) {
      this.sql.exec("INSERT INTO battle_rooms(id,group_id,p1,p2,state,deadline,data) VALUES(?,?,?,?,?,?,?)", b.battleId, b.groupId, b.p1, b.p2, b.state, deadline, data);
    } else if (existing.deadline === deadline) {
      // Omitting the indexed column avoids its write even when SQLite sees the same value.
      this.sql.exec("UPDATE battle_rooms SET state=?,data=? WHERE id=?", b.state, data, b.battleId);
    } else {
      this.sql.exec("UPDATE battle_rooms SET state=?,deadline=?,data=? WHERE id=?", b.state, deadline, data, b.battleId);
    }
  }
  deadline(b: Battle): number | null {
    if (PRESTART.has(b.state)) return b.expiresAt;
    if (b.state === "REPORTED") return b.reportedAt! + REPORT_MS;
    if (b.state !== "RUNNING") return null;
    const expiry = b.startedAt! + REPORT_MS;
    const round = this.round(b.battleId, b.roundSeq);
    return round?.deadline != null && round.pair === null ? Math.min(expiry, round.deadline) : expiry;
  }
  earliest(): number | null { return this.sql.exec<{ at: number | null }>("SELECT MIN(deadline) AS at FROM battle_rooms WHERE deadline IS NOT NULL").toArray()[0]?.at ?? null; }
  due(now: number): Battle[] { return this.sql.exec<StoredBattle>("SELECT data FROM battle_rooms WHERE deadline<=?", now).toArray().map(r => JSON.parse(r.data)); }
  forTrainer(id: string): Battle[] { return this.sql.exec<StoredBattle>("SELECT data FROM battle_rooms WHERE (p1=? OR p2=?) AND deadline IS NOT NULL", id, id).toArray().map(r => JSON.parse(r.data)); }
  list(id: string, before: number): StoredBattle[] { return this.sql.exec<StoredBattle>("SELECT seq,data FROM battle_rooms WHERE p1=? AND seq<? UNION ALL SELECT seq,data FROM battle_rooms WHERE p2=? AND seq<? ORDER BY seq DESC LIMIT 101", id, before, id, before).toArray(); }
  busy(trainerId: string, instanceId: string, except?: string): boolean {
    const row = this.sql.exec<{ battle_id: string }>("SELECT battle_id FROM battle_locks WHERE trainer_id=? AND instance_id=?", trainerId, instanceId).toArray()[0];
    return !!row && row.battle_id !== except;
  }
  lock(b: Battle): void { for (const side of ["p1", "p2"] as const) this.sql.exec("INSERT INTO battle_locks(trainer_id,instance_id,battle_id) VALUES(?,?,?)", b[side], b.snapshots[side]!.instanceId, b.battleId); }
  unlock(id: string): void { this.sql.exec("DELETE FROM battle_locks WHERE battle_id=?", id); }
  receipt(b: Battle, actor: string, action: string, revision: number, payload: unknown): boolean {
    const row = this.sql.exec<{ payload: string }>("SELECT payload FROM battle_receipts WHERE battle_id=? AND actor=? AND action=? AND revision=?", b.battleId, actor, action, revision).toArray()[0];
    return row?.payload === canonical(payload);
  }
  recordReceipt(b: Battle, actor: string, action: string, revision: number, payload: unknown): void { this.sql.exec("INSERT INTO battle_receipts(battle_id,actor,action,revision,payload) VALUES(?,?,?,?,?)", b.battleId, actor, action, revision, canonical(payload)); }
  round(id: string, seq: number): Round | null { return this.sql.exec<Round>("SELECT battle_id,seq,deadline,p1,p2,pair FROM battle_rounds WHERE battle_id=? AND seq=?", id, seq).toArray()[0] ?? null; }
  journal(id: string): Pair[] { return this.sql.exec<{ pair: string }>("SELECT pair FROM battle_rounds WHERE battle_id=? AND pair IS NOT NULL ORDER BY seq", id).toArray().map(r => JSON.parse(r.pair)); }
}
