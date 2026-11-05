import { describe, expect, it } from "vitest";
import { action } from "../battle-fixture";
import { closeSocketsAfterAll } from "./socket";
import { release, running } from "./battle-session";
closeSocketsAfterAll();
describe("public notification deadlines", () => {
  it("tells only the opponent, once and without the slot, that a first choice is in", async () => {
    const f = await running(), id = f.view.battleId;
    await f.a.socket.sync(); await f.b.socket.sync();
    const first = await action(f.p1, id, "choices", { roundSeq: 1, choice: "move 1" });
    // D7: exactly one existing-type frame reaches the other seat; sync() fails if anything else is unread before the pong.
    const seen = await f.b.socket.next(); await f.b.socket.sync();
    expect(seen).toEqual({ v: 1, type: "battle_changed", battleId: id, state: "RUNNING", revision: f.view.revision, roundSeq: 1, deadline: first.body.deadline, opponentSubmitted: true });
    expect(Object.keys(seen).sort()).toEqual(["v", "type", "battleId", "state", "revision", "roundSeq", "deadline", "opponentSubmitted"].sort());
    expect(JSON.stringify(seen)).not.toMatch(/slot|choice|move/);
    await f.a.socket.sync(); // the chooser hears nothing
    // A retry of the stored choice is not a new first choice.
    expect((await action(f.p1, id, "choices", { roundSeq: 1, choice: "move 1" })).status).toBe(200);
    await f.a.socket.sync(); await f.b.socket.sync();
    // The second choice releases the pair for both seats and adds no signal of its own.
    expect((await action(f.p2, id, "choices", { roundSeq: 1, choice: "move 2" })).status).toBe(200);
    for (const socket of [f.a.socket, f.b.socket]) { expect((await socket.next()).type).toBe("battle_round"); await socket.sync(); }
  });
  it("sends the same next-round deadline as HTTP and nothing else with it", async () => {
    const f = await running(), id = f.view.battleId;
    await f.a.socket.sync(); await f.b.socket.sync();
    await release(f);
    for (const socket of [f.a.socket, f.b.socket]) {
      const released = await socket.until(m => m.type === "battle_round");
      expect(Object.keys(released).sort()).toEqual(["v", "type", "battleId", "pair"].sort());
    }
    const next = await action(f.p1, id, "advance", { processedRoundSeq: 1 });
    for (const socket of [f.a.socket, f.b.socket]) {
      const opened = await socket.until(m => m.type === "battle_changed" && m.roundSeq === 2);
      expect(Object.keys(opened).sort()).toEqual(["v", "type", "battleId", "state", "revision", "roundSeq", "deadline"].sort());
      expect(opened.deadline).toBe(next.body.deadline);
      expect(opened.deadline).toBeTypeOf("number");
    }
  });
});
