import { GroupAccess, type Actor } from "./access";
import { canonical, POLICY_VERSION, RELAY_VERSION, RULES_VERSION, type BattleAction, type BattleInput, type Side } from "./battle-input";
import { ACTIVE, BattleStore, CHALLENGE_MS, PRESTART, REPORT_MS, type Battle } from "./battle-store";
import { fail, ok, type Result } from "./contract";
import type { Realtime } from "./realtime";
export interface BattleEffect { recipients: string[]; groupId?: string; message: Record<string, unknown> }
export function battleChanged(b: Battle): BattleEffect { return { recipients: [b.p1, b.p2], message: { type: "battle_changed", battleId: b.battleId, state: b.state, revision: b.revision } }; }
export class Battles {
  readonly store: BattleStore;
  constructor(sql: SqlStorage, private readonly access: GroupAccess, private readonly realtime: Realtime) { this.store = new BattleStore(sql); }
  dispatch(actor: Actor, id: string | null, action: BattleAction | "get" | "list", input: BattleInput, now: number, after: BattleEffect[], before = Number.MAX_SAFE_INTEGER): Result<unknown> {
    if (action === "list") {
      const rows = this.store.list(actor.trainer.id, before), page = rows.slice(0, 100);
      return ok({ battles: page.map(r => this.view(JSON.parse(r.data), actor.trainer.id)), before: rows.length > 100 ? String(page[99]!.seq) : null });
    }
    if (action === "create") return this.create(actor, input, now, after);
    const b = id ? this.store.get(id) : null;
    if (!b || b.groupId !== actor.groupId || (b.p1 !== actor.trainer.id && b.p2 !== actor.trainer.id)) return fail("not_found");
    if (action === "get") return ok(this.view(b, actor.trainer.id));
    const side: Side = b.p1 === actor.trainer.id ? "p1" : "p2";
    // Successful update/accept retry uses its ORIGINAL revision, before stale checks.
    if ((action === "update" || action === "accept") && this.store.receipt(b, actor.trainer.id, action, input.revision!, input)) return ok(this.view(b, actor.trainer.id));
    if (input.revision !== undefined && input.revision !== b.revision) return fail("stale_revision");
    if (action === "decline" && b.state === "DECLINED" && side === "p2" || action === "cancel" && b.state === "CANCELLED") return ok(this.view(b, actor.trainer.id));
    if (!ACTIVE.has(b.state)) return fail("invalid_state");
    let changed = true;
    if (action === "update") {
      if (b.state !== "PENDING" || side !== "p1") return fail("invalid_state");
      if (this.store.busy(b.p1, input.snapshot!.instanceId)) return fail("instance_busy");
      changed = canonical(b.snapshots.p1) !== canonical(input.snapshot);
      this.store.recordReceipt(b, actor.trainer.id, action, input.revision!, input);
      if (changed) { b.snapshots.p1 = input.snapshot!; b.revision++; b.confirmed = false; b.ready = {}; }
    } else if (action === "accept") {
      if (b.state !== "PENDING" || side !== "p2") return fail("invalid_state");
      if (this.store.busy(b.p2, input.snapshot!.instanceId)) return fail("instance_busy");
      this.store.recordReceipt(b, actor.trainer.id, action, input.revision!, input);
      b.snapshots.p2 = input.snapshot!; b.revision++; b.state = "ACCEPTED";
    } else if (action === "confirm") {
      if (b.state !== "ACCEPTED" || side !== "p1") return fail("invalid_state");
      changed = !b.confirmed; b.confirmed = true;
    } else if (action === "decline" || action === "cancel") {
      if (action === "decline" ? b.state !== "PENDING" || side !== "p2" : !PRESTART.has(b.state)) return fail("invalid_state");
      b.state = action === "decline" ? "DECLINED" : "CANCELLED"; this.store.unlock(b.battleId);
    } else if (action === "ready") {
      const result = this.ready(b, side, input); if (!result.ok) return result; changed = result.value;
    } else if (action === "start") {
      const result = this.start(b, side, input, now); if (!result.ok) return result; changed = result.value;
    } else return fail("invalid_state");
    if (changed) { this.store.put(b); after.push(battleChanged(b)); }
    return ok(this.view(b, actor.trainer.id));
  }
  private create(actor: Actor, input: BattleInput, now: number, after: BattleEffect[]): Result<unknown> {
    const payload = canonical(input);
    const previous = this.store.sql.exec<{ payload: string; battle_id: string }>("SELECT payload,battle_id FROM battle_requests WHERE trainer_id=? AND request_id=?", actor.trainer.id, input.requestId!).toArray()[0];
    if (previous) return previous.payload === payload ? ok(this.view(this.store.get(previous.battle_id)!, actor.trainer.id)) : fail("idempotency_conflict");
    const target = this.access.target(actor, input.targetTrainerId!, { activeOnly: true }); if (!target.ok) return target;
    if (this.store.busy(actor.trainer.id, input.snapshot!.instanceId)) return fail("instance_busy");
    const b: Battle = { battleId: `bt_${crypto.randomUUID().replaceAll("-", "")}`, groupId: actor.groupId, p1: actor.trainer.id, p2: target.value.id, state: "PENDING", revision: 1, mode: input.mode!, createdAt: now, expiresAt: now + CHALLENGE_MS, startedAt: null, reportedAt: null, confirmed: false, snapshots: { p1: input.snapshot!, p2: null }, ready: {}, starts: {}, config: null, roundSeq: 0, result: null, reason: null, rematchOf: null };
    this.store.put(b);
    this.store.sql.exec("INSERT INTO battle_requests(trainer_id,request_id,payload,battle_id) VALUES(?,?,?,?)", actor.trainer.id, input.requestId!, payload, b.battleId);
    after.push(battleChanged(b)); return ok(this.view(b, actor.trainer.id));
  }
  private ready(b: Battle, side: Side, input: BattleInput): Result<boolean> {
    if (!b.confirmed) return fail("not_ready");
    if (b.state !== "ACCEPTED" && b.state !== "READY") return fail("invalid_state");
    if (this.realtime.connectionId(b[side]) !== input.connectionId) return fail("not_ready");
    if (input.rulesVersion !== RULES_VERSION || input.policyVersion !== POLICY_VERSION) return fail("version_mismatch");
    const other: Side = side === "p1" ? "p2" : "p1";
    const peer = b.ready[other];
    if (b.config && b.config.engineHash !== input.engineHash || peer && peer.connectionId === this.realtime.connectionId(b[other]) && peer.engineHash !== input.engineHash) return fail("engine_mismatch");
    if (this.store.busy(b[side], b.snapshots[side]!.instanceId, b.battleId)) return fail("instance_busy");
    if (b.config) return ok(false); // Immutable once frozen, even across reconnects.
    const both = peer && peer.connectionId === this.realtime.connectionId(b[other]);
    if (both && this.store.busy(b[other], b.snapshots[other]!.instanceId, b.battleId)) return fail("instance_busy");
    if (b.ready[side]?.connectionId === input.connectionId && !both) return ok(false);
    b.ready[side] = { connectionId: input.connectionId!, engineHash: input.engineHash! };
    if (both) {
      const seed = [...crypto.getRandomValues(new Uint16Array(4))], policySeed = crypto.getRandomValues(new Uint32Array(1))[0]!;
      b.config = { readyToken: crypto.randomUUID(), engineHash: input.engineHash!, rulesVersion: RULES_VERSION, policyVersion: POLICY_VERSION, relayVersion: RELAY_VERSION, seed, policySeed, p1: { name: "p1", set: b.snapshots.p1.set, hp: b.snapshots.p1.hp, policy: "standard" }, p2: { name: "p2", set: b.snapshots.p2!.set, hp: b.snapshots.p2!.hp, policy: "standard" } };
      this.store.lock(b); b.state = "READY";
    }
    return ok(true);
  }
  private start(b: Battle, side: Side, input: BattleInput, now: number): Result<boolean> {
    if (this.realtime.connectionId(b[side]) !== input.connectionId) return fail("not_ready");
    if (b.state !== "READY" && b.state !== "RUNNING") return fail("invalid_state");
    if (!b.config || input.readyToken !== b.config.readyToken) return fail("not_ready");
    if (input.engineHash !== b.config.engineHash) return fail("engine_mismatch");
    if (b.state === "RUNNING" || b.starts[side] === input.connectionId) return ok(false);
    b.starts[side] = input.connectionId!;
    if (b.starts.p1 === this.realtime.connectionId(b.p1) && b.starts.p2 === this.realtime.connectionId(b.p2)) { b.state = "RUNNING"; b.startedAt = now; }
    return ok(true);
  }
  expire(now: number, after: BattleEffect[]): void {
    for (const b of this.store.due(now)) {
      if (PRESTART.has(b.state)) { b.state = "EXPIRED"; }
      else if (b.state === "RUNNING" && now >= b.startedAt! + REPORT_MS || b.state === "REPORTED" && now >= b.reportedAt! + REPORT_MS) { b.state = "VOID"; b.reason = "report_timeout"; }
      else continue;
      this.store.unlock(b.battleId); this.store.put(b); after.push(battleChanged(b));
    }
  }
  participantLeft(id: string, after: BattleEffect[]): void {
    for (const b of this.store.forTrainer(id)) { b.state = PRESTART.has(b.state) ? "CANCELLED" : "VOID"; b.reason = "participant_left"; this.store.unlock(b.battleId); this.store.put(b); after.push(battleChanged(b)); }
  }
  view(b: Battle, viewer: string): unknown {
    const player = (side: Side) => {
      const s = b.snapshots[side]; if (!s) return { trainerId: b[side] };
      return b.config || viewer === b[side] ? { trainerId: b[side], snapshot: s } : { trainerId: b[side], public: s.public, hpPercent: s.hp / s.public.stats.hp * 100 };
    };
    const current = this.store.round(b.battleId, b.roundSeq), side: Side = viewer === b.p1 ? "p1" : "p2";
    return { battleId: b.battleId, state: b.state, revision: b.revision, mode: b.mode, p1: player("p1"), p2: player("p2"), createdAt: b.createdAt, expiresAt: b.expiresAt, startedAt: b.startedAt, reportedAt: b.reportedAt, confirmed: b.confirmed, config: b.config, roundSeq: b.roundSeq, deadline: current?.pair === null ? current.deadline : null, ownChoice: current?.pair === null && current[side] !== null ? `move ${current[side]}` : null, journal: this.store.journal(b.battleId), result: b.result, reason: b.reason, rematchOf: b.rematchOf };
  }
}
