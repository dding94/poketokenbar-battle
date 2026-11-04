import { it } from "vitest";
import { measureBattle } from "./battle-cost-runner";
const scenarios = [
  { name: "manual-25", mode: "manual", rounds: 25, finish: "match" },
  { name: "manual-25-batch10", mode: "manual", rounds: 25, finish: "match", games: 10 },
  { name: "manual-200", mode: "manual", rounds: 200, finish: "match" },
  { name: "manual-25-moving-clock", mode: "manual", rounds: 25, finish: "match", movingClock: true },
  { name: "manual-25-dual-advance-retries", mode: "manual", rounds: 25, finish: "match", movingClock: true, retries: true },
  { name: "manual-200-batch10", mode: "manual", rounds: 200, finish: "match", games: 10, movingClock: true },
  { name: "auto-25", mode: "auto", rounds: 25, finish: "match" },
  { name: "timeout-25", mode: "manual", rounds: 25, finish: "match", timeout: true },
  { name: "mismatch", mode: "manual", rounds: 1, finish: "mismatch" },
  { name: "missing-report", mode: "manual", rounds: 1, finish: "missing" },
  { name: "zero-report", mode: "auto", rounds: 1, finish: "zero" },
  { name: "reconnect", mode: "manual", rounds: 1, finish: "match", reconnect: true },
  { name: "manual-200-slow29", mode: "manual", rounds: 200, finish: "match", movingClock: true, stepMs: 29_000, deliverAlarms: true },
  { name: "manual-25-app-read-fanout", mode: "manual", rounds: 25, finish: "match", movingClock: true, appReads: true },
] as const;
it.each(scenarios)("local workerd cost: $name", measureBattle, 30_000);
