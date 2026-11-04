import { describe, expect, it } from "vitest";
import { action } from "../battle-fixture";
import { closeSocketsAfterAll } from "./socket";
import { release, running } from "./battle-session";
closeSocketsAfterAll();
describe("public notification deadlines", () => {
  it("sends the same next-round deadline as HTTP and never emits a first-choice signal", async () => {
    const f = await running(), id = f.view.battleId;
    await f.a.socket.sync(); await f.b.socket.sync();
    const before = f.b.socket.frames.length;
    await action(f.p1, id, "choices", { roundSeq: 1, choice: "move 1" });
    await f.b.socket.sync();
    const after = f.b.socket.frames.slice(before).filter(frame => frame !== "pong");
    expect(after).toEqual([]);
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
