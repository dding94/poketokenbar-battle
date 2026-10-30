// Pure parts of measure.mjs: argument parsing, the Appendix C reconnect rule and summaries.
// No Node or network APIs here, so the Worker test suite can import it.

/** Reconnect delays are drawn below min(60 s, 1 s × 2^attempt) (full jitter). */
export const BACKOFF_BASE_MS = 1000;
export const BACKOFF_CAP_MS = 60_000;
/** A connection that stayed up this long resets the attempt count. */
export const STABLE_MS = 60_000;

/** @param {number} attempt */
export function backoffCeilingMs(attempt) {
  return Math.min(BACKOFF_CAP_MS, BACKOFF_BASE_MS * 2 ** Math.min(attempt, 30));
}

/**
 * Full jitter: uniform in [0, ceiling).
 * @param {number} attempt
 * @param {() => number} random in [0, 1)
 */
export function backoffDelayMs(attempt, random) {
  return Math.floor(random() * backoffCeilingMs(attempt));
}

/**
 * The attempt number after a drop: back to 1 when the connection had been up for a minute.
 * @param {number} attempt
 * @param {number} connectedMs
 */
export function nextAttempt(attempt, connectedMs) {
  return connectedMs >= STABLE_MS ? 1 : attempt + 1;
}

/**
 * 4003 (revoked) means re-authenticate and 4001 (replaced) means another client took over;
 * the app does not reconnect automatically for either. 4400 is a client bug, so the script
 * stops too instead of looping.
 * @param {number} code
 * @returns {"retry" | "stop"}
 */
export function reconnectDecision(code) {
  return code === 4001 || code === 4003 || code === 4400 ? "stop" : "retry";
}

const OPTIONS = {
  "--members": { key: "members", integer: true, min: 1, max: 99 },
  "--hold-minutes": { key: "holdMinutes", integer: false, min: 0, max: 24 * 60 },
  "--churn": { key: "churn", integer: true, min: 0, max: 99 },
  "--redeploy-wait-minutes": { key: "redeployWaitMinutes", integer: false, min: 0, max: 24 * 60 },
  "--ping-seconds": { key: "pingSeconds", integer: false, min: 1, max: 3600 },
};

const LOCAL_HOSTS = new Set(["localhost", "127.0.0.1", "[::1]"]);

/**
 * @param {string} text
 * @returns {string}
 */
function parseBaseUrl(text) {
  let url;
  try {
    url = new URL(text);
  } catch {
    throw new Error("the base URL is not a valid URL");
  }
  if (url.protocol !== "https:" && !(url.protocol === "http:" && LOCAL_HOSTS.has(url.hostname))) {
    throw new Error("the base URL must be https (http only for localhost)");
  }
  if (url.username || url.password || url.search || url.hash) {
    throw new Error("the base URL must not carry credentials, a query or a fragment");
  }
  return url.toString().replace(/\/+$/, "");
}

/**
 * Parses `<baseUrl> [options]`. Error messages never repeat a value, so a mistyped secret
 * cannot end up in a terminal log.
 * @param {string[]} argv
 */
export function parseArgs(argv) {
  /** @type {{ baseUrl: string, members: number, holdMinutes: number, churn: number, redeployWaitMinutes: number, pingSeconds: number, cleanup: boolean }} */
  const options = {
    baseUrl: "",
    members: 30,
    holdMinutes: 10,
    churn: 5,
    redeployWaitMinutes: 0,
    pingSeconds: 30,
    cleanup: false,
  };
  /** @type {string[]} */
  const positional = [];
  for (let i = 0; i < argv.length; i += 1) {
    const arg = /** @type {string} */ (argv[i]);
    if (arg === "--cleanup") {
      options.cleanup = true;
      continue;
    }
    if (arg.startsWith("--")) {
      const spec = OPTIONS[/** @type {keyof typeof OPTIONS} */ (arg)];
      if (!spec) throw new Error("unknown option (see server/README.md)");
      const raw = argv[i + 1];
      i += 1;
      const value = raw === undefined || raw.trim() === "" ? Number.NaN : Number(raw);
      if (!Number.isFinite(value) || (spec.integer && !Number.isInteger(value)) || value < spec.min || value > spec.max) {
        throw new Error(`${arg} needs ${spec.integer ? "an integer" : "a number"} from ${spec.min} to ${spec.max}`);
      }
      options[spec.key] = value;
      continue;
    }
    positional.push(arg);
  }
  if (positional.length !== 1) throw new Error("expected exactly one argument: the base URL");
  options.baseUrl = parseBaseUrl(/** @type {string} */ (positional[0]));
  if (options.churn > options.members) throw new Error("--churn cannot exceed --members");
  return options;
}

/** @param {number} index 1-based */
export function memberEmail(index) {
  return `m${String(index).padStart(2, "0")}@measure.invalid`;
}

/**
 * Nearest-rank percentiles.
 * @param {number[]} values
 */
export function summarize(values) {
  if (values.length === 0) return { count: 0 };
  const sorted = [...values].sort((a, b) => a - b);
  /** @param {number} p */
  const rank = (p) => /** @type {number} */ (sorted[Math.max(0, Math.ceil(p * sorted.length) - 1)]);
  return {
    count: sorted.length,
    min: sorted[0],
    p50: rank(0.5),
    p90: rank(0.9),
    p99: rank(0.99),
    max: sorted[sorted.length - 1],
  };
}
