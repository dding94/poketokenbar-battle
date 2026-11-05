import { runInDurableObject } from "cloudflare:test";
import { expect, it } from "vitest";
import { BattleStore } from "../src/battle-store";
import { BattleRelay } from "../src/battle-relay";
import type { BattleEffect } from "../src/battle-effects";
import { room } from "./battle-fixture";
import { leagueStub } from "./helpers";

// Cursor counters include index writes. Meter only the operation under test, not fixture reads.
function writes(sql: SqlStorage, operation: () => void): number {
  const original = sql.exec.bind(sql), cursors: SqlStorageCursor<Record<string, SqlStorageValue>>[] = [];
  sql.exec = ((query: string, ...values: SqlStorageValue[]) => {
    const cursor = original(query, ...values); cursors.push(cursor); return cursor;
  }) as typeof sql.exec;
  try { operation(); for (const cursor of cursors) cursor.toArray(); return cursors.reduce((sum, cursor) => sum + cursor.rowsWritten, 0); }
  finally { sql.exec = original; }
}

it("updates room data with one write while preserving creation sequence, participants and list cursor", async () => {
  const f = await room();
  const result = await runInDurableObject(leagueStub(), (_instance, state) => state.storage.transactionSync(() => {
    const sql = state.storage.sql, store = new BattleStore(sql), b = store.get(f.view.battleId)!;
    const original = sql.exec("SELECT seq,group_id,p1,p2,deadline FROM battle_rooms WHERE id=?", b.battleId).toArray()[0]!;
    const sequence = () => sql.exec<{ seq: number }>("SELECT seq FROM sqlite_sequence WHERE name='battle_rooms'").one().seq;
    const beforeSequence = sequence();
    b.confirmed = true;
    const unchangedWrites = writes(sql, () => store.put(b));
    const afterSequence = sequence(), updated = sql.exec("SELECT seq,group_id,p1,p2,deadline FROM battle_rooms WHERE id=?", b.battleId).toArray()[0]!;
    const next = { ...b, battleId: `${b.battleId}-next` }; store.put(next);
    const first = store.list(b.p1, Number.MAX_SAFE_INTEGER), second = store.list(b.p1, first[0]!.seq);
    return { original, updated, unchangedWrites, beforeSequence, afterSequence, newSeq: first[0]!.seq, nextId: JSON.parse(second[0]!.data).battleId, saved: store.get(b.battleId)!.confirmed };
  }));
  expect(result.updated).toEqual(result.original); expect(result.saved).toBe(true);
  expect(result.afterSequence).toBe(result.beforeSequence); expect(result.newSeq).toBe(result.beforeSequence + 1);
  expect(result.nextId).toBe(f.view.battleId);
  expect(result.unchangedWrites).toBe(1);
});

it("updates the deadline index when due time changes and removes it on completion", async () => {
  const f = await room();
  const result = await runInDurableObject(leagueStub(), (_instance, state) => state.storage.transactionSync(() => {
    const sql = state.storage.sql, store = new BattleStore(sql), b = store.get(f.view.battleId)!;
    b.expiresAt += 30_000;
    const changedWrites = writes(sql, () => store.put(b));
    const deadline = sql.exec("SELECT deadline FROM battle_rooms WHERE id=?", b.battleId).one().deadline;
    b.state = "COMPLETED";
    const terminalWrites = writes(sql, () => store.put(b));
    const terminalDeadline = sql.exec("SELECT deadline FROM battle_rooms WHERE id=?", b.battleId).one().deadline;
    const repeatWrites = writes(sql, () => store.put(b));
    return { changedWrites, deadline, expected: b.expiresAt, terminalWrites, terminalDeadline, repeatWrites };
  }));
  expect(result.deadline).toBe(result.expected); expect(result.terminalDeadline).toBeNull();
  expect(result.changedWrites).toBeLessThanOrEqual(3); expect(result.terminalWrites).toBeLessThanOrEqual(2);
  expect(result.repeatWrites).toBe(1);
});

it.each(["p1", "p2"] as const)("stores second %s choice and pair in one write with private first choice and free retries", async second => {
  const f = await room();
  const result = await runInDurableObject(leagueStub(), (_instance, state) => state.storage.transactionSync(() => {
    const sql = state.storage.sql, store = new BattleStore(sql), relay = new BattleRelay(store), b = store.get(f.view.battleId)!;
    b.state = "RUNNING"; b.startedAt = 1000;
    const effects: BattleEffect[] = []; relay.open(b, 1000, effects); store.put(b);
    const first = second === "p1" ? "p2" : "p1";
    const firstWrites = writes(sql, () => { expect(relay.choice(b, first, 1, "move 3", 1001, effects)).toEqual({ ok: true, value: true }); store.put(b); });
    const privateRound = store.round(b, 1), privateJournal = store.journal(b), privateEffects = [...effects];
    const secondWrites = writes(sql, () => { expect(relay.choice(b, second, 1, "move 2", 1002, effects)).toEqual({ ok: true, value: true }); store.put(b); });
    const retryWrites = writes(sql, () => expect(relay.choice(b, second, 1, "move 2", 1003, effects)).toEqual({ ok: true, value: false }));
    const conflict = relay.choice(b, second, 1, "move 4", 1003, effects);
    return { secondTrainer: b[second], firstWrites, secondWrites, retryWrites, privateRound, privateJournal, privateEffects, conflict, journal: store.journal(b), effects };
  }));
  expect(result.privateRound![second]).toBeNull(); expect(result.privateRound!.pair).toBeNull();
  expect(result.privateJournal).toEqual([]); expect(result.privateEffects).toEqual([{ recipients: [result.secondTrainer], message: expect.objectContaining({ type: "battle_changed", opponentSubmitted: true }) }]);
  expect(result.firstWrites).toBe(1); expect(result.secondWrites).toBe(1); expect(result.retryWrites).toBe(0);
  expect(result.conflict).toMatchObject({ ok: false }); expect(result.journal).toHaveLength(1); expect(result.effects).toHaveLength(2); // the first-choice signal, then the pair
  expect(result.journal[0]).toMatchObject({ [second]: { kind: "move", slot: 2 }, releasedAt: 1002 });
});

it("stores auto round and policy pair together and does not write on duplicate advance", async () => {
  const f = await room("auto");
  const result = await runInDurableObject(leagueStub(), (_instance, state) => state.storage.transactionSync(() => {
    const sql = state.storage.sql, store = new BattleStore(sql), relay = new BattleRelay(store), b = store.get(f.view.battleId)!;
    b.state = "RUNNING"; b.startedAt = 1000;
    const effects: BattleEffect[] = []; store.put(b);
    const firstWrites = writes(sql, () => { relay.open(b, 1000, effects); store.put(b); });
    const nextWrites = writes(sql, () => { expect(relay.advance(b, 1, 1001, effects)).toEqual({ ok: true, value: true }); store.put(b); });
    const retryWrites = writes(sql, () => expect(relay.advance(b, 1, 1002, effects)).toEqual({ ok: true, value: false }));
    return { firstWrites, nextWrites, retryWrites, effects, journal: store.journal(b), round: store.round(b, 2) };
  }));
  expect(result.firstWrites).toBe(1); expect(result.nextWrites).toBe(1); expect(result.retryWrites).toBe(0);
  expect(result.journal).toHaveLength(2); expect(result.effects).toHaveLength(2);
  expect(result.journal[1]).toEqual({ roundSeq: 2, p1: { kind: "policy" }, p2: { kind: "policy" }, releasedAt: 1001 });
  expect(result.round).toMatchObject({ deadline: null, p1: null, p2: null });
});
