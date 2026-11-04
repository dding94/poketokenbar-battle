import { env } from "cloudflare:workers";
import { runInDurableObject } from "cloudflare:test";
import { expect } from "vitest";
import worker from "../../src/index";
import { snapshot, versions } from "../battle-fixture";
import { BASE, call, freshEmail, operatorSecret } from "../helpers";
import { Socket } from "./socket";
export async function packedSession(mode = "manual") {
  const id = env.LEAGUE.idFromName(`packed-${crypto.randomUUID()}`), stub = env.LEAGUE.get(id);
  const bindings = { LEAGUE: { idFromName: () => id, get: () => stub } } as unknown as Pick<Env, "LEAGUE">;
  const request = (method: string, path: string, key?: string, body?: unknown) => call(method, path, { key, body, envOverride: bindings });
  const owner = (await request("POST", "/v1/groups", undefined, { operatorSecret: operatorSecret(), groupName: "Packed fixture", displayEmail: freshEmail() })).body;
  const invite = (await request("POST", "/v1/invites", owner.accessKey, {})).body;
  const guest = (await request("POST", "/v1/join", undefined, { inviteCode: invite.inviteCode, displayEmail: freshEmail() })).body;
  const players = [owner, guest], sockets: { socket: Socket; connectionId: unknown }[] = [];
  for (const player of players) {
    const response = await worker.fetch(new Request(`${BASE}/v1/connect`, { headers: { upgrade: "websocket", authorization: `Bearer ${player.accessKey}` } }), { ...env, ...bindings });
    expect(response.status).toBe(101);
    const socket = new Socket(response.webSocket!); const hello = await socket.next(); sockets.push({ socket, connectionId: hello.connectionId });
  }
  const clock = (at: number) => runInDurableObject(stub, instance => { instance.clock = () => at; });
  await clock(Date.now());
  let view = (await request("POST", "/v1/battles", owner.accessKey, { requestId: "packed", targetTrainerId: guest.trainer.trainerId, mode, snapshot: snapshot("packed-p1") })).body;
  const path = `/v1/battles/${view.battleId}`;
  const action = async (side: number, name: string, body: unknown) => {
    const result = await request("POST", `${path}/${name}`, players[side].accessKey, body);
    expect(result.status, result.text).toBe(200); return result.body;
  };
  view = await action(1, "accept", { revision: 1, snapshot: snapshot("packed-p2") });
  await action(0, "confirm", { revision: 2 });
  for (let i = 0; i < 2; i++) view = await action(i, "ready", { revision: 2, ...versions, connectionId: sockets[i]!.connectionId });
  for (let i = 0; i < 2; i++) view = await action(i, "start", { revision: 2, engineHash: versions.engineHash, readyToken: view.config.readyToken, connectionId: sockets[i]!.connectionId });
  for (const { socket } of sockets) await socket.until(m => m.type === "battle_changed" && m.state === "RUNNING");
  const get = async (side = 0) => (await request("GET", path, players[side].accessKey)).body;
  const alarm = () => runInDurableObject(stub, (_instance, state) => state.storage.getAlarm());
  return { stub, players, sockets, view, clock, request, path, action, get, alarm };
}
export async function measured<T>(f: Awaited<ReturnType<typeof packedSession>>, operation: () => Promise<T>) {
  const cursors: SqlStorageCursor<Record<string, SqlStorageValue>>[] = [];
  const restore = await runInDurableObject(f.stub, (_instance, state) => {
    const sql = state.storage.sql, original = sql.exec.bind(sql);
    sql.exec = ((query: string, ...values: SqlStorageValue[]) => { const cursor = original(query, ...values); cursors.push(cursor); return cursor; }) as typeof sql.exec;
    return () => { sql.exec = original; };
  });
  try { const value = await operation(); for (const cursor of cursors) cursor.toArray(); return { value, writes: cursors.reduce((n, c) => n + c.rowsWritten, 0), reads: cursors.reduce((n, c) => n + c.rowsRead, 0) }; }
  finally { restore(); }
}
