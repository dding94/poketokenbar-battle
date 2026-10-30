import { describe, expect, it } from "vitest";
import { attemptBucket } from "../src/ip";
import { type ApiResponse, expectError, freshEmail, joinRaw } from "./helpers";

describe("attemptBucket", () => {
  it("groups IPv6 addresses by /64, whatever the spelling", () => {
    const bucket = attemptBucket("2001:db8::1");
    for (const same of [
      "2001:db8:0:0:ffff::2",
      "2001:0db8:0000:0000:0000:0000:0000:0001",
      "2001:DB8::abcd:ef01:2345:6789",
      "2001:db8:0::1:2:3",
      "2001:db8:0:0:1:2:3:4",
      "2001:db8::",
      "2001:db8::1%eth0",
      "2001:db8::ffff:192.0.2.1",
    ]) {
      expect(attemptBucket(same), same).toBe(bucket);
    }
    for (const other of ["2001:db8:0:1::1", "2001:db9::1", "2001:db8:1::", "::1", "::"]) {
      expect(attemptBucket(other), other).not.toBe(bucket);
    }
  });

  it("counts IPv4 and IPv4-mapped IPv6 per address", () => {
    expect(attemptBucket("192.0.2.7")).toBe("192.0.2.7");
    expect(attemptBucket("::ffff:192.0.2.7")).toBe("192.0.2.7");
    expect(attemptBucket("::FFFF:c000:0207")).toBe("192.0.2.7");
    expect(attemptBucket("0:0:0:0:0:ffff:192.0.2.7")).toBe("192.0.2.7");
    expect(attemptBucket("192.0.2.8")).not.toBe(attemptBucket("192.0.2.7"));
    expect(attemptBucket("::ffff:192.0.2.8")).not.toBe(attemptBucket("::ffff:192.0.2.7"));
  });

  it("keeps anything it cannot parse as its own bucket", () => {
    for (const odd of ["unknown", "2001:db8::1::2", "1:2:3:4:5:6:7:8:9", "2001:db8::g", "", "::ffff:300.1.1.1"]) {
      expect(attemptBucket(odd), odd).toBe(odd);
    }
    // Junk never lands in a real address's bucket.
    expect(attemptBucket("2001:db8::1::2")).not.toBe(attemptBucket("2001:db8::1"));
  });
});

describe("attempt limits by bucket", () => {
  async function failInvite(ip: string): Promise<ApiResponse> {
    return joinRaw("ZZZZ-ZZZZ-ZZZZ", freshEmail(), ip);
  }

  it("shares one IPv6 /64 across addresses and spellings", async () => {
    for (let i = 0; i < 10; i += 1) expectError(await failInvite(`2001:db8:77::${(i + 1).toString(16)}`), 404, "invalid_invite");
    expectError(await failInvite("2001:db8:77:0:ffff::2"), 429, "too_many_attempts");
    expectError(await failInvite("2001:0db8:0077:0000:0000:0000:0000:0001"), 429, "too_many_attempts");
    expectError(await failInvite("2001:db8:77:1::1"), 404, "invalid_invite");
  });

  it("counts an IPv4 address and its IPv4-mapped form together, and IPv4 per address", async () => {
    for (let i = 0; i < 5; i += 1) expectError(await failInvite("198.51.100.50"), 404, "invalid_invite");
    for (let i = 0; i < 5; i += 1) expectError(await failInvite("::ffff:198.51.100.50"), 404, "invalid_invite");
    expectError(await failInvite("198.51.100.50"), 429, "too_many_attempts");
    expectError(await failInvite("::ffff:c633:6432"), 429, "too_many_attempts");
    expectError(await failInvite("198.51.100.51"), 404, "invalid_invite");
  });
});
