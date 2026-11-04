import { it } from "vitest";
import { measureBattle } from "../test/ws/battle-cost-runner";
it("measures 100 actual manual games of 200 rounds with 29-second turns and due alarm delivery", async () => {
  await measureBattle({ name: "manual-200-slow29-batch100", mode: "manual", rounds: 200, games: 100, finish: "match", movingClock: true, stepMs: 29_000, deliverAlarms: true });
}, 180_000);
