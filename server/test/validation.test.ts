import { exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { BASE, call, createGroup, expectError, freshEmail, freshIp, operatorSecret } from "./helpers";

function groupBody(overrides: Record<string, unknown>) {
  return { operatorSecret: operatorSecret(), groupName: "Valid", displayEmail: freshEmail(), ...overrides };
}

function padTo(body: Record<string, unknown>, size: number): string {
  const json = JSON.stringify(body);
  return json + " ".repeat(size - new TextEncoder().encode(json).length);
}

describe("request bodies", () => {
  it("rejects malformed JSON with bad_request", async () => {
    expectError(await call("POST", "/v1/join", { rawBody: "{\"inviteCode\":" }), 400, "bad_request");
  });

  it("rejects JSON that is not an object", async () => {
    expectError(await call("POST", "/v1/join", { rawBody: "[]" }), 400, "bad_request");
    expectError(await call("POST", "/v1/join", { rawBody: "null" }), 400, "bad_request");
    expectError(await call("POST", "/v1/join", { rawBody: "\"x\"" }), 400, "bad_request");
  });

  it("rejects a non-JSON content type with unsupported_media_type", async () => {
    const rawBody = JSON.stringify({ inviteCode: "AAAA-AAAA-AAAA", displayEmail: freshEmail() });
    expectError(await call("POST", "/v1/join", { rawBody, contentType: "text/plain" }), 415, "unsupported_media_type");
    expectError(await call("POST", "/v1/join", { rawBody, contentType: null }), 415, "unsupported_media_type");
  });

  it("accepts a JSON content type with parameters", async () => {
    const res = await call("POST", "/v1/recover", {
      body: { recoveryCode: "ZZZZ-ZZZZ-ZZZZ-ZZZZ" },
      contentType: "application/json; charset=utf-8",
    });
    expectError(res, 404, "invalid_code");
  });

  it("accepts a body of exactly 4 KB and rejects a larger one", async () => {
    const body = { recoveryCode: "ZZZZ-ZZZZ-ZZZZ-ZZZZ" };
    expectError(await call("POST", "/v1/recover", { rawBody: padTo(body, 4096) }), 404, "invalid_code");
    expectError(await call("POST", "/v1/recover", { rawBody: padTo(body, 4097) }), 413, "payload_too_large");
  });

  it("rejects an oversized streamed body without a content length", async () => {
    const chunk = new TextEncoder().encode(" ".repeat(1024));
    let sent = 0;
    const stream = new ReadableStream<Uint8Array>({
      pull(controller) {
        if (sent >= 8) controller.close();
        else {
          controller.enqueue(chunk);
          sent += 1;
        }
      },
    });
    const req = new Request(`${BASE}/v1/recover`, {
      method: "POST",
      headers: { "content-type": "application/json", "cf-connecting-ip": freshIp() },
      body: stream,
    });
    const res = await exports.default.fetch(req);
    expect(res.status).toBe(413);
    expect(await res.json()).toEqual({ error: { code: "payload_too_large" } });
  });

  it("rejects wrong field types", async () => {
    const host = await createGroup();
    expectError(await call("POST", "/v1/invites", { key: host.accessKey, body: { ttlSeconds: "3600" } }), 400, "bad_request");
    expectError(await call("POST", "/v1/invites/revoke", { key: host.accessKey, body: { inviteId: 1 } }), 400, "bad_request");
    expectError(await call("POST", "/v1/members/remove", { key: host.accessKey, body: {} }), 400, "bad_request");
  });
});

describe("display email", () => {
  const bad = [
    "",
    "   ",
    "ab",
    "a@",
    "@b",
    "a@@b",
    "a@b@c",
    "no-at-sign",
    "a b@c",
    "a@b\tc",
    "a@b\u0007",
    "a@b c",
    `${"x".repeat(250)}@b.cd`,
  ];

  for (const email of bad) {
    it(`rejects ${JSON.stringify(email.length > 20 ? `${email.slice(0, 12)}…(${email.length})` : email)}`, async () => {
      expectError(await call("POST", "/v1/groups", { body: groupBody({ displayEmail: email }) }), 400, "bad_request");
    });
  }

  it("trims surrounding whitespace", async () => {
    const email = freshEmail("trim");
    const res = await call("POST", "/v1/groups", { body: groupBody({ displayEmail: `  ${email}\n` }) });
    expect(res.status, res.text).toBe(200);
    expect(res.body.trainer.displayEmail).toBe(email);
  });

  it("accepts 3 and 254 characters", async () => {
    expect((await call("POST", "/v1/groups", { body: groupBody({ displayEmail: "a@b" }) })).status).toBe(200);
    const long = `${"y".repeat(250)}@b.c`;
    expect(long).toHaveLength(254);
    expect((await call("POST", "/v1/groups", { body: groupBody({ displayEmail: long }) })).status).toBe(200);
  });

  it("is validated on join before the invite is looked at", async () => {
    expectError(await call("POST", "/v1/join", { body: { inviteCode: "AAAA-AAAA-AAAA", displayEmail: "bad" } }), 400, "bad_request");
  });
});

describe("group name", () => {
  for (const name of ["", "   ", "n".repeat(41)]) {
    it(`rejects a name of length ${name.length}`, async () => {
      expectError(await call("POST", "/v1/groups", { body: groupBody({ groupName: name }) }), 400, "bad_request");
    });
  }

  for (const name of ["n", "n".repeat(40), "포켓몬 트레이너 모임"]) {
    it(`accepts a name of length ${[...name].length}`, async () => {
      const res = await call("POST", "/v1/groups", { body: groupBody({ groupName: name }) });
      expect(res.status, res.text).toBe(200);
      expect(res.body.group.name).toBe(name);
    });
  }
});

describe("invite bounds", () => {
  const cases: Array<[Record<string, unknown>, number]> = [
    [{ ttlSeconds: 3599 }, 400],
    [{ ttlSeconds: 3600 }, 200],
    [{ ttlSeconds: 30 * 86400 }, 200],
    [{ ttlSeconds: 30 * 86400 + 1 }, 400],
    [{ ttlSeconds: 3600.5 }, 400],
    [{ maxUses: 0 }, 400],
    [{ maxUses: 1 }, 200],
    [{ maxUses: 100 }, 200],
    [{ maxUses: 101 }, 400],
    [{ maxUses: 2.5 }, 400],
    [{ maxUses: null }, 400],
  ];
  for (const [body, status] of cases) {
    it(`${JSON.stringify(body)} -> ${status}`, async () => {
      const host = await createGroup();
      const res = await call("POST", "/v1/invites", { key: host.accessKey, body });
      if (status === 200) expect(res.status, res.text).toBe(200);
      else expectError(res, 400, "bad_request");
    });
  }
});

describe("authorization header", () => {
  const malformed = ["", "Bearer", "Bearer ", "Basic abc", "Bearer ptbk_short", `Bearer ptbk_${"A".repeat(43)}`, `bearer  ptbk_${"A".repeat(43)}x`];
  for (const authorization of malformed) {
    it(`rejects ${JSON.stringify(authorization.slice(0, 24))} with unauthorized`, async () => {
      expectError(await call("GET", "/v1/me", { authorization }), 401, "unauthorized");
    });
  }

  it("rejects a missing header with unauthorized", async () => {
    expectError(await call("GET", "/v1/me"), 401, "unauthorized");
  });
});
