import { describe, expect, it } from "vitest";
import {
  BACKOFF_CAP_MS,
  STABLE_MS,
  backoffCeilingMs,
  backoffDelayMs,
  memberEmail,
  nextAttempt,
  parseArgs,
  reconnectDecision,
  summarize,
} from "../scripts/measure-lib.mjs";

describe("measure.mjs backoff (Appendix C: full jitter in min(60 s, 1 s x 2^n))", () => {
  it("doubles from one second and caps at sixty", () => {
    expect([0, 1, 2, 3, 4, 5, 6, 7, 20, 1000].map(backoffCeilingMs)).toEqual([
      1000, 2000, 4000, 8000, 16000, 32000, 60000, 60000, 60000, 60000,
    ]);
    expect(BACKOFF_CAP_MS).toBe(60_000);
  });

  it("draws the delay uniformly below the ceiling", () => {
    expect(backoffDelayMs(3, () => 0)).toBe(0);
    expect(backoffDelayMs(3, () => 0.5)).toBe(4000);
    expect(backoffDelayMs(3, () => 0.999999)).toBeLessThan(8000);
    expect(backoffDelayMs(10, () => 0.999999)).toBeLessThan(60_000);
    expect(Number.isInteger(backoffDelayMs(2, Math.random))).toBe(true);
  });

  it("resets the attempt count after a minute connected", () => {
    expect(STABLE_MS).toBe(60_000);
    expect(nextAttempt(4, 59_999)).toBe(5);
    expect(nextAttempt(4, 60_000)).toBe(1);
    expect(nextAttempt(0, 0)).toBe(1);
  });

  it("does not reconnect after revoked or replaced", () => {
    expect(reconnectDecision(4003)).toBe("stop");
    expect(reconnectDecision(4001)).toBe("stop");
    expect(reconnectDecision(4400)).toBe("stop");
    expect(reconnectDecision(1006)).toBe("retry");
    expect(reconnectDecision(1001)).toBe("retry");
    expect(reconnectDecision(1012)).toBe("retry");
  });
});

describe("measure.mjs arguments", () => {
  it("defaults to 30 members and a held, churned run without cleanup", () => {
    expect(parseArgs(["https://ptb-battle-league-dev.example.workers.dev/"])).toEqual({
      baseUrl: "https://ptb-battle-league-dev.example.workers.dev",
      members: 30,
      holdMinutes: 10,
      churn: 5,
      redeployWaitMinutes: 0,
      pingSeconds: 30,
      cleanup: false,
    });
  });

  it("reads every option", () => {
    expect(
      parseArgs([
        "--members", "3", "--hold-minutes", "0.5", "--churn", "2", "--redeploy-wait-minutes", "4",
        "--ping-seconds", "10", "--cleanup", "http://localhost:8787",
      ]),
    ).toEqual({
      baseUrl: "http://localhost:8787",
      members: 3,
      holdMinutes: 0.5,
      churn: 2,
      redeployWaitMinutes: 4,
      pingSeconds: 10,
      cleanup: true,
    });
  });

  it("refuses bad input", () => {
    for (const argv of [
      [],
      ["not a url"],
      ["ftp://example.com"],
      ["http://example.com"],
      ["https://user:pw@example.com"],
      ["https://example.com/?key=x"],
      ["https://example.com/#x"],
      ["https://a.example", "https://b.example"],
      ["https://example.com", "--members", "0"],
      ["https://example.com", "--members", "100"],
      ["https://example.com", "--members", "2.5"],
      ["https://example.com", "--members"],
      ["https://example.com", "--churn", "31"],
      ["https://example.com", "--hold-minutes", "-1"],
      ["https://example.com", "--ping-seconds", "0"],
      ["https://example.com", "--operator-secret", "x"],
    ]) {
      expect(() => parseArgs(argv), JSON.stringify(argv)).toThrow();
    }
  });

  it("never echoes a refused value", () => {
    const value = "operator-secret-looking-value-xxxxxxxxx";
    let message = "";
    try {
      parseArgs(["https://example.com", "--operator-secret", value]);
    } catch (error) {
      message = String(error);
    }
    expect(message).not.toBe("");
    expect(message).not.toContain(value);
  });
});

describe("measure.mjs helpers", () => {
  it("numbers member emails under measure.invalid", () => {
    expect(memberEmail(1)).toBe("m01@measure.invalid");
    expect(memberEmail(30)).toBe("m30@measure.invalid");
  });

  it("summarizes latencies", () => {
    expect(summarize([])).toEqual({ count: 0 });
    expect(summarize([5, 1, 3, 2, 4])).toEqual({ count: 5, min: 1, p50: 3, p90: 5, p99: 5, max: 5 });
  });
});
