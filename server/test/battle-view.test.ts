import { describe, expect, it } from "vitest";
import { battleView } from "../src/battle-view";
import type { Battle, BattleStore, Round } from "../src/battle-store";

/** The projection reads the store for the current round and the journal; nothing else of the store matters here. */
function view(current: Partial<Round> | null, viewer: "p1" | "p2", state: Battle["state"] = "RUNNING") {
  const snapshot = { instanceId: "i", set: {}, public: { stats: { hp: 100 } }, hp: 100 };
  const b = { battleId: "bt_x", groupId: "g", p1: "one", p2: "two", state, revision: 3, mode: "manual", createdAt: 1, expiresAt: 2,
    startedAt: 3, reportedAt: null, confirmed: true, config: {}, roundSeq: 2, result: null, reason: null, rematchOf: null,
    snapshots: { p1: snapshot, p2: snapshot } } as unknown as Battle;
  const store = { round: () => current === null ? null : { battle_id: "bt_x", seq: 2, deadline: 99, p1: null, p2: null, pair: null, ...current }, journal: () => [] } as unknown as BattleStore;
  return battleView(store, b, viewer === "p1" ? "one" : "two") as Record<string, unknown>;
}

describe("opponentSubmitted", () => {
  it("tells a viewer whose opponent has chosen, and only that viewer", () => {
    expect(view({ p1: 3 }, "p2").opponentSubmitted).toBe(true);
    expect(view({ p1: 3 }, "p1").opponentSubmitted).toBe(false);
    expect(view({ p2: 1 }, "p1").opponentSubmitted).toBe(true);
    expect(view({ p2: 1 }, "p2").opponentSubmitted).toBe(false);
  });

  it("is false before anyone chose, once the round is released, and with no current round", () => {
    expect(view({}, "p1").opponentSubmitted).toBe(false);
    expect(view({}, "p2").opponentSubmitted).toBe(false);
    expect(view({ p1: 3, p2: 1, pair: "{}" }, "p1").opponentSubmitted).toBe(false);
    expect(view({ p1: 3, p2: 1, pair: "{}" }, "p2").opponentSubmitted).toBe(false);
    expect(view(null, "p2", "PENDING").opponentSubmitted).toBe(false);
  });

  it("never carries the opponent's slot or choice in any form", () => {
    // Whatever slot the opponent picked, the viewer's whole view is byte-identical: only the fact is in it.
    const slots = [1, 2, 3, 4].map(slot => JSON.stringify(view({ p1: slot }, "p2")));
    expect(new Set(slots).size).toBe(1);
    const shown = view({ p1: 3 }, "p2");
    expect(shown.ownChoice).toBeNull();
    expect(JSON.stringify(shown)).not.toContain("move 3");
    // Exactly one key more than before, and no peer-choice field next to it.
    expect(Object.keys(shown).sort()).toEqual(["battleId", "state", "revision", "mode", "p1", "p2", "createdAt", "expiresAt", "startedAt",
      "reportedAt", "confirmed", "config", "roundSeq", "deadline", "ownChoice", "journal", "result", "reason", "rematchOf", "opponentSubmitted"].sort());
  });

  it("keeps the viewer's own choice private to the viewer", () => {
    expect(view({ p1: 3 }, "p1").ownChoice).toBe("move 3");
    expect(view({ p1: 3 }, "p2").ownChoice).toBeNull();
  });
});
