import { describe, expect, it } from "vitest";
import { battleChanged } from "../src/battle-effects";
import type { Battle } from "../src/battle-store";

describe("public round notifications", () => {
  it("includes only public round metadata and preserves the actual opened deadline", () => {
    const room = { battleId: "bt_notice", p1: "one", p2: "two", state: "RUNNING", revision: 2,
      roundSeq: 7, relay: { pairs: [], current: { deadline: 123456, p1: 4, p2: null } } } as unknown as Battle;
    expect(battleChanged(room)).toEqual({ recipients: ["one", "two"], message: {
      type: "battle_changed", battleId: "bt_notice", state: "RUNNING", revision: 2, roundSeq: 7, deadline: 123456 } });
  });
  it("does not publish an open deadline for a void retaining a private unpaired turn", () => {
    const room = { battleId: "bt_notice", p1: "one", p2: "two", state: "VOID", revision: 2,
      roundSeq: 7, relay: { pairs: [], current: { deadline: 123456, p1: 4, p2: null } } } as unknown as Battle;
    expect(battleChanged(room).message).toMatchObject({ roundSeq: 7, deadline: null });
  });
});
