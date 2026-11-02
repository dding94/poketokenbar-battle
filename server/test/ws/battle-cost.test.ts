import { env } from "cloudflare:workers";
import { runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { afterEach, expect, it, vi } from "vitest";
import worker from "../../src/index";
import type { League } from "../../src/league";
import { snapshot, versions } from "../battle-fixture";
import { BASE, DAY, call, freshEmail, operatorSecret } from "../helpers";
import { closeSocketsAfterAll, Socket } from "./socket";
closeSocketsAfterAll();
afterEach(() => vi.restoreAllMocks());

// Local workerd only, fake accounts, unique DO per scenario. No remote URL or credentials.
// Instrumented SQL cursors count index writes already; setAlarm writes are reported separately.
// HTTP/RPC counters exclude setup and test-only introspection. SQL excludes baseline/measurement queries.
const scenarios = [
  { name: "manual-25", mode: "manual", rounds: 25, finish: "match" },
  { name: "manual-25-batch10", mode: "manual", rounds: 25, finish: "match", games: 10 },
  { name: "manual-200", mode: "manual", rounds: 200, finish: "match" },
  { name: "auto-25", mode: "auto", rounds: 25, finish: "match" },
  { name: "timeout-25", mode: "manual", rounds: 25, finish: "match", timeout: true },
  { name: "mismatch", mode: "manual", rounds: 1, finish: "mismatch" },
  { name: "missing-report", mode: "manual", rounds: 1, finish: "missing" },
  { name: "zero-report", mode: "auto", rounds: 1, finish: "zero" },
  { name: "reconnect", mode: "manual", rounds: 1, finish: "match", reconnect: true },
] as const;

type Meter = { cursors: SqlStorageCursor<Record<string, SqlStorageValue>>[]; alarmWrites: number; alarmDeletes: number; restore: () => void };
type MeasuredLeague = League & { __cost?: Meter };
async function begin(stub: DurableObjectStub<League>) {
  return runInDurableObject(stub, (instance: MeasuredLeague, state) => {
    const sql = state.storage.sql, original = sql.exec.bind(sql), setAlarm = state.storage.setAlarm.bind(state.storage), deleteAlarm = state.storage.deleteAlarm.bind(state.storage);
    const baseline = sql.databaseSize;
    const meter: Meter = { cursors: [], alarmWrites: 0, alarmDeletes: 0, restore: () => { sql.exec = original; state.storage.setAlarm = setAlarm; state.storage.deleteAlarm = deleteAlarm; } };
    sql.exec = ((query: string, ...values: SqlStorageValue[]) => { const cursor = original(query, ...values); meter.cursors.push(cursor); return cursor; }) as typeof sql.exec;
    state.storage.setAlarm = ((...args: Parameters<typeof setAlarm>) => { meter.alarmWrites++; return setAlarm(...args); }) as typeof setAlarm;
    state.storage.deleteAlarm = ((...args: Parameters<typeof deleteAlarm>) => { meter.alarmDeletes++; return deleteAlarm(...args); }) as typeof deleteAlarm;
    instance.__cost = meter;
    return baseline;
  });
}
async function end(stub: DurableObjectStub<League>, forcedAlarms: number) {
  return runInDurableObject(stub, (instance: MeasuredLeague, state) => {
    const meter = instance.__cost!; meter.restore(); delete instance.__cost;
    // Cursors have already been consumed by the operations that use them. Read all remaining
    // rows (DDL/write cursors are empty) before reading the final rowsWritten counters.
    for (const cursor of meter.cursors) cursor.toArray();
    const rowsWritten = meter.cursors.reduce((sum, cursor) => sum + cursor.rowsWritten, 0);
    const rowsRead = meter.cursors.reduce((sum, cursor) => sum + cursor.rowsRead, 0);
    const sql = state.storage.sql;
    const names = sql.exec<{ name: string }>("SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'battle_%'").toArray();
    let retainedCellBytes = 0;
    for (const { name } of names) for (const row of sql.exec(`SELECT * FROM ${name}`).toArray()) for (const value of Object.values(row)) {
      retainedCellBytes += typeof value === "string" ? new TextEncoder().encode(value).length : typeof value === "number" ? 8 : value instanceof ArrayBuffer ? value.byteLength : 0;
    }
    return { rowsRead, rowsWritten, alarmWrites: meter.alarmWrites, alarmDeletes: meter.alarmDeletes - forcedAlarms, harnessAlarmDeletes: forcedAlarms, databaseBytes: sql.databaseSize, retainedCellBytes };
  });
}

it.each(scenarios)("local workerd cost: $name", async scenario => {
  const print = console.log.bind(console);
  vi.spyOn(console, "log").mockImplementation(() => {});
  const id = env.LEAGUE.idFromName(`cost-${crypto.randomUUID()}`), stub = env.LEAGUE.get(id);
  let httpRequests = 0, rpcRequests = 0, alarmRequests = 0, measuring = false;
  const namespace = {
    idFromName: () => id,
    get: () => new Proxy(stub, { get(target, key) {
      const value = Reflect.get(target, key);
      return typeof value === "function" ? (...args: unknown[]) => { if (measuring) rpcRequests++; return Reflect.apply(value, target, args); } : value;
    } }),
  } as unknown as DurableObjectNamespace<League>;
  const bindings = { LEAGUE: namespace };
  const request = async (method: string, path: string, key?: string, body?: unknown) => {
    if (measuring) httpRequests++;
    const res = await call(method, path, { key, body, envOverride: bindings }); expect(res.status, res.text).toBe(200); return res.body;
  };
  const owner = await request("POST", "/v1/groups", undefined, { operatorSecret: operatorSecret(), groupName: "Synthetic cost fixture", displayEmail: freshEmail() });
  const invite = await request("POST", "/v1/invites", owner.accessKey, {});
  const guest = await request("POST", "/v1/join", undefined, { inviteCode: invite.inviteCode, displayEmail: freshEmail() });
  let now = Date.now();
  await runInDurableObject(stub, instance => { instance.clock = () => now; });
  const clock = async (at: number) => { now = at; await runInDurableObject(stub, instance => { instance.clock = () => at; }); };
  const baselineDatabaseBytes = await begin(stub); measuring = true;
  const open = async (key: string) => {
    httpRequests++;
    const response = await worker.fetch(new Request(`${BASE}/v1/connect`, { headers: { upgrade: "websocket", authorization: `Bearer ${key}` } }), { ...env, ...bindings });
    if (response.status !== 101 || !response.webSocket) { const text = await response.text(); expect.fail(text); }
    const socket = new Socket(response.webSocket); const hello = await socket.next(); expect(hello.type).toBe("hello"); return { socket, hello };
  };
  const sockets = [await open(owner.accessKey), await open(guest.accessKey)];
  const games = "games" in scenario ? scenario.games : 1;
  for (let game = 0; game < games; game++) {
  const created = await request("POST", "/v1/battles", owner.accessKey, { requestId: `cost-${game}`, targetTrainerId: guest.trainer.trainerId, mode: scenario.mode, snapshot: snapshot("cost-p1") });
  const path = `/v1/battles/${created.battleId}`;
  await request("POST", `${path}/accept`, guest.accessKey, { revision: 1, snapshot: snapshot("cost-p2") });
  await request("POST", `${path}/confirm`, owner.accessKey, { revision: 2 });
  const players = [owner, guest]; let view: any;
  for (let i = 0; i < 2; i++) view = await request("POST", `${path}/ready`, players[i].accessKey, { revision: 2, ...versions, connectionId: sockets[i]!.hello.connectionId });
  const config = view.config;
  for (let i = 0; i < 2; i++) view = await request("POST", `${path}/start`, players[i].accessKey, { revision: 2, engineHash: versions.engineHash, readyToken: config.readyToken, connectionId: sockets[i]!.hello.connectionId });
  expect(view.state).toBe("RUNNING");
  for (let seq = 1; seq <= scenario.rounds; seq++) {
    if (scenario.mode === "manual") {
      if ("timeout" in scenario) {
        await clock(now + 30_000); alarmRequests++; expect(await runDurableObjectAlarm(stub)).toBe(true);
      } else {
        for (const player of players) view = await request("POST", `${path}/choices`, player.accessKey, { roundSeq: seq, choice: "move 1" });
      }
    }
    if (seq < scenario.rounds) view = await request("POST", `${path}/advance`, owner.accessKey, { processedRoundSeq: seq });
  }
  if ("reconnect" in scenario) {
    sockets.push(await open(owner.accessKey));
    view = await request("GET", path, owner.accessKey); expect(view.config).toEqual(config); expect(view.journal).toHaveLength(scenario.rounds);
  }
  const report = { readyToken: config.readyToken, engineHash: versions.engineHash, terminalSeq: scenario.rounds, winner: "p1", logHash: "c".repeat(64), journalHash: "d".repeat(64), finalHp: { p1: 50, p2: 0 } };
  if (scenario.finish !== "zero") view = await request("POST", `${path}/report`, owner.accessKey, report);
  if (scenario.finish === "match" || scenario.finish === "mismatch") {
    view = await request("POST", `${path}/report`, guest.accessKey, scenario.finish === "mismatch" ? { ...report, logHash: "e".repeat(64) } : report);
    expect(view.state).toBe(scenario.finish === "match" ? "COMPLETED" : "VOID");
  } else {
    await clock(now + 3 * DAY); alarmRequests++; expect(await runDurableObjectAlarm(stub)).toBe(true);
    view = await request("GET", path, owner.accessKey); expect(view.state).toBe("VOID");
  }
  }
  measuring = false;
  // The pinned test helper consumes each alarm with deleteAlarm before delivery.
  // Exclude those harness calls from application alarm deletes.
  const measured = await end(stub, alarmRequests);
  expect(measured.alarmDeletes).toBeGreaterThanOrEqual(0);
  const expectedHTTP = 2 + games * (7 + (scenario.mode === "manual" && !("timeout" in scenario) ? 2 * scenario.rounds : 0) + scenario.rounds - 1 + (scenario.finish === "zero" ? 1 : 2)) + ("reconnect" in scenario ? 2 : 0);
  expect(httpRequests).toBe(expectedHTTP);
  expect(alarmRequests).toBe(games * (("timeout" in scenario ? scenario.rounds : 0) + (scenario.finish === "zero" || scenario.finish === "missing" ? 1 : 0)));
  expect(rpcRequests).toBe(httpRequests); expect(measured.rowsWritten).toBeGreaterThan(0); expect(measured.retainedCellBytes).toBeGreaterThan(0);
  print(JSON.stringify({ localWorkerdOnly: true, scenario: scenario.name, games, rounds: scenario.rounds, httpRequests, rpcRequests, alarmRequests, doRequests: rpcRequests + alarmRequests, ...measured, baselineDatabaseBytes, databaseDeltaBytes: measured.databaseBytes - baselineDatabaseBytes }));
  for (const { socket } of sockets) if (!socket.closeInfo) socket.close();
  await Promise.all(sockets.map(s => s.socket.closed()));
});
