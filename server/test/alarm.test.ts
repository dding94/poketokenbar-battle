import { runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import type { League } from "../src/league";
import { DAY, HOUR, dumpTables, expectError, freshIp, joinRaw, freshEmail, leagueStub, setClock, useRealClockAfterEach } from "./helpers";

// Its own file so the League starts with no attempt rows and no pending alarm.

useRealClockAfterEach();

async function pendingAlarm(): Promise<number | null> {
  return runInDurableObject(leagueStub(), (_instance: League, state: DurableObjectState) => state.storage.getAlarm());
}

async function attemptTimes(): Promise<number[]> {
  return ((await dumpTables()).attempts ?? []).map((r) => r.at as number).sort((a, b) => a - b);
}

describe("attempt cleanup alarm", () => {
  it("deletes day-old rows, keeps newer ones and reschedules for them", async () => {
    const t0 = Date.now();
    await setClock(t0);
    expectError(await joinRaw("ZZZZ-ZZZZ-ZZZZ", freshEmail(), freshIp()), 404, "invalid_invite");
    expect(await pendingAlarm()).toBe(t0 + DAY + 1000);

    await setClock(t0 + 12 * HOUR);
    expectError(await joinRaw("ZZZZ-ZZZZ-ZZZZ", freshEmail(), freshIp()), 404, "invalid_invite");
    expect(await attemptTimes()).toEqual([t0, t0 + 12 * HOUR]);

    await setClock(t0 + DAY + 1000);
    expect(await runDurableObjectAlarm(leagueStub())).toBe(true);
    expect(await attemptTimes()).toEqual([t0 + 12 * HOUR]);
    expect(await pendingAlarm()).toBe(t0 + 12 * HOUR + DAY + 1000);

    await setClock(t0 + 12 * HOUR + DAY + 1000);
    expect(await runDurableObjectAlarm(leagueStub())).toBe(true);
    expect(await attemptTimes()).toEqual([]);
    expect(await pendingAlarm()).toBeNull();
  });
});
