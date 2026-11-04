import { type Battle, type Pair, type RelayToken, type Round } from "./battle-store";
export type PackedPair = [number, number, number];
export interface PackedRelay { pairs: PackedPair[]; current: { deadline: number | null; p1: number | null; p2: number | null } | null }
export const emptyRelay = (): PackedRelay => ({ pairs: [], current: null });
const encode = (token: RelayToken): number => token.kind === "move" ? token.slot : token.kind === "timeout" ? 0 : 5;
const decode = (code: number): RelayToken => code === 0 ? { kind: "timeout" } : code === 5 ? { kind: "policy" } : { kind: "move", slot: code };
export function packPair(b: Battle, pair: Pair): PackedPair {
  return [encode(pair.p1), encode(pair.p2), pair.releasedAt - b.startedAt!];
}
export function unpackPair(b: Battle, tuple: PackedPair, index: number): Pair {
  return { roundSeq: index + 1, p1: decode(tuple[0]), p2: decode(tuple[1]), releasedAt: b.startedAt! + tuple[2] };
}
function invalid(): never { throw new Error("invalid legacy relay"); }
function slot(value: unknown): value is number | null { return value === null || Number.isInteger(value) && Number(value) >= 1 && Number(value) <= 4; }
function token(value: RelayToken, saved: number | null, auto: boolean): boolean {
  return !!value && (auto ? value.kind === "policy" && saved === null : saved === null ? value.kind === "timeout" : value.kind === "move" && value.slot === saved);
}
/** Called only within the schema migration transaction. No report/receipt rows are rebuilt. */
export function migratePackedBattles(sql: SqlStorage): void {
  sql.exec("ALTER TABLE battle_rooms ADD COLUMN turn_deadline INTEGER");
  sql.exec("CREATE INDEX battle_running ON battle_rooms(seq) WHERE state='RUNNING'");
  if (sql.exec("SELECT 1 FROM battle_rounds r WHERE NOT EXISTS (SELECT 1 FROM battle_rooms b WHERE b.id=r.battle_id) LIMIT 1").toArray().length) invalid();
  for (const row of sql.exec<{ id: string; data: string }>("SELECT id,data FROM battle_rooms ORDER BY seq").toArray()) {
    const b: Battle = JSON.parse(row.data);
    if (b.battleId !== row.id || !Number.isInteger(b.roundSeq) || b.roundSeq < 0 || b.roundSeq > 200) invalid();
    const rounds = sql.exec<Round>("SELECT battle_id,seq,deadline,p1,p2,pair FROM battle_rounds WHERE battle_id=? ORDER BY seq", row.id).toArray();
    if (rounds.length !== b.roundSeq || rounds.length && !Number.isSafeInteger(b.startedAt)) invalid();
    b.relay = emptyRelay();
    for (const [index, round] of rounds.entries()) {
      if (round.seq !== index + 1 || !slot(round.p1) || !slot(round.p2) || (round.deadline !== null && !Number.isSafeInteger(round.deadline))) invalid();
      if (round.pair === null) {
        if (round.seq !== b.roundSeq || b.mode !== "manual" || round.deadline === null || round.p1 !== null && round.p2 !== null) invalid();
        b.relay.current = { deadline: round.deadline, p1: round.p1, p2: round.p2 };
      } else {
        const pair: Pair = JSON.parse(round.pair);
        if (pair.roundSeq !== round.seq || !Number.isSafeInteger(pair.releasedAt) || !token(pair.p1, round.p1, b.mode === "auto") || !token(pair.p2, round.p2, b.mode === "auto")) invalid();
        const packed = packPair(b, pair);
        if (!Number.isSafeInteger(packed[2]) || b.startedAt! + packed[2] !== pair.releasedAt) invalid();
        b.relay.pairs.push(packed);
      }
    }
    const deadline = b.state === "PENDING" || b.state === "ACCEPTED" || b.state === "READY" ? b.expiresAt : b.state === "RUNNING" ? b.startedAt! + 72 * 3600_000 : b.state === "REPORTED" ? b.reportedAt! + 72 * 3600_000 : null;
    sql.exec("UPDATE battle_rooms SET data=?,deadline=?,turn_deadline=? WHERE id=?", JSON.stringify(b), deadline, b.state === "RUNNING" ? b.relay.current?.deadline ?? null : null, row.id);
  }
  sql.exec("DROP TABLE battle_rounds");
  sql.exec("DELETE FROM meta WHERE key='attempts_alarm_at'");
}
