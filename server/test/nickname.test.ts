import { describe, expect, it } from "vitest";
import { call, createGroup, expectError, issueInvite, issueReconnect, join, joinRaw, leaveGroup, reconnectWith } from "./helpers";

describe("nickname registration through the compatible display field", () => {
  it("accepts a one-character host name and a Korean member nickname", async () => {
    const host = await createGroup({ email: "딩" });
    const { inviteCode } = await issueInvite(host.accessKey);
    const res = await joinRaw(inviteCode, "  피카츄트레이너  ");
    expect(res.status, res.text).toBe(200);
    expect(res.body.trainer.displayEmail).toBe("피카츄트레이너");
  });
  it("rejects normalized duplicate nicknames without replacing the first member", async () => {
    const host = await createGroup();
    const { inviteCode } = await issueInvite(host.accessKey);
    const member = await join(inviteCode, "Trainer");
    expectError(await joinRaw(inviteCode, "  ＴＲＡＩＮＥＲ  "), 409, "display_email_taken");
    const res = await call("GET", "/v1/me", { key: member.accessKey });
    expect(res.status, res.text).toBe(200);
    expect(res.body.trainer.trainerId).toBe(member.trainerId);
  });
  it("restores a left account with its nickname and original identity", async () => {
    const host = await createGroup();
    const { inviteCode } = await issueInvite(host.accessKey);
    const member = await join(inviteCode, "라프라스");
    expect((await leaveGroup(member.accessKey)).status).toBe(200);
    const code = await issueReconnect(host.accessKey, member.trainerId);
    const res = await reconnectWith(code, "딩");
    expect(res.status, res.text).toBe(200);
    expect(res.body.trainer).toMatchObject({ trainerId: member.trainerId, displayEmail: "딩" });
  });
});
