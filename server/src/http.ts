import { ERROR_STATUS, type ErrorCode } from "./contract";

export const MAX_BODY_BYTES = 4096;

/** Carries only a fixed code, so nothing a client sent can reach a response or a log. */
export class ApiError extends Error {
  constructor(
    readonly code: ErrorCode,
    readonly retryAfter?: number,
  ) {
    super(code);
  }
}

const BASE_HEADERS = {
  "content-type": "application/json; charset=utf-8",
  "cache-control": "no-store",
  "x-content-type-options": "nosniff",
};

export function json(status: number, body: unknown, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...BASE_HEADERS, ...extra } });
}

export function errorResponse(code: ErrorCode, extra: Record<string, string> = {}, retryAfter?: number): Response {
  const headers = retryAfter === undefined ? extra : { ...extra, "retry-after": String(retryAfter) };
  return json(ERROR_STATUS[code], { error: { code } }, headers);
}

async function readLimited(request: Request): Promise<Uint8Array> {
  const declared = request.headers.get("content-length");
  if (declared !== null && Number(declared) > MAX_BODY_BYTES) throw new ApiError("payload_too_large");
  if (request.body === null) return new Uint8Array();
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > MAX_BODY_BYTES) {
      await reader.cancel();
      throw new ApiError("payload_too_large");
    }
    chunks.push(value);
  }
  const out = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    out.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return out;
}

function isJsonContentType(value: string | null): boolean {
  return value !== null && value.split(";")[0]!.trim().toLowerCase() === "application/json";
}

export type Body = Record<string, unknown>;

/** A JSON object body of at most 4 KB. An empty body reads as `{}`. */
export async function readJsonObject(request: Request): Promise<Body> {
  const bytes = await readLimited(request);
  if (bytes.byteLength === 0) return {};
  if (!isJsonContentType(request.headers.get("content-type"))) throw new ApiError("unsupported_media_type");
  let parsed: unknown;
  try {
    parsed = JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes));
  } catch {
    throw new ApiError("bad_request");
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) throw new ApiError("bad_request");
  return parsed as Body;
}

export function requireString(body: Body, field: string): string {
  const value = body[field];
  if (typeof value !== "string") throw new ApiError("bad_request");
  return value;
}

export function optionalInteger(body: Body, field: string, min: number, max: number, fallback: number): number {
  const value = body[field];
  if (value === undefined) return fallback;
  if (typeof value !== "number" || !Number.isInteger(value) || value < min || value > max) {
    throw new ApiError("bad_request");
  }
  return value;
}

// Cc: control characters. Cf: format characters such as zero-width and bidi controls,
// which would let look-alike emails or names pass as distinct. Emails also refuse
// default-ignorable code points (Hangul fillers, variation selectors, CGJ, ...) and the
// blank braille pattern U+2800, which render as nothing. Group names skip that extra check:
// only the operator sets a name, and emoji need variation selectors.
const FORBIDDEN_IN_EMAIL = /[\s\p{Cc}\p{Cf}\p{Default_Ignorable_Code_Point}\u2800]/u;
const FORBIDDEN_IN_NAME = /[\p{Cc}\p{Cf}]/u;

export interface DisplayEmail {
  display: string;
  norm: string;
}

/**
 * Trimmed and NFKC-normalised; 3-254 characters, exactly one `@` with text on both sides,
 * no whitespace, control or format characters. Duplicates compare by lowercase NFKC form.
 */
export function parseDisplayEmail(value: unknown): DisplayEmail {
  if (typeof value !== "string") throw new ApiError("bad_request");
  const display = value.trim().normalize("NFKC");
  const length = [...display].length;
  if (length < 3 || length > 254 || FORBIDDEN_IN_EMAIL.test(display)) throw new ApiError("bad_request");
  const parts = display.split("@");
  if (parts.length !== 2 || parts[0] === "" || parts[1] === "") throw new ApiError("bad_request");
  return { display, norm: display.toLowerCase() };
}

/** Trimmed and NFKC-normalised; 1-40 characters, no control or format characters. */
export function parseGroupName(value: unknown): string {
  if (typeof value !== "string") throw new ApiError("bad_request");
  const name = value.trim().normalize("NFKC");
  const length = [...name].length;
  if (length < 1 || length > 40 || FORBIDDEN_IN_NAME.test(name)) throw new ApiError("bad_request");
  return name;
}
