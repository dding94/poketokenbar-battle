import { describe, expect, it } from "vitest";
import { call, expectError, issueReconnect, setupGroup } from "./helpers";

describe("cross-group access", () => {
  async function twoGroups() {
    const a = await setupGroup(1);
    const b = await setupGroup(1);
    return { a, b };
  }

  it("lists only the caller's own group", async () => {
    const { a, b } = await twoGroups();
    const res = await call("GET", "/v1/group", { key: b.host.accessKey });
    expect(res.body.group.groupId).toBe(b.host.groupId);
    const ids = res.body.members.map((m: any) => m.trainerId);
    expect(ids).not.toContain(a.host.trainerId);
    expect(ids).not.toContain(a.members[0]!.trainerId);
  });

  it("refuses a reconnect code for another group's member", async () => {
    const { a, b } = await twoGroups();
    const res = await call("POST", "/v1/reconnect-codes", { key: b.host.accessKey, body: { trainerId: a.members[0]!.trainerId } });
    expectError(res, 404, "not_found");
  });

  it("refuses removing another group's member", async () => {
    const { a, b } = await twoGroups();
    const res = await call("POST", "/v1/members/remove", { key: b.host.accessKey, body: { trainerId: a.members[0]!.trainerId } });
    expectError(res, 404, "not_found");
    expect((await call("GET", "/v1/me", { key: a.members[0]!.accessKey })).status).toBe(200);
  });

  it("refuses revoking another group's invite", async () => {
    const { a, b } = await twoGroups();
    const res = await call("POST", "/v1/invites/revoke", { key: b.host.accessKey, body: { inviteId: a.inviteId } });
    expectError(res, 404, "not_found");
    const list = await call("GET", "/v1/invites", { key: a.host.accessKey });
    expect(list.body.invites.find((i: any) => i.inviteId === a.inviteId).revoked).toBe(false);
  });

  it("refuses transferring host to another group's member", async () => {
    const { a, b } = await twoGroups();
    const res = await call("POST", "/v1/host/transfer", { key: b.host.accessKey, body: { trainerId: a.members[0]!.trainerId } });
    expectError(res, 404, "not_found");
    const group = await call("GET", "/v1/group", { key: b.host.accessKey });
    expect(group.body.group.hostTrainerId).toBe(b.host.trainerId);
  });

  it("refuses transferring host to another group's host", async () => {
    const { a, b } = await twoGroups();
    const res = await call("POST", "/v1/host/transfer", { key: b.host.accessKey, body: { trainerId: a.host.trainerId } });
    expectError(res, 404, "not_found");
  });

  it("keeps audit logs per group", async () => {
    const { a, b } = await twoGroups();
    await issueReconnect(a.host.accessKey, a.members[0]!.trainerId);
    const res = await call("GET", "/v1/audit", { key: b.host.accessKey });
    expect(res.status).toBe(200);
    expect(res.text).not.toContain(a.members[0]!.trainerId);
    expect(res.text).not.toContain(a.inviteId);
  });
});
