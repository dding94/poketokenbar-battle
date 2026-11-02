import { expect } from "vitest";
import { call, setupGroup, type Account } from "./helpers";
export const ENGINE = "a".repeat(64);
export const versions = { engineHash: ENGINE, rulesVersion: "gen9-notera-noitems-v1", policyVersion: "auto-v2" };
export function snapshot(instanceId = "original_1") {
  return { instanceId, set: { speciesNum: 25, form: null, level: 50, gender: "male", nature: "hardy", ability: "static", moves: ["thunderbolt", "tackle"], ivs: { hp: 31, attack: 31, defense: 31, "special-attack": 31, "special-defense": 31, speed: 31 }, shiny: false }, public: { speciesNum: 25, species: "Pikachu", level: 50, types: ["Electric"], stats: { hp: 110, atk: 75, def: 60, spa: 70, spd: 70, spe: 110 } }, hp: 100 };
}
export const action = (who: Account, id: string, name: string, body: unknown) => call("POST", `/v1/battles/${id}/${name}`, { key: who.accessKey, body });
export const getBattle = (who: Account, id: string) => call("GET", `/v1/battles/${id}`, { key: who.accessKey });
export const createBattle = (p1: Account, p2: Account, mode = "manual", requestId = crypto.randomUUID(), snap = snapshot()) => call("POST", "/v1/battles", { key: p1.accessKey, body: { requestId, targetTrainerId: p2.trainerId, mode, snapshot: snap } });
export async function room(mode = "manual") {
  const { host: p1, members: [p2, third] } = await setupGroup(2);
  const made = await createBattle(p1, p2!, mode); expect(made.status, made.text).toBe(200);
  return { p1, p2: p2!, third: third!, view: made.body };
}
export async function accepted(mode = "manual") {
  const f = await room(mode); const res = await action(f.p2, f.view.battleId, "accept", { revision: f.view.revision, snapshot: snapshot("original_2") });
  expect(res.status, res.text).toBe(200); return { ...f, view: res.body };
}
export async function confirmed(mode = "manual") {
  const f = await accepted(mode); const res = await action(f.p1, f.view.battleId, "confirm", { revision: f.view.revision });
  expect(res.status, res.text).toBe(200); return { ...f, view: res.body };
}
