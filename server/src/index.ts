import { accessKeyHash } from "./access";
import type { Result } from "./contract";
import {
  ApiError,
  type Body,
  errorResponse,
  json,
  optionalInteger,
  parseDisplayEmail,
  parseGroupName,
  readJsonObject,
  requireString,
} from "./http";
import type { League, NewCredentials } from "./league";
import {
  INVITE_CODE_LENGTH,
  RECONNECT_CODE_LENGTH,
  RECOVERY_CODE_LENGTH,
  newAccessKey,
  newCode,
  normalizeCode,
  pepperedHash,
  secretsEqual,
  sha256Hex,
} from "./secrets";

export { League } from "./league";

const OPERATOR_SECRET_MIN_LENGTH = 32;
const HOUR_S = 3600;
const DAY_S = 24 * HOUR_S;

interface Context {
  request: Request;
  env: Env;
  league: DurableObjectStub<League>;
}

/** CODE_PEPPER, required by every route that hashes a code or an IP. */
function pepper(ctx: Context): string {
  const value = ctx.env.CODE_PEPPER;
  if (!value) throw new ApiError("internal");
  return value;
}

type Handler = (ctx: Context) => Promise<Response>;

function unwrap<T>(result: Result<T>): T {
  if (!result.ok) throw new ApiError(result.code, result.retryAfter);
  return result.value;
}

async function ipHashOf(ctx: Context): Promise<string> {
  return pepperedHash(pepper(ctx), "ip", ctx.request.headers.get("cf-connecting-ip") ?? "unknown");
}

async function codeHashOf(
  ctx: Context,
  domain: "invite" | "recovery" | "reconnect",
  raw: string,
  length: number,
): Promise<string | null> {
  const code = normalizeCode(raw, length);
  return code === null ? null : pepperedHash(pepper(ctx), domain, code);
}

interface Issued {
  accessKey: string;
  recoveryCode: string;
  hashes: NewCredentials;
}

async function issueCredentials(ctx: Context): Promise<Issued> {
  const accessKey = newAccessKey();
  const recoveryCode = newCode(RECOVERY_CODE_LENGTH);
  const [keyHash, recoveryHash] = await Promise.all([
    sha256Hex(accessKey),
    pepperedHash(pepper(ctx), "recovery", normalizeCode(recoveryCode, RECOVERY_CODE_LENGTH)!),
  ]);
  return { accessKey, recoveryCode, hashes: { keyHash, recoveryHash } };
}

function withCredentials<T extends object>(value: T, issued: Issued): Response {
  return json(200, { ...value, accessKey: issued.accessKey, recoveryCode: issued.recoveryCode });
}

/**
 * Operator routes are off (operator_disabled) unless OPERATOR_SECRET is set and at least
 * 32 characters; that check comes before the body is read.
 */
async function operatorRequest(ctx: Context): Promise<{ body: Body; configured: string }> {
  const configured = ctx.env.OPERATOR_SECRET;
  if (!configured || configured.length < OPERATOR_SECRET_MIN_LENGTH) throw new ApiError("operator_disabled");
  return { body: await readJsonObject(ctx.request), configured };
}

function optionalEmail(body: Body) {
  return body.displayEmail === undefined ? null : parseDisplayEmail(body.displayEmail);
}

const routes: Record<string, Partial<Record<string, Handler>>> = {
  "/v1/health": {
    GET: async () => json(200, { ok: true, api: 1 }),
  },

  "/v1/groups": {
    POST: async (ctx) => {
      const { body, configured } = await operatorRequest(ctx);
      const submitted = requireString(body, "operatorSecret");
      const groupName = parseGroupName(body.groupName);
      const email = parseDisplayEmail(body.displayEmail);
      const [operatorOk, ipHash, issued] = await Promise.all([
        secretsEqual(submitted, configured),
        ipHashOf(ctx),
        issueCredentials(ctx),
      ]);
      const grant = unwrap(
        await ctx.league.createGroup({ ipHash, operatorOk, groupName, email, credentials: issued.hashes }),
      );
      return withCredentials(grant, issued);
    },
  },

  "/v1/operator/host-reconnect": {
    POST: async (ctx) => {
      const { body, configured } = await operatorRequest(ctx);
      const submitted = requireString(body, "operatorSecret");
      const groupId = requireString(body, "groupId");
      const reconnectCode = newCode(RECONNECT_CODE_LENGTH);
      const [operatorOk, ipHash, codeHash] = await Promise.all([
        secretsEqual(submitted, configured),
        ipHashOf(ctx),
        codeHashOf(ctx, "reconnect", reconnectCode, RECONNECT_CODE_LENGTH),
      ]);
      const issued = unwrap(await ctx.league.operatorHostReconnect({ ipHash, operatorOk, groupId, codeHash: codeHash! }));
      return json(200, { trainerId: issued.trainerId, reconnectCode, expiresAt: issued.expiresAt });
    },
  },

  "/v1/join": {
    POST: async (ctx) => {
      const body = await readJsonObject(ctx.request);
      const inviteCode = requireString(body, "inviteCode");
      const email = parseDisplayEmail(body.displayEmail);
      const [inviteHash, ipHash, issued] = await Promise.all([
        codeHashOf(ctx, "invite", inviteCode, INVITE_CODE_LENGTH),
        ipHashOf(ctx),
        issueCredentials(ctx),
      ]);
      const grant = unwrap(await ctx.league.join({ ipHash, inviteHash, email, credentials: issued.hashes }));
      return withCredentials(grant, issued);
    },
  },

  "/v1/me": {
    GET: async (ctx) => json(200, unwrap(await ctx.league.me({ keyHash: await accessKeyHash(ctx.request) }))),
  },

  "/v1/group": {
    GET: async (ctx) => json(200, unwrap(await ctx.league.group({ keyHash: await accessKeyHash(ctx.request) }))),
  },

  "/v1/audit": {
    GET: async (ctx) => json(200, unwrap(await ctx.league.audit({ keyHash: await accessKeyHash(ctx.request) }))),
  },

  "/v1/invites": {
    GET: async (ctx) => json(200, unwrap(await ctx.league.listInvites({ keyHash: await accessKeyHash(ctx.request) }))),
    POST: async (ctx) => {
      const keyHash = await accessKeyHash(ctx.request);
      const body = await readJsonObject(ctx.request);
      const ttlSeconds = optionalInteger(body, "ttlSeconds", HOUR_S, 30 * DAY_S, 7 * DAY_S);
      const maxUses = optionalInteger(body, "maxUses", 1, 100, 30);
      const inviteCode = newCode(INVITE_CODE_LENGTH);
      const inviteHash = (await codeHashOf(ctx, "invite", inviteCode, INVITE_CODE_LENGTH))!;
      const invite = unwrap(await ctx.league.createInvite({ keyHash, inviteHash, ttlMs: ttlSeconds * 1000, maxUses }));
      return json(200, { invite, inviteCode });
    },
  },

  "/v1/invites/revoke": {
    POST: async (ctx) => {
      const keyHash = await accessKeyHash(ctx.request);
      const inviteId = requireString(await readJsonObject(ctx.request), "inviteId");
      return json(200, { invite: unwrap(await ctx.league.revokeInvite({ keyHash, inviteId })) });
    },
  },

  "/v1/recover": {
    POST: async (ctx) => {
      const recoveryCode = requireString(await readJsonObject(ctx.request), "recoveryCode");
      const [recoveryHash, ipHash, issued] = await Promise.all([
        codeHashOf(ctx, "recovery", recoveryCode, RECOVERY_CODE_LENGTH),
        ipHashOf(ctx),
        issueCredentials(ctx),
      ]);
      const grant = unwrap(await ctx.league.recover({ ipHash, recoveryHash, credentials: issued.hashes }));
      return withCredentials(grant, issued);
    },
  },

  "/v1/reconnect-codes": {
    POST: async (ctx) => {
      const keyHash = await accessKeyHash(ctx.request);
      const trainerId = requireString(await readJsonObject(ctx.request), "trainerId");
      const reconnectCode = newCode(RECONNECT_CODE_LENGTH);
      const codeHash = (await codeHashOf(ctx, "reconnect", reconnectCode, RECONNECT_CODE_LENGTH))!;
      const issued = unwrap(await ctx.league.issueReconnectCode({ keyHash, trainerId, codeHash }));
      return json(200, { trainerId: issued.trainerId, reconnectCode, expiresAt: issued.expiresAt });
    },
  },

  "/v1/reconnect": {
    POST: async (ctx) => {
      const body = await readJsonObject(ctx.request);
      const reconnectCode = requireString(body, "reconnectCode");
      const email = optionalEmail(body);
      const [codeHash, ipHash, issued] = await Promise.all([
        codeHashOf(ctx, "reconnect", reconnectCode, RECONNECT_CODE_LENGTH),
        ipHashOf(ctx),
        issueCredentials(ctx),
      ]);
      const grant = unwrap(await ctx.league.reconnect({ ipHash, codeHash, email, credentials: issued.hashes }));
      return withCredentials(grant, issued);
    },
  },

  "/v1/leave": {
    POST: async (ctx) => {
      const keyHash = await accessKeyHash(ctx.request);
      await readJsonObject(ctx.request);
      return json(200, unwrap(await ctx.league.leave({ keyHash })));
    },
  },

  "/v1/members/remove": {
    POST: async (ctx) => {
      const keyHash = await accessKeyHash(ctx.request);
      const trainerId = requireString(await readJsonObject(ctx.request), "trainerId");
      return json(200, unwrap(await ctx.league.removeMember({ keyHash, trainerId })));
    },
  },

  "/v1/host/transfer": {
    POST: async (ctx) => {
      const keyHash = await accessKeyHash(ctx.request);
      const trainerId = requireString(await readJsonObject(ctx.request), "trainerId");
      return json(200, unwrap(await ctx.league.transferHost({ keyHash, trainerId })));
    },
  },
};

const LOGGED_METHODS = new Set(["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]);

async function route(request: Request, env: Env, path: string): Promise<Response> {
  const methods = Object.hasOwn(routes, path) ? routes[path] : undefined;
  if (!methods) return errorResponse("not_found");
  const handler = methods[request.method];
  if (!handler) return errorResponse("method_not_allowed", { allow: Object.keys(methods).join(", ") });
  try {
    const league = env.LEAGUE.get(env.LEAGUE.idFromName("league"));
    return await handler({ request, env, league });
  } catch (error) {
    if (error instanceof ApiError) return errorResponse(error.code, {}, error.retryAfter);
    return errorResponse("internal");
  }
}

export default {
  async fetch(request, env): Promise<Response> {
    const started = Date.now();
    const path = new URL(request.url).pathname;
    const response = await route(request, env, path);
    // One line per request: method, route template, status, duration. Nothing a client sent beyond that.
    console.log(
      JSON.stringify({
        method: LOGGED_METHODS.has(request.method) ? request.method : "OTHER",
        route: Object.hasOwn(routes, path) ? path : "unmatched",
        status: response.status,
        ms: Date.now() - started,
      }),
    );
    return response;
  },
} satisfies ExportedHandler<Env>;
