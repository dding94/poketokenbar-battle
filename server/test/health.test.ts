import { describe, expect, it } from "vitest";
import wranglerConfig from "../wrangler.jsonc?raw";
import { call, expectError } from "./helpers";

function parseJsonc(text: string): any {
  // Enough for this file: strip line comments that start a line or follow whitespace.
  return JSON.parse(text.replace(/(^|\s)\/\/.*$/gm, "$1"));
}

describe("health and routing", () => {
  it("reports the API version without auth", async () => {
    const res = await call("GET", "/v1/health");
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ ok: true, api: 1 });
    expect(res.headers.get("cache-control")).toBe("no-store");
    expect(res.headers.get("content-type")).toMatch(/^application\/json/);
  });

  it("answers unknown routes with not_found and no-store", async () => {
    const res = await call("GET", "/v1/nope");
    expectError(res, 404, "not_found");
    expect(res.headers.get("cache-control")).toBe("no-store");
  });

  it("answers a known route with the wrong method with method_not_allowed", async () => {
    expectError(await call("POST", "/v1/health", { body: {} }), 405, "method_not_allowed");
    expectError(await call("GET", "/v1/join"), 405, "method_not_allowed");
    expectError(await call("DELETE", "/v1/group"), 405, "method_not_allowed");
  });
});

describe("missing CODE_PEPPER", () => {
  it("fails hashing routes with internal and keeps health working", async () => {
    const recover = await call("POST", "/v1/recover", {
      body: { recoveryCode: "ZZZZ-ZZZZ-ZZZZ-ZZZZ" },
      envOverride: { CODE_PEPPER: undefined },
    });
    expectError(recover, 500, "internal");
    const join = await call("POST", "/v1/join", {
      body: { inviteCode: "ZZZZ-ZZZZ-ZZZZ", displayEmail: "a@b.c" },
      envOverride: { CODE_PEPPER: "" },
    });
    expectError(join, 500, "internal");
    const health = await call("GET", "/v1/health", { envOverride: { CODE_PEPPER: undefined } });
    expect(health.status).toBe(200);
    expect(health.body).toEqual({ ok: true, api: 1 });
  });
});

describe("wrangler config", () => {
  const config = parseJsonc(wranglerConfig);

  it("keeps Workers Logs and observability explicitly off", () => {
    expect(config.observability?.enabled).toBe(false);
    expect(config.observability?.logs?.enabled ?? false).toBe(false);
  });

  it("declares the League SQLite Durable Object", () => {
    expect(config.durable_objects.bindings).toEqual([{ name: "LEAGUE", class_name: "League" }]);
    expect(config.migrations).toEqual([{ tag: "v1", new_sqlite_classes: ["League"] }]);
  });

  it("declares the dev environment with its own name and the bindings it does not inherit", () => {
    const dev = config.env?.dev;
    expect(dev?.name).toBe("ptb-battle-league-dev");
    expect(dev?.name).not.toBe(config.name);
    // Bindings are not inherited by environments; migrations stay at the top level.
    expect(dev?.durable_objects?.bindings).toEqual([{ name: "LEAGUE", class_name: "League" }]);
    expect(dev?.migrations ?? config.migrations).toEqual([{ tag: "v1", new_sqlite_classes: ["League"] }]);
    expect(dev?.workers_dev ?? config.workers_dev).toBe(true);
    expect(dev?.observability?.enabled).toBe(false);
    expect(dev?.observability?.logs?.enabled ?? false).toBe(false);
    expect(Object.keys(config.env ?? {})).toEqual(["dev"]);
  });

  it("holds no secret values", () => {
    expect(config.vars?.OPERATOR_SECRET).toBeUndefined();
    expect(config.vars?.CODE_PEPPER).toBeUndefined();
    expect(wranglerConfig).not.toMatch(/"(OPERATOR_SECRET|CODE_PEPPER)"\s*:/);
  });
});
