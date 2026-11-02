import { expect } from "vitest";
import { action, confirmed, versions } from "../battle-fixture";
import { connect } from "./socket";
export async function running(mode = "manual") {
  const f = await confirmed(mode); const a = await connect(f.p1.accessKey), b = await connect(f.p2.accessKey);
  const body = { revision: f.view.revision, ...versions };
  expect((await action(f.p1, f.view.battleId, "ready", { ...body, connectionId: a.hello.connectionId })).status).toBe(200);
  const ready = await action(f.p2, f.view.battleId, "ready", { ...body, connectionId: b.hello.connectionId }); expect(ready.body.state).toBe("READY");
  const start = { revision: f.view.revision, engineHash: versions.engineHash, readyToken: ready.body.config.readyToken };
  expect((await action(f.p1, f.view.battleId, "start", { ...start, connectionId: a.hello.connectionId })).body.state).toBe("READY");
  const began = await action(f.p2, f.view.battleId, "start", { ...start, connectionId: b.hello.connectionId }); expect(began.status, began.text).toBe(200); expect(began.body.state).toBe("RUNNING");
  await a.socket.until(m => m.type === "battle_changed" && m.state === "RUNNING");
  await b.socket.until(m => m.type === "battle_changed" && m.state === "RUNNING");
  return { ...f, a, b, view: began.body };
}
export async function release(f: Awaited<ReturnType<typeof running>>, seq = f.view.roundSeq) {
  expect((await action(f.p1, f.view.battleId, "choices", { roundSeq: seq, choice: "move 1" })).status).toBe(200);
  const res = await action(f.p2, f.view.battleId, "choices", { roundSeq: seq, choice: "move 2" }); expect(res.status, res.text).toBe(200); return res.body;
}
