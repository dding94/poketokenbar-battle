// Testable parts of bootstrap-group.mjs. No Node APIs: fetch is injected.
//
// Error text never repeats an argument, the secret, an access key or a server message, so a
// mistyped value cannot end up in a terminal log.

export const USAGE =
  "usage: OPERATOR_SECRET is read from the environment (read -rs OPERATOR_SECRET; export OPERATOR_SECRET)\n" +
  "  node server/scripts/bootstrap-group.mjs <baseUrl> <groupName> <hostNickname>";

const LOCAL_HOSTS = new Set(["localhost", "127.0.0.1", "[::1]"]);

// These three match the server (src/http.ts, src/index.ts), so a bad value fails here with its reason.
// test/bootstrap-group.test.ts runs both sides on the same inputs.
const OPERATOR_SECRET_MIN_LENGTH = 32;
const FORBIDDEN_IN_NICKNAME = /[\s\p{Cc}\p{Cf}\p{Default_Ignorable_Code_Point}⠀]/u;
const FORBIDDEN_IN_GROUP_NAME = /[\p{Cc}\p{Cf}]/u;

/**
 * @param {string} text
 * @param {number} max
 * @param {RegExp} forbidden
 */
function validText(text, max, forbidden) {
  const value = text.trim().normalize("NFKC");
  const length = [...value].length;
  return length >= 1 && length <= max && !forbidden.test(value);
}

/** Static text only: nothing here comes from the server or the arguments. */
const FAILURE_HINTS = {
  operator_denied: "OPERATOR_SECRET does not match the value set on this Worker.",
  operator_disabled: `this Worker has no OPERATOR_SECRET of at least ${OPERATOR_SECRET_MIN_LENGTH} characters. Set it with wrangler secret put.`,
  bad_request: "the server refused the group name or host nickname. See the rules in server/README.md.",
  too_many_attempts: "too many failed attempts from this address. Please wait before trying again.",
};

/**
 * @typedef {{ baseUrl: string, groupName: string, nickname: string, operatorSecret: string }} Options
 */

/** @param {string} text */
function parseBaseUrl(text) {
  let url;
  try {
    url = new URL(text);
  } catch {
    throw new Error(`the base URL is missing or not a valid URL\n${USAGE}`);
  }
  if (url.protocol !== "https:" && !(url.protocol === "http:" && LOCAL_HOSTS.has(url.hostname))) {
    throw new Error(`the base URL must be https (http only for localhost)\n${USAGE}`);
  }
  if (url.username || url.password || url.search || url.hash) {
    throw new Error(`the base URL must not carry credentials, a query or a fragment\n${USAGE}`);
  }
  return url.toString().replace(/\/+$/, "");
}

/**
 * @param {string[]} argv
 * @param {Record<string, string | undefined>} env
 * @returns {Options}
 */
export function parseArgs(argv, env) {
  if (argv.length !== 3) throw new Error(`expected <baseUrl> <groupName> <hostNickname>\n${USAGE}`);
  const [rawUrl, groupName, nickname] = /** @type {[string, string, string]} */ (argv);
  const baseUrl = parseBaseUrl(rawUrl);
  if (!validText(groupName, 40, FORBIDDEN_IN_GROUP_NAME)) {
    throw new Error(`the group name must be 1 to 40 characters with no control characters\n${USAGE}`);
  }
  if (!validText(nickname, 254, FORBIDDEN_IN_NICKNAME)) {
    throw new Error(`the host nickname must be 1 to 254 characters with no spaces or invisible characters\n${USAGE}`);
  }
  const operatorSecret = env.OPERATOR_SECRET;
  if (!operatorSecret) throw new Error(`OPERATOR_SECRET is not set in the environment\n${USAGE}`);
  if (operatorSecret.length < OPERATOR_SECRET_MIN_LENGTH) {
    throw new Error(`OPERATOR_SECRET must be at least ${OPERATOR_SECRET_MIN_LENGTH} characters: the server turns shorter ones off\n${USAGE}`);
  }
  return { baseUrl, groupName, nickname, operatorSecret };
}

/**
 * The secret travels in the JSON body only. The server still names the nickname field
 * `displayEmail` (legacy name).
 * @param {Options} options
 * @returns {{ url: string, init: RequestInit }}
 */
export function buildRequest(options) {
  return {
    url: `${options.baseUrl}/v1/groups`,
    init: {
      method: "POST",
      // A redirect would resend the secret to wherever it points. The Worker never answers with one.
      redirect: "error",
      headers: { accept: "application/json", "content-type": "application/json" },
      body: JSON.stringify({
        operatorSecret: options.operatorSecret,
        groupName: options.groupName,
        displayEmail: options.nickname,
      }),
    },
  };
}

/** @param {unknown} value */
function asRecord(value) {
  return value !== null && typeof value === "object" ? /** @type {Record<string, unknown>} */ (value) : {};
}

/**
 * Picks the three values the operator needs. The access key in the response is ignored.
 * @param {unknown} body
 * @returns {string | null} null when the response lacks a recovery code
 */
export function formatSuccess(body) {
  const data = asRecord(body);
  const recoveryCode = data.recoveryCode;
  if (typeof recoveryCode !== "string" || recoveryCode === "") return null;
  const groupId = asRecord(data.group).groupId;
  const trainerId = asRecord(data.trainer).trainerId;
  return [
    `group id:        ${typeof groupId === "string" ? groupId : "(unknown)"}`,
    `host trainer id: ${typeof trainerId === "string" ? trainerId : "(unknown)"}`,
    `RECOVERY CODE:   ${recoveryCode}`,
    "Shown once. Paste the recovery code into the app's recovery field to connect as host.",
  ].join("\n");
}

/**
 * Only the server's error code is printed, and only when it looks like one.
 * @param {number} status
 * @param {unknown} body
 */
export function formatFailure(status, body) {
  const code = asRecord(asRecord(body).error).code;
  if (typeof code === "string" && /^[a-z0-9_]{1,64}$/.test(code)) {
    const hint = Object.hasOwn(FAILURE_HINTS, code) ? FAILURE_HINTS[/** @type {keyof typeof FAILURE_HINTS} */ (code)] : null;
    return hint ? `server error: ${code}: ${hint}` : `server error: ${code}`;
  }
  return `server error: HTTP ${status} without an error code. Check that the base URL is this Worker.`;
}

/**
 * @param {Options} options
 * @param {typeof fetch} fetchImpl
 * @returns {Promise<{ ok: boolean, text: string }>}
 */
export async function bootstrapGroup(options, fetchImpl) {
  const { url, init } = buildRequest(options);
  let res;
  try {
    res = await fetchImpl(url, { ...init, signal: AbortSignal.timeout(15_000) });
  } catch {
    return { ok: false, text: "request failed: could not reach the server. Check the base URL; a redirect is refused so the secret goes nowhere else." };
  }
  /** @type {unknown} */
  let body = null;
  try {
    body = await res.json();
  } catch {
    body = null;
  }
  if (!res.ok) return { ok: false, text: formatFailure(res.status, body) };
  const text = formatSuccess(body);
  if (text === null) return { ok: false, text: "server answered without a recovery code" };
  return { ok: true, text };
}
