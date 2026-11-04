import { packPair } from "./battle-packing";
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
      b.relay.pairs.push(packPair(b, pair)); b.relay.current = null;
      this.publish(b, pair, after);
    } else {
      b.relay.current = { deadline: now + TURN_MS, p1: null, p2: null };
    }
  }
  choice(b: Battle, side: Side, seq: number, choice: string, now: number, after: BattleEffect[]): Result<boolean> {
    if (b.mode !== "manual") return fail("invalid_state");
    const round = this.store.round(b, seq), slot = Number(choice.slice(-1));
    // A saved choice is immutable, including retries after publication/completion.
    if (round && round[side] !== null) return round[side] === slot ? ok(false) : fail("choice_conflict");
    if (b.state !== "RUNNING") return fail("invalid_state");
    if (!round || round.seq !== b.roundSeq || round.pair !== null) return fail("stale_round");
    round[side] = slot;
    if (round.p1 !== null && round.p2 !== null) { this.release(b, round, now, after); return ok(true); }
    b.relay.current![side] = slot;
    return ok(true); // Persist privately, without notification or peer submission signal.
  }
  advance(b: Battle, seq: number, now: number, after: BattleEffect[]): Result<boolean> {
    if (b.state !== "RUNNING") return fail("invalid_state");
    const processed = this.store.round(b, seq);
    if (!processed?.pair || seq > b.roundSeq) return fail("stale_round");
    if (seq < b.roundSeq) return ok(false);
    if (seq === 200) return fail("invalid_state");
    this.open(b, now, after); return ok(true);
  }
  timeout(b: Battle, now: number, after: BattleEffect[]): boolean {
    const round = this.store.round(b, b.roundSeq);
    if (!round || round.pair !== null || round.deadline === null || now < round.deadline) return false;
    this.release(b, round, round.deadline, after); return true;
  }
  private release(b: Battle, round: Round, at: number, after: BattleEffect[]): void {
    const token = (slot: number | null): RelayToken => slot === null ? { kind: "timeout" } : { kind: "move", slot };
    const pair: Pair = { roundSeq: round.seq, p1: token(round.p1), p2: token(round.p2), releasedAt: at };
    b.relay.pairs.push(packPair(b, pair)); b.relay.current = null;
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
