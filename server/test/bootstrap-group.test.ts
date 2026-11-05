import { describe, expect, it } from "vitest";
import {
  bootstrapGroup,
  buildRequest,
  formatFailure,
  formatSuccess,
  parseArgs,
} from "../scripts/bootstrap-group-lib.mjs";

const SECRET = "fake-operator-secret-for-tests";
const ACCESS_KEY = "ptb_fakeaccesskey0123456789";
const RECOVERY = "FAKE-RECOV-CODE-0001";
const ENV = { OPERATOR_SECRET: SECRET };

function successBody() {
  return {
    accessKey: ACCESS_KEY,
    recoveryCode: RECOVERY,
    trainer: { trainerId: "trainer-1", displayEmail: "Host", role: "host", status: "active" },
    group: { groupId: "group-1", name: "Arena", hostTrainerId: "trainer-1" },
  };
}

describe("bootstrap-group parseArgs", () => {
  it("reads base URL, group name and nickname, and the secret from the environment", () => {
    expect(parseArgs(["https://example.invalid/", "Arena", "Host"], ENV)).toEqual({
      baseUrl: "https://example.invalid",
      groupName: "Arena",
      nickname: "Host",
      operatorSecret: SECRET,
    });
  });

  it("allows http only for localhost", () => {
    expect(parseArgs(["http://localhost:8787", "A", "H"], ENV).baseUrl).toBe("http://localhost:8787");
    expect(() => parseArgs(["http://example.invalid", "A", "H"], ENV)).toThrow(/https/);
  });

  it("fails with a usage message when the URL is missing or invalid", () => {
    expect(() => parseArgs([], ENV)).toThrow(/usage/);
    expect(() => parseArgs(["not a url", "A", "H"], ENV)).toThrow(/usage/);
  });

  it("rejects a URL that carries credentials or a query", () => {
    expect(() => parseArgs(["https://u:p@example.invalid", "A", "H"], ENV)).toThrow(/usage/);
    expect(() => parseArgs(["https://example.invalid/?k=v", "A", "H"], ENV)).toThrow(/usage/);
  });

  it("fails when the group name or nickname is missing, or extra arguments are given", () => {
    expect(() => parseArgs(["https://example.invalid", "A"], ENV)).toThrow(/usage/);
    expect(() => parseArgs(["https://example.invalid", "A", "H", "extra"], ENV)).toThrow(/usage/);
  });

  it("fails when the secret is missing or empty", () => {
    expect(() => parseArgs(["https://example.invalid", "A", "H"], {})).toThrow(/OPERATOR_SECRET/);
    expect(() => parseArgs(["https://example.invalid", "A", "H"], { OPERATOR_SECRET: "" })).toThrow(/OPERATOR_SECRET/);
  });
});

describe("bootstrap-group request", () => {
  it("posts the secret in the body, never in the URL", () => {
    const options = parseArgs(["https://example.invalid", "Arena", "Host"], ENV);
    const { url, init } = buildRequest(options);
    expect(url).toBe("https://example.invalid/v1/groups");
    expect(url).not.toContain(SECRET);
    expect(init.method).toBe("POST");
    expect(JSON.parse(String(init.body))).toEqual({
      operatorSecret: SECRET,
      groupName: "Arena",
      displayEmail: "Host",
    });
  });
});

describe("bootstrap-group output", () => {
  it("prints the group id, trainer id and recovery code but not the access key or secret", () => {
    const text = formatSuccess(successBody());
    expect(text).toContain("group-1");
    expect(text).toContain("trainer-1");
    expect(text).toContain(RECOVERY);
    expect(text).toMatch(/recovery/i);
    expect(text).not.toContain(ACCESS_KEY);
    expect(text).not.toContain(SECRET);
  });

  it("prints only the error code on a server error", () => {
    const text = formatFailure(403, { error: { code: "operator_denied", detail: SECRET, other: ACCESS_KEY } });
    expect(text).toContain("operator_denied");
    expect(text).not.toContain(SECRET);
    expect(text).not.toContain(ACCESS_KEY);
  });

  it("falls back to a generic line when the error body has no code", () => {
    const text = formatFailure(500, `<html>${SECRET}</html>`);
    expect(text).toMatch(/500/);
    expect(text).not.toContain(SECRET);
  });
});

describe("bootstrapGroup", () => {
  const options = () => parseArgs(["https://example.invalid", "Arena", "Host"], ENV);

  it("returns success output that hides the access key", async () => {
    const fetchImpl = (async () => Response.json(successBody())) as unknown as typeof fetch;
    const result = await bootstrapGroup(options(), fetchImpl);
    expect(result.ok).toBe(true);
    expect(result.text).toContain(RECOVERY);
    expect(result.text).not.toContain(ACCESS_KEY);
    expect(result.text).not.toContain(SECRET);
  });

  it("returns only the error code when the server refuses", async () => {
    const fetchImpl = (async () =>
      Response.json({ error: { code: "operator_denied" } }, { status: 403 })) as unknown as typeof fetch;
    const result = await bootstrapGroup(options(), fetchImpl);
    expect(result.ok).toBe(false);
    expect(result.text).toContain("operator_denied");
    expect(result.text).not.toContain(SECRET);
  });

  it("does not echo a network error message", async () => {
    const fetchImpl = (async () => {
      throw new Error(`boom ${SECRET}`);
    }) as unknown as typeof fetch;
    const result = await bootstrapGroup(options(), fetchImpl);
    expect(result.ok).toBe(false);
    expect(result.text).not.toContain(SECRET);
    expect(result.text.length).toBeGreaterThan(0);
  });

  it("treats a success response without a recovery code as a failure", async () => {
    const fetchImpl = (async () => Response.json({ group: { groupId: "g" } })) as unknown as typeof fetch;
    const result = await bootstrapGroup(options(), fetchImpl);
    expect(result.ok).toBe(false);
  });
});
