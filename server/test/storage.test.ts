import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import {
  call,
  createGroup,
  dumpTables,
  freshEmail,
  freshIp,
  issueInvite,
  issueReconnect,
  join,
  joinRaw,
  operatorSecret,
  secretForms,
} from "./helpers";

describe("League storage", () => {
  it("keeps a schema version", async () => {
    await createGroup();
    const tables = await dumpTables();
    expect(tables.meta).toContainEqual({ key: "schema_version", value: "1" });
  });

  it("holds no raw secret, IP or departed email anywhere", async () => {
    const secrets: string[] = [operatorSecret(), env.CODE_PEPPER ?? ""];
    const ips = [freshIp(), freshIp(), freshIp(), freshIp()];

    const host = await createGroup({ ip: ips[0] });
    secrets.push(host.accessKey, host.recoveryCode);
    const invite = await issueInvite(host.accessKey);
    secrets.push(invite.inviteCode);

    const stayEmail = freshEmail("Stays");
    const leaveEmail = freshEmail("Leaves");
    const removeEmail = freshEmail("Removed");
    const stays = await join(invite.inviteCode, stayEmail, ips[1]);
    const leaves = await join(invite.inviteCode, leaveEmail, ips[1]);
    const removed = await join(invite.inviteCode, removeEmail, ips[1]);
    secrets.push(stays.accessKey, stays.recoveryCode, leaves.accessKey, leaves.recoveryCode, removed.accessKey, removed.recoveryCode);

    // Failed attempts with submitted values that must not be stored either.
    const fakeInvite = "QQQQ-RRRR-SSSS";
    const fakeCode = "WWWW-XXXX-YYYY-ZZZZ";
    secrets.push(fakeInvite, fakeCode);
    await joinRaw(fakeInvite, freshEmail(), ips[2]);
    await call("POST", "/v1/recover", { ip: ips[2], body: { recoveryCode: fakeCode } });
    await call("POST", "/v1/reconnect", { ip: ips[2], body: { reconnectCode: fakeCode } });
    await call("POST", "/v1/groups", {
      ip: ips[3],
      body: { operatorSecret: "operator-wrong-value-xxxxxxxxxxxxxxxxx", groupName: "G", displayEmail: freshEmail() },
    });

    const recovered = await call("POST", "/v1/recover", { body: { recoveryCode: stays.recoveryCode } });
    secrets.push(recovered.body.accessKey, recovered.body.recoveryCode);
    const pending = await issueReconnect(host.accessKey, stays.trainerId);
    const used = await issueReconnect(host.accessKey, stays.trainerId);
    secrets.push(pending, used);
    const reconnected = await call("POST", "/v1/reconnect", { body: { reconnectCode: used } });
    secrets.push(reconnected.body.accessKey, reconnected.body.recoveryCode);

    await call("POST", "/v1/leave", { key: leaves.accessKey });
    await call("POST", "/v1/members/remove", { key: host.accessKey, body: { trainerId: removed.trainerId } });

    const tables = await dumpTables();
    // The scan is not vacuous: the expected tables exist and hold this scenario's rows.
    for (const name of ["meta", "groups", "trainers", "invites", "reconnect_codes", "audit", "attempts"]) {
      expect(Object.keys(tables)).toContain(name);
    }
    const trainerIds = tables.trainers!.map((r) => r.id);
    expect(trainerIds).toEqual(expect.arrayContaining([host.trainerId, stays.trainerId, leaves.trainerId, removed.trainerId]));
    expect(tables.attempts!.length).toBeGreaterThan(0);

    const dump = JSON.stringify(tables);
    const dumpLower = dump.toLowerCase();
    for (const secret of secrets.filter((s) => s.length > 0)) {
      for (const form of secretForms(secret)) {
        expect(dumpLower.includes(form.toLowerCase()), "raw secret in storage").toBe(false);
      }
    }
    for (const ip of ips) expect(dumpLower.includes(ip.toLowerCase()), "raw IP in storage").toBe(false);

    expect(dumpLower).toContain(stayEmail.toLowerCase());
    expect(dumpLower.includes(leaveEmail.toLowerCase()), "left member email kept").toBe(false);
    expect(dumpLower.includes(removeEmail.toLowerCase()), "removed member email kept").toBe(false);
  });
});
