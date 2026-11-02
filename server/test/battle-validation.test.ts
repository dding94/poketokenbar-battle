import { describe, it } from "vitest";
import { call, expectError, setupGroup } from "./helpers";
import { snapshot } from "./battle-fixture";
describe("closed snapshot input", () => {
  const mutations: [string, (s: any) => void, string][] = [
    ["fainted", s => s.hp = 0, "fainted"], ["HP above max", s => s.hp = 111, "invalid_snapshot"],
    ["hidden field", s => s.experience = 1, "invalid_snapshot"], ["set field", s => s.set.item = "x", "invalid_snapshot"],
    ["species mismatch", s => s.public.speciesNum = 26, "invalid_snapshot"], ["level mismatch", s => s.public.level = 51, "invalid_snapshot"],
    ["IV key", s => s.set.ivs.atk = 31, "invalid_snapshot"], ["invalid IV", s => s.set.ivs.hp = 32, "invalid_snapshot"],
    ["stat key", s => s.public.stats.attack = 75, "invalid_snapshot"], ["stat range", s => s.public.stats.atk = 1000, "invalid_snapshot"],
    ["invisible name", s => s.public.species = "Pika\u034fchu", "invalid_snapshot"],
    ["slug injection", s => s.set.moves = ["tackle\n>eval 1"], "invalid_snapshot"],
    ["duplicate types", s => s.public.types = ["Electric", "Electric"], "invalid_snapshot"],
    ["unsupported type", s => s.public.types = ["Stellar"], "invalid_snapshot"],
    ["instance delimiter", s => s.instanceId = "x:y", "invalid_snapshot"],
    ["level range", s => s.set.level = 101, "invalid_snapshot"], ["species range", s => s.set.speciesNum = 650, "invalid_snapshot"],
    ["gender", s => s.set.gender = "M", "invalid_snapshot"], ["shiny", s => s.set.shiny = 1, "invalid_snapshot"],
  ];
  it.each(mutations)("rejects %s", async (_label, mutate, code) => {
    const { host, members: [target] } = await setupGroup(); const snap = snapshot(); mutate(snap);
    expectError(await call("POST", "/v1/battles", { key: host.accessKey, body: { requestId: "request", targetTrainerId: target!.trainerId, mode: "manual", snapshot: snap } }), code === "fainted" ? 409 : 400, code);
  });
  it("keeps authentication, byte and unknown-key boundaries", async () => {
    expectError(await call("POST", "/v1/battles", { body: {} }), 401, "unauthorized");
    const { host, members: [target] } = await setupGroup();
    expectError(await call("POST", "/v1/battles", { key: host.accessKey, rawBody: "x".repeat(4097) }), 413, "payload_too_large");
    expectError(await call("POST", "/v1/battles", { key: host.accessKey, body: { requestId: "x", targetTrainerId: target!.trainerId, mode: "manual", snapshot: snapshot(), unknown: true } }), 400, "bad_request");
  });
});
