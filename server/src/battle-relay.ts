import type { BattleEffect } from "./battle-effects";
import { BattleStore, TURN_MS, type Battle, type Pair, type RelayToken, type Round } from "./battle-store";
import { fail, ok, type Result } from "./contract";
import type { Side } from "./battle-input";
/** Closed relay journal: user input can only become a move slot, never simulator text. */
export class BattleRelay {
  constructor(private readonly store: BattleStore) {}
  open(b: Battle, now: number, after: BattleEffect[]): void {
    b.roundSeq++;
    if (b.mode === "auto") {
      const pair: Pair = { roundSeq: b.roundSeq, p1: { kind: "policy" }, p2: { kind: "policy" }, releasedAt: now };
      this.store.sql.exec("INSERT INTO battle_rounds(battle_id,seq,pair) VALUES(?,?,?)", b.battleId, b.roundSeq, JSON.stringify(pair));
      this.publish(b, pair, after);
    } else {
      this.store.sql.exec("INSERT INTO battle_rounds(battle_id,seq,deadline) VALUES(?,?,?)", b.battleId, b.roundSeq, now + TURN_MS);
    }
  }
  choice(b: Battle, side: Side, seq: number, choice: string, now: number, after: BattleEffect[]): Result<boolean> {
    if (b.mode !== "manual") return fail("invalid_state");
    const round = this.store.round(b.battleId, seq), slot = Number(choice.slice(-1));
    // A saved choice is immutable, including retries after publication/completion.
    if (round && round[side] !== null) return round[side] === slot ? ok(false) : fail("choice_conflict");
    if (b.state !== "RUNNING") return fail("invalid_state");
    if (!round || round.seq !== b.roundSeq || round.pair !== null) return fail("stale_round");
    round[side] = slot;
    if (round.p1 !== null && round.p2 !== null) { this.release(b, round, now, after, side); return ok(true); }
    this.store.sql.exec(`UPDATE battle_rounds SET ${side}=? WHERE battle_id=? AND seq=?`, slot, b.battleId, seq);
    return ok(false); // No room update, notification, or peer submission signal.
  }
  advance(b: Battle, seq: number, now: number, after: BattleEffect[]): Result<boolean> {
    if (b.state !== "RUNNING") return fail("invalid_state");
    const processed = this.store.round(b.battleId, seq);
    if (!processed?.pair || seq > b.roundSeq) return fail("stale_round");
    if (seq < b.roundSeq) return ok(false);
    if (seq === 200) return fail("invalid_state");
    this.open(b, now, after); return ok(true);
  }
  timeout(b: Battle, now: number, after: BattleEffect[]): boolean {
    const round = this.store.round(b.battleId, b.roundSeq);
    if (!round || round.pair !== null || round.deadline === null || now < round.deadline) return false;
    this.release(b, round, round.deadline, after); return true;
  }
  private release(b: Battle, round: Round, at: number, after: BattleEffect[], side?: Side): void {
    const token = (slot: number | null): RelayToken => slot === null ? { kind: "timeout" } : { kind: "move", slot };
    const pair: Pair = { roundSeq: round.seq, p1: token(round.p1), p2: token(round.p2), releasedAt: at };
    if (side) this.store.sql.exec(`UPDATE battle_rounds SET ${side}=?,pair=? WHERE battle_id=? AND seq=? AND pair IS NULL`, round[side], JSON.stringify(pair), b.battleId, round.seq);
    else this.store.sql.exec("UPDATE battle_rounds SET pair=? WHERE battle_id=? AND seq=? AND pair IS NULL", JSON.stringify(pair), b.battleId, round.seq);
    this.publish(b, pair, after);
  }
  private publish(b: Battle, pair: Pair, after: BattleEffect[]): void {
    after.push({ recipients: [b.p1, b.p2], message: { type: "battle_round", battleId: b.battleId, pair } });
  }
}
/** Appendix D canonical bytes. releasedAt deliberately does not affect the comparison. */
export function journalBytes(battleId: string, readyToken: string, journal: Pair[]): string {
  const token = (v: RelayToken) => v.kind === "move" ? ["move", v.slot] : [v.kind];
  return JSON.stringify(["relay-v1", battleId, readyToken, journal.map(r => [r.roundSeq, token(r.p1), token(r.p2)])]);
}
