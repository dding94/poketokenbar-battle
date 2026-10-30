// Raw secret handling. Everything here runs in the Worker only.

const CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
const CROCKFORD_CHAR = /^[0-9A-HJKMNP-TV-Z]+$/;
const ACCESS_KEY_PREFIX = "ptbk_";
// The auth scheme is case-insensitive (RFC 9110); the key itself is not.
const BEARER = /^[Bb][Ee][Aa][Rr][Ee][Rr] (ptbk_[A-Za-z0-9_-]{43})$/;

export const RECOVERY_CODE_LENGTH = 16;
export const INVITE_CODE_LENGTH = 12;
export const RECONNECT_CODE_LENGTH = 16;

export type CodeDomain = "invite" | "recovery" | "reconnect" | "ip";

const encoder = new TextEncoder();

function hex(buffer: ArrayBuffer): string {
  return [...new Uint8Array(buffer)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function base64url(bytes: Uint8Array): string {
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

/** `ptbk_` + 32 random bytes in base64url (43 characters). */
export function newAccessKey(): string {
  return ACCESS_KEY_PREFIX + base64url(crypto.getRandomValues(new Uint8Array(32)));
}

/** Crockford base32, 5 random bits per character, grouped by four with hyphens. */
export function newCode(length: number): string {
  const bytes = crypto.getRandomValues(new Uint8Array(length));
  const chars = [...bytes].map((b) => CROCKFORD[b & 31]);
  const groups: string[] = [];
  for (let i = 0; i < chars.length; i += 4) groups.push(chars.slice(i, i + 4).join(""));
  return groups.join("-");
}

/**
 * Ignores case, hyphens and whitespace, and reads the Crockford aliases O as 0 and I, L as 1.
 * Returns null when the result is not a code of `length`.
 */
export function normalizeCode(input: string, length: number): string | null {
  const compact = input
    .replace(/[\s-]/g, "")
    .toUpperCase()
    .replace(/O/g, "0")
    .replace(/[IL]/g, "1");
  return compact.length === length && CROCKFORD_CHAR.test(compact) ? compact : null;
}

/** The access key from `Authorization: Bearer <key>`, or null when absent or malformed. */
export function bearerKey(header: string | null): string | null {
  if (header === null) return null;
  return BEARER.exec(header)?.[1] ?? null;
}

export async function sha256Hex(value: string): Promise<string> {
  return hex(await crypto.subtle.digest("SHA-256", encoder.encode(value)));
}

const hmacKeys = new Map<string, Promise<CryptoKey>>();

function hmacKey(pepper: string): Promise<CryptoKey> {
  let key = hmacKeys.get(pepper);
  if (!key) {
    key = crypto.subtle.importKey("raw", encoder.encode(pepper), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
    hmacKeys.set(pepper, key);
  }
  return key;
}

/** HMAC-SHA256 with CODE_PEPPER, domain-separated so equal strings of different kinds never collide. */
export async function pepperedHash(pepper: string, domain: CodeDomain, value: string): Promise<string> {
  const signature = await crypto.subtle.sign("HMAC", await hmacKey(pepper), encoder.encode(`${domain}:${value}`));
  return hex(signature);
}

/** Constant-time comparison of two strings of any length, over their SHA-256 digests. */
export async function secretsEqual(a: string, b: string): Promise<boolean> {
  const [da, db] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(a)),
    crypto.subtle.digest("SHA-256", encoder.encode(b)),
  ]);
  return crypto.subtle.timingSafeEqual(da, db);
}
