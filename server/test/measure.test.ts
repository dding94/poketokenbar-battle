import { describe, expect, it } from "vitest";
import {
  BACKOFF_CAP_MS,
  CONNECT_TIMEOUT_MS,
  Member,
  STABLE_MS,
  Stats,
  backoffCeilingMs,
  backoffDelayMs,
  memberEmail,
  nextAttempt,
  parseArgs,
  reconnectDecision,
  releaseSetup,
  runSetup,
  summarize,
  summaryOptions,
  targetLabel,
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
      ["https://example.com", "--members", "1e3"],
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

describe("measure.mjs summary target", () => {
  it("names the Worker by its first host label, never the workers.dev subdomain", () => {
    const options = parseArgs(["https://ptb-battle-league-dev.secret-sub.workers.dev", "--members", "99"]);
    expect(options.members).toBe(99);
    expect(targetLabel(options.baseUrl)).toBe("ptb-battle-league-dev");
    expect(targetLabel("http://localhost:8787")).toBe("localhost");
    const printed = JSON.stringify(summaryOptions(options));
    expect(printed).not.toContain("secret-sub");
    expect(printed).not.toContain("workers.dev");
    expect(JSON.parse(printed)).toMatchObject({ target: "ptb-battle-league-dev", members: 99 });
  });
});

/** A manual clock and timer queue standing in for Node's. */
class FakeTimers {
  now = 0;
  private nextId = 1;
  private timers = new Map<number, { at: number; fn: () => void; every: number | null }>();

  setTimeout = (fn: () => void, ms: number) => this.add(fn, ms, null);
  setInterval = (fn: () => void, ms: number) => this.add(fn, ms, ms);
  clearTimeout = (id: number) => void this.timers.delete(id);
  clearInterval = (id: number) => void this.timers.delete(id);

  private add(fn: () => void, ms: number, every: number | null): number {
    const id = this.nextId++;
    this.timers.set(id, { at: this.now + ms, fn, every });
    return id;
  }

  get pending(): number {
    return this.timers.size;
  }

  advance(ms: number): void {
    const until = this.now + ms;
    for (;;) {
      const due = [...this.timers.entries()].filter(([, t]) => t.at <= until).sort((a, b) => a[1].at - b[1].at)[0];
      if (!due) break;
      const [id, timer] = due;
      this.now = timer.at;
      if (timer.every === null) this.timers.delete(id);
      else timer.at += timer.every;
      timer.fn();
    }
    this.now = until;
  }
}

class FakeSocket {
  static created: FakeSocket[] = [];
  readyState = 0;
  sent: string[] = [];
  private listeners = new Map<string, Array<(event: any) => void>>();

  constructor(
    readonly url: string,
    readonly init: { headers: Record<string, string> },
  ) {
    FakeSocket.created.push(this);
  }

  addEventListener(type: string, fn: (event: any) => void): void {
    this.listeners.set(type, [...(this.listeners.get(type) ?? []), fn]);
  }

  emit(type: string, event: any = {}): void {
    if (type === "open") this.readyState = 1;
    if (type === "close") this.readyState = 3;
    for (const fn of this.listeners.get(type) ?? []) fn(event);
  }

  send(data: string): void {
    this.sent.push(data);
  }

  /** Like a real socket, the close event comes later (see emit). */
  close(): void {
    this.readyState = 2;
  }
}

function memberWith(timers: FakeTimers) {
  FakeSocket.created = [];
  const stats = new Stats();
  const env = {
    WebSocket: FakeSocket,
    now: () => timers.now,
    random: () => 0.5,
    setTimeout: timers.setTimeout,
    clearTimeout: timers.clearTimeout,
    setInterval: timers.setInterval,
    clearInterval: timers.clearInterval,
  };
  const member = new Member("ptbk_test", { baseUrl: "https://league.test", pingSeconds: 30 }, stats, env);
  return { member, stats };
}

describe("measure.mjs member sockets", () => {
  it("ignores a late close from the socket it replaced", async () => {
    const timers = new FakeTimers();
    const { member, stats } = memberWith(timers);
    const first = member.connect();
    const old = FakeSocket.created[0]!;
    old.emit("open");
    expect(await first).toBe(true);

    // Churn: close on purpose and reconnect before the old socket's close event arrives.
    member.close();
    timers.advance(2_000);
    const second = member.connect();
    const current = FakeSocket.created[1]!;
    current.emit("open");
    expect(await second).toBe(true);
    timers.advance(5_000);
    old.emit("close", { code: 1006 });
    old.emit("message", { data: "pong" });

    expect(member.socket).toBe(current);
    expect(member.open).toBe(true);
    expect(member.openedAt).toBe(2_000);
    expect(stats.unexpectedDrops).toEqual([]);
    expect(stats.reconnects).toEqual([]);
    expect(stats.pings.pongs).toBe(0);
    expect(stats.closes).toEqual({ setup: { "1006": 1 } });
    // The new socket's ping timer survived.
    timers.advance(30_000);
    expect(current.sent).toEqual(["ping"]);
    expect(FakeSocket.created).toHaveLength(2);
  });

  it("gives up on a connect that never opens and ignores that socket afterwards", async () => {
    const timers = new FakeTimers();
    const { member, stats } = memberWith(timers);
    const pending = member.connect();
    const stuck = FakeSocket.created[0]!;
    timers.advance(CONNECT_TIMEOUT_MS);
    expect(await pending).toBe(false);
    expect(stats.errors).toEqual({ connect_timeout: 1 });
    expect(stats.reconnects).toHaveLength(1);

    timers.advance(stats.reconnects[0]!.delayMs);
    const retry = FakeSocket.created[1]!;
    retry.emit("open");
    stuck.emit("open");
    stuck.emit("close", { code: 1006 });
    expect(member.socket).toBe(retry);
    expect(member.open).toBe(true);
    expect(stats.connects.opened).toBe(1);
    expect(stats.unexpectedDrops).toEqual([]);
    expect(stats.reconnects).toHaveLength(1);
  });

  it("does not reconnect after a timeout while closing on purpose", async () => {
    const timers = new FakeTimers();
    const { member, stats } = memberWith(timers);
    const pending = member.connect();
    member.close();
    timers.advance(CONNECT_TIMEOUT_MS);
    expect(await pending).toBe(false);
    expect(stats.errors).toEqual({});
    expect(stats.reconnects).toEqual([]);
    expect(timers.pending).toBe(0);
  });
});

interface Call {
  method: string;
  path: string;
  key?: string;
  body?: unknown;
}

function fakeApi(failJoinAt: number | null) {
  const calls: Call[] = [];
  let joins = 0;
  const api = async (method: string, path: string, init: { key?: string; body?: unknown } = {}) => {
    calls.push({ method, path, key: init.key, body: init.body });
    if (path === "/v1/groups") return { status: 200, json: { accessKey: "host-key", group: { groupId: "g1" } } };
    if (path === "/v1/invites") return { status: 200, json: { inviteCode: "CODE", invite: { inviteId: "inv1" } } };
    if (path === "/v1/join") {
      joins += 1;
      if (joins === failJoinAt) return { status: 429, json: { error: { code: "rate_limited" } } };
      return { status: 200, json: { accessKey: `member-key-${joins}`, trainer: { trainerId: `t${joins}` } } };
    }
    return { status: 200, json: {} };
  };
  return { api, calls };
}

describe("measure.mjs setup", () => {
  const now = () => "2026-10-31T00:00:00.000Z";

  it("returns a partial setup, which releaseSetup undoes", async () => {
    const { api, calls } = fakeApi(3);
    const state = await runSetup(api, { members: 5 }, "op-secret", new AbortController().signal, now);
    expect(state.error).toBe("join 3 failed with HTTP 429");
    expect(state.inviteId).toBe("inv1");
    expect(state.joined.map((m) => m.trainerId)).toEqual(["t1", "t2"]);
    expect(calls.filter((c) => c.path === "/v1/invites/revoke")).toEqual([]);

    calls.length = 0;
    expect(await releaseSetup(api, state)).toEqual({ inviteRevoked: true, membersJoined: 2, membersLeft: 2 });
    expect(calls).toEqual([
      { method: "POST", path: "/v1/invites/revoke", key: "host-key", body: { inviteId: "inv1" } },
      { method: "POST", path: "/v1/leave", key: "member-key-1", body: undefined },
      { method: "POST", path: "/v1/leave", key: "member-key-2", body: undefined },
    ]);
    expect(state.inviteId).toBeNull();
  });

  it("stops joining once interrupted", async () => {
    const { api, calls } = fakeApi(null);
    const interrupt = new AbortController();
    const interrupting = async (method: string, path: string, init?: { key?: string; body?: unknown }) => {
      const res = await api(method, path, init);
      if (calls.filter((c) => c.path === "/v1/join").length === 2) interrupt.abort();
      return res;
    };
    const state = await runSetup(interrupting, { members: 5 }, "op-secret", interrupt.signal, now);
    expect(state.error).toBe("interrupted during setup");
    expect(state.joined).toHaveLength(2);
    expect(calls.filter((c) => c.path === "/v1/join")).toHaveLength(2);
    expect(await releaseSetup(api, state)).toEqual({ inviteRevoked: true, membersJoined: 2, membersLeft: 2 });
  });

  it("revokes the invite after a full setup", async () => {
    const { api, calls } = fakeApi(null);
    const state = await runSetup(api, { members: 3 }, "op-secret", new AbortController().signal, now);
    expect(state.error).toBeNull();
    expect(state.joined).toHaveLength(3);
    expect(state.inviteId).toBeNull();
    expect(calls.map((c) => c.path).at(-1)).toBe("/v1/invites/revoke");
  });

  it("keeps response values out of an unexpected-response error", async () => {
    const api = async () => ({ status: 200, json: { unexpected: "op-secret" } });
    const state = await runSetup(api, { members: 1 }, "op-secret", new AbortController().signal, now);
    expect(state.error).toBe("setup failed on an unexpected response");
  });
});
