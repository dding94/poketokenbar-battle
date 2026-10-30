import { env, exports } from "cloudflare:workers";
import { createExecutionContext, runInDurableObject, waitOnExecutionContext } from "cloudflare:test";
import { afterEach, expect } from "vitest";
import worker from "../src/index";
import type { League } from "../src/league";

// Storage is shared by every test in a file (one League DO), so each test builds
// its own group, emails and client IPs, and the clock is restored after each test.

export const BASE = "https://league.test";
export const MINUTE = 60_000;
export const HOUR = 60 * MINUTE;
export const DAY = 24 * HOUR;

export const KEY_RE = /^ptbk_[A-Za-z0-9_-]{43}$/;
const C = "[0-9A-HJKMNP-TV-Z]";
export const RECOVERY_RE = new RegExp(`^${C}{4}-${C}{4}-${C}{4}-${C}{4}$`);
export const INVITE_RE = new RegExp(`^${C}{4}-${C}{4}-${C}{4}$`);
export const RECONNECT_RE = RECOVERY_RE;

const runTag = crypto.randomUUID().slice(0, 8);
let counter = 0;
function next(): number {
  counter += 1;
  return counter;
}

/** A client IP no other test uses. */
export function freshIp(): string {
  return `2001:db8:${runTag.slice(0, 4)}:${runTag.slice(4, 8)}::${next().toString(16)}`;
}

/** An email no other test uses. */
export function freshEmail(label = "trainer"): string {
  return `${label}-${runTag}-${next()}@example.test`;
}

export interface CallOptions {
  body?: unknown;
  /** Sent as-is instead of JSON-encoding `body`. */
  rawBody?: string;
  key?: string;
  authorization?: string;
  ip?: string;
  /** null sends no content-type header. */
  contentType?: string | null;
  /** Replaces bindings for this one request by calling the handler directly. */
  envOverride?: Partial<Env>;
}

export interface ApiResponse {
  status: number;
  headers: Headers;
  text: string;
  body: any;
}

export async function call(method: string, path: string, opts: CallOptions = {}): Promise<ApiResponse> {
  const headers = new Headers();
  headers.set("cf-connecting-ip", opts.ip ?? freshIp());
  let payload: string | undefined;
  if (opts.rawBody !== undefined) payload = opts.rawBody;
  else if (opts.body !== undefined) payload = JSON.stringify(opts.body);
  if (payload !== undefined) {
    const ct = opts.contentType === undefined ? "application/json" : opts.contentType;
    if (ct !== null) headers.set("content-type", ct);
  }
  if (opts.authorization !== undefined) headers.set("authorization", opts.authorization);
  else if (opts.key !== undefined) headers.set("authorization", `Bearer ${opts.key}`);

  const request = new Request(`${BASE}${path}`, { method, headers, body: payload });
  let response: Response;
  if (opts.envOverride) {
    const ctx = createExecutionContext();
    const handler = worker as unknown as {
      fetch(req: Request, env: Env, ctx: ExecutionContext): Promise<Response>;
    };
    response = await handler.fetch(request, { ...env, ...opts.envOverride } as Env, ctx);
    await waitOnExecutionContext(ctx);
  } else {
    response = await exports.default.fetch(request);
  }
  const text = await response.text();
  let body: unknown = undefined;
  try {
    body = JSON.parse(text);
  } catch {
    body = undefined;
  }
  return { status: response.status, headers: response.headers, text, body };
}

export function expectError(res: ApiResponse, status: number, code: string): void {
  expect({ status: res.status, body: res.body }).toEqual({ status, body: { error: { code } } });
}

export function operatorSecret(): string {
  const secret = env.OPERATOR_SECRET;
  if (!secret) throw new Error("test binding OPERATOR_SECRET missing");
  return secret;
}

export interface Account {
  trainerId: string;
  accessKey: string;
  recoveryCode: string;
  email: string;
  groupId: string;
}

function account(res: ApiResponse, email: string): Account {
  expect(res.status, res.text).toBe(200);
  return {
    trainerId: res.body.trainer.trainerId,
    accessKey: res.body.accessKey,
    recoveryCode: res.body.recoveryCode,
    email,
    groupId: res.body.group.groupId,
  };
}

export async function createGroup(opts: { groupName?: string; email?: string; ip?: string } = {}): Promise<Account> {
  const email = opts.email ?? freshEmail("host");
  const res = await call("POST", "/v1/groups", {
    body: { operatorSecret: operatorSecret(), groupName: opts.groupName ?? `Group ${next()}`, displayEmail: email },
    ip: opts.ip,
  });
  return account(res, email);
}

export async function issueInvite(hostKey: string, opts: { ttlSeconds?: number; maxUses?: number } = {}): Promise<{ inviteCode: string; inviteId: string; invite: any }> {
  const res = await call("POST", "/v1/invites", { key: hostKey, body: opts });
  expect(res.status, res.text).toBe(200);
  return { inviteCode: res.body.inviteCode, inviteId: res.body.invite.inviteId, invite: res.body.invite };
}

export async function joinRaw(inviteCode: string, email: string, ip?: string): Promise<ApiResponse> {
  return call("POST", "/v1/join", { body: { inviteCode, displayEmail: email }, ip });
}

export async function join(inviteCode: string, email = freshEmail("member"), ip?: string): Promise<Account> {
  return account(await joinRaw(inviteCode, email, ip), email);
}

export interface Fixture {
  host: Account;
  members: Account[];
  inviteCode: string;
  inviteId: string;
}

/** A group with a host and `memberCount` members, all with unique emails. */
export async function setupGroup(memberCount = 1): Promise<Fixture> {
  const host = await createGroup();
  const { inviteCode, inviteId } = await issueInvite(host.accessKey);
  const members: Account[] = [];
  for (let i = 0; i < memberCount; i += 1) members.push(await join(inviteCode));
  return { host, members, inviteCode, inviteId };
}

export async function recoverAccount(acc: Account): Promise<Account> {
  const res = await call("POST", "/v1/recover", { body: { recoveryCode: acc.recoveryCode } });
  return account(res, acc.email);
}

export async function issueReconnect(hostKey: string, trainerId: string): Promise<string> {
  const res = await call("POST", "/v1/reconnect-codes", { key: hostKey, body: { trainerId } });
  expect(res.status, res.text).toBe(200);
  return res.body.reconnectCode;
}

export function leagueStub(): DurableObjectStub<League> {
  return env.LEAGUE.get(env.LEAGUE.idFromName("league"));
}

export async function nowInLeague(): Promise<number> {
  return runInDurableObject(leagueStub(), (instance: League) => instance.clock());
}

export async function setClock(ms: number): Promise<void> {
  await runInDurableObject(leagueStub(), (instance: League) => {
    instance.clock = () => ms;
  });
}

/** Freezes the league clock at its current time plus `ms`. */
export async function advanceClock(ms: number): Promise<number> {
  return runInDurableObject(leagueStub(), (instance: League) => {
    const target = instance.clock() + ms;
    instance.clock = () => target;
    return target;
  });
}

export async function restoreClock(): Promise<void> {
  await runInDurableObject(leagueStub(), (instance: League) => {
    instance.clock = () => Date.now();
  });
}

/** Restores the real clock after every test in the calling file. */
export function useRealClockAfterEach(): void {
  afterEach(async () => {
    await restoreClock();
  });
}

export type Row = Record<string, unknown>;

/** Every row of every table in the League DO's SQLite database. */
export async function dumpTables(): Promise<Record<string, Row[]>> {
  return runInDurableObject(leagueStub(), (_instance: League, state: DurableObjectState) => {
    const sql = state.storage.sql;
    const names = sql
      .exec<{ name: string }>("SELECT name FROM sqlite_master WHERE type = 'table'")
      .toArray()
      .map((r) => r.name);
    const out: Record<string, Row[]> = {};
    for (const name of names) {
      try {
        out[name] = sql.exec(`SELECT * FROM "${name.replaceAll('"', '""')}"`).toArray() as Row[];
      } catch {
        // Internal tables the runtime refuses to expose to user code.
      }
    }
    return out;
  });
}

/** Spellings of a secret a careless implementation might store or print. */
export function secretForms(secret: string): string[] {
  const compact = secret.replace(/[-\s]/g, "");
  return [...new Set([secret, compact, compact.toLowerCase(), secret.toLowerCase()])];
}
