import { expect, it } from "vitest";
import { journalBytes } from "../src/battle-relay";
it("serializes relay-v1 without timestamps or engine inputLog fields", () => {
  const journal = [ { roundSeq: 1, p1: { kind: "move" as const, slot: 4 }, p2: { kind: "timeout" as const }, releasedAt: 123 }, { roundSeq: 2, p1: { kind: "policy" as const }, p2: { kind: "policy" as const }, releasedAt: 124 } ];
  expect(journalBytes("battle", "ready", journal)).toBe('["relay-v1","battle","ready",[[1,["move",4],["timeout"]],[2,["policy"],["policy"]]]]');
  expect(journalBytes("battle", "ready", journal.map(r => ({ ...r, releasedAt: 999 })))).toBe(journalBytes("battle", "ready", journal));
});
