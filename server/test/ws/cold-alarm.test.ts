import { evictDurableObject, runInDurableObject } from "cloudflare:test";
import { expect, it, vi } from "vitest";
import { closeSocketsAfterAll } from "./socket";
import { packedSession } from "./packed-session";
closeSocketsAfterAll();
it.each(["timeout", "early"])("rearms a real scheduled cold %s alarm once without the delivery helper", async kind => {
  const f = await packedSession();
  const sets: number[] = [], gets: (number | null)[] = []; let deliveries = 0;
  const restore = await runInDurableObject(f.stub, (instance, state) => {
    const storage = state.storage, prototype = Object.getPrototypeOf(storage), league = Object.getPrototypeOf(instance);
    const set = prototype.setAlarm, get = prototype.getAlarm, alarm = league.alarm;
    prototype.setAlarm = function(this: DurableObjectStorage, at: number | Date, ...args: unknown[]) { sets.push(Number(at)); return set.call(this, at, ...args); };
    prototype.getAlarm = async function(this: DurableObjectStorage, ...args: unknown[]) { const at = await get.call(this, ...args); gets.push(at); return at; };
    league.alarm = function(...args: unknown[]) { const result = alarm.call(this, ...args); deliveries++; return result; };
    const at = Date.now() + 250;
    const row = storage.sql.exec<{ data: string }>("SELECT data FROM battle_rooms").one(), b = JSON.parse(row.data);
    b.relay.current.deadline = kind === "timeout" ? at : at + 5000;
    storage.sql.exec("UPDATE battle_rooms SET data=?,turn_deadline=?", JSON.stringify(b), b.relay.current.deadline);
    void storage.setAlarm(at); sets.length = 0;
    return () => { prototype.setAlarm = set; prototype.getAlarm = get; league.alarm = alarm; };
  });
  try {
    await evictDurableObject(f.stub, { webSockets: "hibernate" });
    await vi.waitFor(() => expect(deliveries).toBe(1), { timeout: 2000, interval: 20 });
    expect(gets).toEqual([null]); expect(sets, JSON.stringify({ gets, sets })).toHaveLength(1);
    if (kind === "timeout") {
      const round = await f.sockets[0]!.socket.until(m => m.type === "battle_round");
      expect(round.pair).toMatchObject({ roundSeq: 1, p1: { kind: "timeout" }, p2: { kind: "timeout" } });
    } else { await f.sockets[0]!.socket.sync(); expect((await f.get()).journal).toEqual([]); }
  } finally { restore(); }
});
it.each(["standings", "close"])("repairs a missing persisted alarm on activation through %s alone", async entry => {
  const f = await packedSession(), deadline = f.view.deadline;
  await runInDurableObject(f.stub, (_i, state) => state.storage.deleteAlarm());
  await evictDurableObject(f.stub, { webSockets: "hibernate" });
  if (entry === "standings") expect((await f.request("GET", "/v1/standings", f.players[0].accessKey)).status).toBe(200);
  else {
    f.sockets[0]!.socket.close();
    await f.sockets[1]!.socket.until(m => m.type === "presence" && m.online === false);
  }
  expect(await f.alarm()).toBe(deadline);
});
