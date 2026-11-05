// Testable parts of bootstrap-group.mjs. No Node APIs: fetch is injected.
//
// Error text never repeats an argument, the secret, an access key or a server message, so a
// mistyped value cannot end up in a terminal log.

export const USAGE =
  "usage: OPERATOR_SECRET is read from the environment (read -rs OPERATOR_SECRET; export OPERATOR_SECRET)\n" +
  "  node server/scripts/bootstrap-group.mjs <baseUrl> <groupName> <hostNickname>";

const LOCAL_HOSTS = new Set(["localhost", "127.0.0.1", "[::1]"]);

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
  if (groupName.trim() === "" || nickname.trim() === "") {
    throw new Error(`the group name and host nickname must not be empty\n${USAGE}`);
  }
  const operatorSecret = env.OPERATOR_SECRET;
  if (!operatorSecret) throw new Error(`OPERATOR_SECRET is not set in the environment\n${USAGE}`);
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
  if (typeof code === "string" && /^[a-z0-9_]{1,64}$/.test(code)) return `server error: ${code}`;
  return `server error: HTTP ${status} without an error code`;
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
    return { ok: false, text: "request failed: could not reach the server" };
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
