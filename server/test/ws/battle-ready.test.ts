import { describe, expect, it } from "vitest";
import { action, confirmed, createBattle, getBattle, snapshot, versions } from "../battle-fixture";
import { dumpTables, expectError, setClock, useRealClockAfterEach } from "../helpers";
import { closeSocketsAfterAll, connect } from "./socket";
closeSocketsAfterAll(); useRealClockAfterEach();
async function connectedRoom() {
  const f = await confirmed(); const a = await connect(f.p1.accessKey); const b = await connect(f.p2.accessKey);
  return { ...f, a, b, readyBody: { revision: f.view.revision, ...versions } };
}
describe("ready handshake", () => {
  it("freezes both snapshots and random config only after both current sessions are ready", async () => {
    const f = await connectedRoom(); const id = f.view.battleId;
    expect(f.a.hello.connectionId).toEqual(expect.any(String)); expect(f.a.hello.connectionId).not.toBe(f.b.hello.connectionId);
    const one = await action(f.p1, id, "ready", { ...f.readyBody, connectionId: f.a.hello.connectionId });
    expect(one.status).toBe(200); expect(one.body.state).toBe("ACCEPTED"); expect(one.body.config).toBeNull();
    const two = await action(f.p2, id, "ready", { ...f.readyBody, connectionId: f.b.hello.connectionId });
    expect(two.status).toBe(200); expect(two.body.state).toBe("READY");
    expect(two.body.config).toMatchObject({ engineHash: versions.engineHash, rulesVersion: versions.rulesVersion, policyVersion: versions.policyVersion, relayVersion: "relay-v1", p1: { name: "p1", policy: "standard", hp: 100, set: snapshot().set } });
    expect(two.body.config.seed).toHaveLength(4); for (const n of two.body.config.seed) expect(n).toBeGreaterThanOrEqual(0);
    expect(two.body.config.policySeed).toBeGreaterThanOrEqual(0);
    expect(two.body.p1.snapshot).toEqual(snapshot());
    expect((await action(f.p1, id, "confirm", { revision: f.view.revision })).body.state).toBe("READY");
    expect((await action(f.p1, id, "ready", { ...f.readyBody, connectionId: f.a.hello.connectionId })).body.config).toEqual(two.body.config);
    const locks = (await dumpTables()).battle_locks!.filter(r => r.battle_id === id); expect(locks).toHaveLength(2);
  });
  it("rejects version and engine mismatch before locking either participant", async () => {
    const f = await connectedRoom(); const id = f.view.battleId;
    expectError(await action(f.p1, id, "ready", { ...f.readyBody, connectionId: f.a.hello.connectionId, policyVersion: "auto-v1" }), 409, "version_mismatch");
    expect((await action(f.p1, id, "ready", { ...f.readyBody, connectionId: f.a.hello.connectionId })).status).toBe(200);
    expectError(await action(f.p2, id, "ready", { ...f.readyBody, connectionId: f.b.hello.connectionId, engineHash: "b".repeat(64) }), 409, "engine_mismatch");
    expect((await dumpTables()).battle_locks!.filter(r => r.battle_id === id)).toHaveLength(0);
    expect((await getBattle(f.p1, id)).body.state).toBe("ACCEPTED");
  });
  it("rejects a changed engine hash from an already-ready session", async () => {
    const f = await connectedRoom(); const body = { ...f.readyBody, connectionId: f.a.hello.connectionId };
    expect((await action(f.p1, f.view.battleId, "ready", body)).status).toBe(200);
    expectError(await action(f.p1, f.view.battleId, "ready", { ...body, engineHash: "b".repeat(64) }), 409, "engine_mismatch");
  });
  it("requires fresh ACK after same-millisecond socket replacement while keeping config", async () => {
    await setClock(Date.now()); const f = await connectedRoom(); const id = f.view.battleId;
    await action(f.p1, id, "ready", { ...f.readyBody, connectionId: f.a.hello.connectionId });
    const ready = await action(f.p2, id, "ready", { ...f.readyBody, connectionId: f.b.hello.connectionId }); expect(ready.status).toBe(200);
    const body = { revision: f.view.revision, readyToken: ready.body.config.readyToken, engineHash: versions.engineHash };
    expect((await action(f.p1, id, "start", { ...body, connectionId: f.a.hello.connectionId })).body.state).toBe("READY");
    const replacement = await connect(f.p1.accessKey); expect(replacement.hello.connectionId).not.toBe(f.a.hello.connectionId);
    expectError(await action(f.p1, id, "start", { ...body, connectionId: f.a.hello.connectionId }), 409, "not_ready");
    expect((await action(f.p2, id, "start", { ...body, connectionId: f.b.hello.connectionId })).body.state).toBe("READY");
    const started = await action(f.p1, id, "start", { ...body, connectionId: replacement.hello.connectionId });
    expect(started.status).toBe(200); expect(started.body.state).toBe("RUNNING"); expect(started.body.config).toEqual(ready.body.config);
  });
  it("checks original instance locks at creation, acceptance and the READY race without partial writes", async () => {
    const f = await connectedRoom(); const id = f.view.battleId;
    const other = await createBattle(f.p1, f.third); expect(other.status).toBe(200);
    await action(f.third, other.body.battleId, "accept", { revision: 1, snapshot: snapshot("third") });
    await action(f.p1, other.body.battleId, "confirm", { revision: 2 });
    const c = await connect(f.third.accessKey);
    await action(f.p1, id, "ready", { ...f.readyBody, connectionId: f.a.hello.connectionId });
    expect((await action(f.p2, id, "ready", { ...f.readyBody, connectionId: f.b.hello.connectionId })).body.state).toBe("READY");
    expectError(await createBattle(f.p1, f.third), 409, "instance_busy");
    expectError(await action(f.p1, other.body.battleId, "ready", { ...f.readyBody, connectionId: f.a.hello.connectionId }), 409, "instance_busy");
    expect((await action(f.third, other.body.battleId, "ready", { ...f.readyBody, connectionId: c.hello.connectionId })).status).toBe(200);
    expect((await dumpTables()).battle_locks!.filter(r => r.battle_id === other.body.battleId)).toHaveLength(0);
    await action(f.p1, id, "cancel", { revision: f.view.revision });
    expect((await dumpTables()).battle_locks!.filter(r => r.battle_id === id)).toHaveLength(0);
  });
});
