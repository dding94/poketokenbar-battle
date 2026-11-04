import { type PackedRelay, unpackPair } from "./battle-packing";
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
  relay: PackedRelay; mode: BattleMode; createdAt: number; expiresAt: number; startedAt: number | null; reportedAt: number | null;
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
  constructor(readonly sql: SqlStorage, private readonly changedDeadline: (at: number | null) => void = () => {}) {}
  get(id: string): Battle | null { const row = this.sql.exec<StoredBattle>("SELECT data FROM battle_rooms WHERE id=?", id).toArray()[0]; return row ? JSON.parse(row.data) : null; }
  put(b: Battle): void {
    const deadline = this.lifecycleDeadline(b), turn = b.state === "RUNNING" ? b.relay.current?.deadline ?? null : null;
    const existing = this.sql.exec<{ deadline: number | null; state: string }>("SELECT state,deadline FROM battle_rooms WHERE id=?", b.battleId).toArray()[0];
    const data = JSON.stringify(b);
    if (!existing) {
      this.sql.exec("INSERT INTO battle_rooms(id,group_id,p1,p2,state,deadline,turn_deadline,data) VALUES(?,?,?,?,?,?,?,?)", b.battleId, b.groupId, b.p1, b.p2, b.state, deadline, turn, data);
    } else {
      // Never mention an unchanged indexed column, including partial-index predicates.
      const columns = ["data=?", "turn_deadline=?"], values: SqlStorageValue[] = [data, turn];
      if (existing.state !== b.state) { columns.push("state=?"); values.push(b.state); }
      if (existing.deadline !== deadline) { columns.push("deadline=?"); values.push(deadline); }
      this.sql.exec(`UPDATE battle_rooms SET ${columns.join(",")} WHERE id=?`, ...values, b.battleId);
    }
    this.changedDeadline(turn === null ? deadline : deadline === null ? turn : Math.min(turn, deadline));
  }
  lifecycleDeadline(b: Battle): number | null {
    if (PRESTART.has(b.state)) return b.expiresAt;
    if (b.state === "REPORTED") return b.reportedAt! + REPORT_MS;
    return b.state === "RUNNING" ? b.startedAt! + REPORT_MS : null;
  }
  earliest(): number | null {
    const life = this.sql.exec<{ at: number | null }>("SELECT MIN(deadline) AS at FROM battle_rooms WHERE deadline IS NOT NULL").one().at;
    const turn = this.sql.exec<{ at: number | null }>("SELECT MIN(turn_deadline) AS at FROM battle_rooms WHERE state='RUNNING'").one().at;
    return life === null ? turn : turn === null ? life : Math.min(life, turn);
  }
  due(now: number): Battle[] {
    return this.sql.exec<StoredBattle>("SELECT data FROM battle_rooms WHERE deadline<=? UNION ALL SELECT data FROM battle_rooms WHERE state='RUNNING' AND turn_deadline<=? AND deadline>?", now, now, now).toArray().map(r => JSON.parse(r.data));
  }
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
  round(b: Battle, seq: number): Round | null {
    const tuple = b.relay.pairs[seq - 1];
    if (tuple) {
      const pair = unpackPair(b, tuple, seq - 1);
      return { battle_id: b.battleId, seq, deadline: null, p1: pair.p1.kind === "move" ? pair.p1.slot : null, p2: pair.p2.kind === "move" ? pair.p2.slot : null, pair: JSON.stringify(pair) };
    }
    return seq === b.roundSeq && b.relay.current ? { battle_id: b.battleId, seq, ...b.relay.current, pair: null } : null;
  }
  journal(b: Battle): Pair[] { return b.relay.pairs.map((tuple, index) => unpackPair(b, tuple, index)); }
}
