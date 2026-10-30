import { describe, expect, it } from "vitest";
import { type Account, call, expectError, setupGroup } from "./helpers";

async function members(key: string): Promise<any[]> {
  const res = await call("GET", "/v1/group", { key });
  expect(res.status, res.text).toBe(200);
  return res.body.members;
}

async function expectSingleActiveHost(key: string, hostTrainerId: string): Promise<void> {
  const res = await call("GET", "/v1/group", { key });
  expect(res.body.group.hostTrainerId).toBe(hostTrainerId);
  const hosts = res.body.members.filter((m: any) => m.role === "host");
  expect(hosts).toHaveLength(1);
  expect(hosts[0]).toMatchObject({ trainerId: hostTrainerId, status: "active" });
}

async function auditKinds(key: string): Promise<string[][]> {
  const res = await call("GET", "/v1/audit", { key });
  expect(res.status, res.text).toBe(200);
  return res.body.entries.map((e: any) => [e.kind, e.actorTrainerId, e.targetTrainerId]);
}

function expectAnonymized(list: any[], account: Account): void {
  const entry = list.find((m) => m.trainerId === account.trainerId);
  expect(entry).toMatchObject({ trainerId: account.trainerId, status: "left", displayEmail: null });
}

describe("POST /v1/leave", () => {
  it("revokes the key and anonymizes the member while keeping the trainer id", async () => {
    const { host, members: [member] } = await setupGroup(1);
    const res = await call("POST", "/v1/leave", { key: member!.accessKey });
    expect(res.status, res.text).toBe(200);
    expectError(await call("GET", "/v1/me", { key: member!.accessKey }), 401, "unauthorized");
    const list = await members(host.accessKey);
    expectAnonymized(list, member!);
    expect(JSON.stringify(list).toLowerCase()).not.toContain(member!.email.toLowerCase());
    expect(await auditKinds(host.accessKey)).toContainEqual(["member_left", member!.trainerId, member!.trainerId]);
  });

  it("accepts an empty body", async () => {
    const { members: [member] } = await setupGroup(1);
    const res = await call("POST", "/v1/leave", { key: member!.accessKey, rawBody: "", contentType: null });
    expect(res.status, res.text).toBe(200);
  });

  it("refuses the host with host_must_transfer", async () => {
    const { host } = await setupGroup(1);
    expectError(await call("POST", "/v1/leave", { key: host.accessKey }), 409, "host_must_transfer");
    expect((await call("GET", "/v1/me", { key: host.accessKey })).status).toBe(200);
    await expectSingleActiveHost(host.accessKey, host.trainerId);
  });

  it("requires a key", async () => {
    expectError(await call("POST", "/v1/leave", {}), 401, "unauthorized");
  });
});

describe("POST /v1/host/transfer", () => {
  it("moves the host role so the old host can leave", async () => {
    const { host, members: [heir] } = await setupGroup(1);
    const res = await call("POST", "/v1/host/transfer", { key: host.accessKey, body: { trainerId: heir!.trainerId } });
    expect(res.status, res.text).toBe(200);
    expect(res.body.group.hostTrainerId).toBe(heir!.trainerId);
    await expectSingleActiveHost(heir!.accessKey, heir!.trainerId);

    expectError(await call("POST", "/v1/invites", { key: host.accessKey, body: {} }), 403, "forbidden");
    expect((await call("POST", "/v1/invites", { key: heir!.accessKey, body: {} })).status).toBe(200);

    expect((await call("POST", "/v1/leave", { key: host.accessKey })).status).toBe(200);
    await expectSingleActiveHost(heir!.accessKey, heir!.trainerId);
    expect(await auditKinds(heir!.accessKey)).toContainEqual(["host_transferred", host.trainerId, heir!.trainerId]);
  });

  it("only goes to an active member of the same group", async () => {
    const { host, members: [gone, stays] } = await setupGroup(2);
    await call("POST", "/v1/leave", { key: gone!.accessKey });
    expectError(
      await call("POST", "/v1/host/transfer", { key: host.accessKey, body: { trainerId: gone!.trainerId } }),
      404,
      "not_found",
    );
    expectError(
      await call("POST", "/v1/host/transfer", { key: host.accessKey, body: { trainerId: host.trainerId } }),
      400,
      "cannot_target_self",
    );
    expectError(
      await call("POST", "/v1/host/transfer", { key: stays!.accessKey, body: { trainerId: stays!.trainerId } }),
      403,
      "forbidden",
    );
    await expectSingleActiveHost(host.accessKey, host.trainerId);
  });
});

describe("POST /v1/members/remove", () => {
  it("lets the host remove a member, revoking the key and anonymizing", async () => {
    const { host, members: [member] } = await setupGroup(1);
    const res = await call("POST", "/v1/members/remove", { key: host.accessKey, body: { trainerId: member!.trainerId } });
    expect(res.status, res.text).toBe(200);
    expectError(await call("GET", "/v1/me", { key: member!.accessKey }), 401, "unauthorized");
    const list = await members(host.accessKey);
    expectAnonymized(list, member!);
    expect(await auditKinds(host.accessKey)).toContainEqual(["member_removed", host.trainerId, member!.trainerId]);
  });

  it("does not let a member remove anyone", async () => {
    const { host, members: [a, b] } = await setupGroup(2);
    for (const target of [b!, host]) {
      expectError(
        await call("POST", "/v1/members/remove", { key: a!.accessKey, body: { trainerId: target.trainerId } }),
        403,
        "forbidden",
      );
    }
    expect((await call("GET", "/v1/me", { key: b!.accessKey })).status).toBe(200);
  });

  it("does not let anyone remove themselves", async () => {
    const { host } = await setupGroup(1);
    expectError(
      await call("POST", "/v1/members/remove", { key: host.accessKey, body: { trainerId: host.trainerId } }),
      400,
      "cannot_target_self",
    );
  });

  it("is not_found for a member who already left", async () => {
    const { host, members: [member] } = await setupGroup(1);
    await call("POST", "/v1/leave", { key: member!.accessKey });
    expectError(
      await call("POST", "/v1/members/remove", { key: host.accessKey, body: { trainerId: member!.trainerId } }),
      404,
      "not_found",
    );
  });
});

describe("group and audit reads", () => {
  it("shows group name, host and members to any active member", async () => {
    const { host, members: [member] } = await setupGroup(1);
    const res = await call("GET", "/v1/group", { key: member!.accessKey });
    expect(res.status).toBe(200);
    expect(res.body.group).toMatchObject({ groupId: host.groupId, hostTrainerId: host.trainerId });
    expect(typeof res.body.group.name).toBe("string");
    expect(res.body.members.find((m: any) => m.trainerId === member!.trainerId)).toMatchObject({
      displayEmail: member!.email,
      role: "member",
      status: "active",
    });
  });

  it("lists invites only to the host", async () => {
    const { members: [member] } = await setupGroup(1);
    expectError(await call("GET", "/v1/invites", { key: member!.accessKey }), 403, "forbidden");
    expectError(await call("POST", "/v1/invites", { key: member!.accessKey, body: {} }), 403, "forbidden");
  });

  it("records invite creation and revocation", async () => {
    const { host, inviteId } = await setupGroup(0);
    await call("POST", "/v1/invites/revoke", { key: host.accessKey, body: { inviteId } });
    const res = await call("GET", "/v1/audit", { key: host.accessKey });
    const kinds = res.body.entries.map((e: any) => [e.kind, e.inviteId]);
    expect(kinds).toContainEqual(["invite_created", inviteId]);
    expect(kinds).toContainEqual(["invite_revoked", inviteId]);
  });
});
