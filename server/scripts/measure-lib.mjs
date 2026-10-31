// Testable parts of measure.mjs: argument parsing, the Appendix C reconnect rule, summaries and
// the per-member socket loop. No Node APIs here: the WebSocket constructor, clock and timers
// are injected, so the Worker test suite can import and drive it.

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

const LOCAL_LABELS = new Set(["localhost", "127.0.0.1", "[::1]"]);

/**
 * What the summary may say about the target: the Worker name (first host label), never the
 * account's workers.dev subdomain.
 * @param {string} baseUrl
 */
export function targetLabel(baseUrl) {
  const host = new URL(baseUrl).hostname;
  return LOCAL_LABELS.has(host) ? host : /** @type {string} */ (host.split(".")[0]);
}

/**
 * The run options as printed in the summary: the URL reduced to targetLabel.
 * @param {ReturnType<typeof parseArgs>} options
 */
export function summaryOptions(options) {
  const { baseUrl, ...rest } = options;
  return { target: targetLabel(baseUrl), ...rest };
}

/**
 * @param {Record<string, number>} counter
 * @param {string} key
 */
export function increment(counter, key, by = 1) {
  counter[key] = (counter[key] ?? 0) + by;
}

/** Counters shared by every member. Holds no key, code, secret or email. */
export class Stats {
  phase = "setup";
  /** @type {Record<string, { latencies: number[], statuses: Record<string, number> }>} */
  http = {};
  /** @type {Record<string, number>} */
  errors = {};
  connects = { attempts: 0, opened: 0, /** @type {number[]} */ latencies: [] };
  /** @type {Record<string, number>} */
  messages = {};
  pings = { sent: 0, pongs: 0, /** @type {number[]} */ rtt: [] };
  /** @type {Record<string, Record<string, number>>} phase -> close code -> count */
  closes = {};
  /** @type {{ phase: string, code: number, connectedForMs: number }[]} */
  unexpectedDrops = [];
  /** @type {{ phase: string, attempt: number, delayMs: number }[]} */
  reconnects = [];
  /** @type {{ phase: string, durationMs: number, attempts: number }[]} */
  outages = [];
  pollingFallbacks = 0;
  /** @type {Record<string, number>} close code -> members that stopped reconnecting */
  stopped = {};

  /** @param {string} name */
  route(name) {
    this.http[name] ??= { latencies: [], statuses: {} };
    return this.http[name];
  }
}

export const CONNECT_TIMEOUT_MS = 15_000;
export const POLLING_AFTER_FAILURES = 3;
export const POLLING_RETRY_MS = 10 * 60_000;
const WS_OPEN = 1;

/**
 * @typedef {object} MemberEnv
 * @property {new (url: string, init: { headers: Record<string, string> }) => any} WebSocket
 * @property {() => number} now monotonic milliseconds
 * @property {() => number} random in [0, 1)
 * @property {(fn: () => void, ms: number) => any} setTimeout
 * @property {(id: any) => void} clearTimeout
 * @property {(fn: () => void, ms: number) => any} setInterval
 * @property {(id: any) => void} clearInterval
 * @property {number} [connectTimeoutMs]
 */

/**
 * One fake member's socket, following the Appendix C client rule. Events from a socket that is
 * no longer the member's current one (a late close after churn, a timed-out connect) only
 * count as closes; they never touch the current socket's state.
 */
export class Member {
  /** @type {any} */
  socket = null;
  openedAt = 0;
  attempt = 0;
  failures = 0;
  intentionalClose = false;
  stopped = false;
  /** @type {any} */
  pingTimer = null;
  /** @type {any} */
  reconnectTimer = null;
  /** @type {number[]} */
  pingsInFlight = [];
  /** @type {{ startedAt: number, phase: string, attempts: number } | null} */
  outage = null;

  /**
   * @param {string} accessKey kept in memory only; sent as a header, never in the URL
   * @param {{ baseUrl: string, pingSeconds: number }} options
   * @param {Stats} stats
   * @param {MemberEnv} env
   */
  constructor(accessKey, options, stats, env) {
    this.accessKey = accessKey;
    this.options = options;
    this.stats = stats;
    this.env = env;
  }

  get open() {
    return this.socket !== null && this.socket.readyState === WS_OPEN;
  }

  /** Opens a socket; resolves true once open, false on close, timeout or stop. */
  connect() {
    const { env, stats } = this;
    if (this.stopped) return Promise.resolve(false);
    this.cancelReconnect();
    const url = `${this.options.baseUrl.replace(/^http/, "ws")}/v1/connect`;
    const started = env.now();
    stats.connects.attempts += 1;
    this.intentionalClose = false;
    return new Promise((resolve) => {
      let settled = false;
      /** @type {any} */
      let timer = null;
      /** @param {boolean} value */
      const settle = (value) => {
        if (settled) return;
        settled = true;
        if (timer !== null) env.clearTimeout(timer);
        timer = null;
        resolve(value);
      };
      /** @type {any} */
      let ws;
      try {
        ws = new env.WebSocket(url, { headers: { authorization: `Bearer ${this.accessKey}` } });
      } catch {
        increment(stats.errors, "ws_init");
        this.socket = null;
        this.failures += 1;
        settle(false);
        this.scheduleReconnect(0, 0);
        return;
      }
      this.socket = ws;
      // Every listener checks that its socket is still the member's current one: a late event
      // from a replaced socket (closed for churn, or given up after a timeout) must not touch
      // the new socket's timers, open time or reconnect state.
      const current = () => ws === this.socket;

      timer = env.setTimeout(() => {
        timer = null;
        if (!current() || ws.readyState === WS_OPEN) return;
        // Give up on this socket: its later events are stale.
        this.socket = null;
        try {
          ws.close();
        } catch {
          // Not open yet.
        }
        settle(false);
        if (this.intentionalClose) return;
        increment(stats.errors, "connect_timeout");
        this.failures += 1;
        this.scheduleReconnect(0, 0);
      }, env.connectTimeoutMs ?? CONNECT_TIMEOUT_MS);

      ws.addEventListener("open", () => {
        if (!current()) return;
        stats.connects.opened += 1;
        stats.connects.latencies.push(Math.round(env.now() - started));
        this.openedAt = env.now();
        this.failures = 0;
        if (this.outage) {
          stats.outages.push({ phase: this.outage.phase, durationMs: env.now() - this.outage.startedAt, attempts: this.outage.attempts });
          this.outage = null;
        }
        this.startPings();
        settle(true);
      });
      ws.addEventListener("message", (/** @type {{ data: unknown }} */ event) => {
        if (current()) this.onMessage(event.data);
      });
      ws.addEventListener("error", () => increment(stats.errors, current() ? "ws_error" : "ws_error_stale"));
      ws.addEventListener("close", (/** @type {{ code: number }} */ event) => {
        stats.closes[stats.phase] ??= {};
        increment(/** @type {Record<string, number>} */ (stats.closes[stats.phase]), String(event.code));
        settle(false);
        if (!current()) return;
        this.stopPings();
        const wasOpen = this.openedAt > 0;
        const connectedForMs = wasOpen ? env.now() - this.openedAt : 0;
        this.openedAt = 0;
        if (this.intentionalClose) return;
        if (wasOpen) stats.unexpectedDrops.push({ phase: stats.phase, code: event.code, connectedForMs });
        else this.failures += 1;
        this.scheduleReconnect(event.code, connectedForMs);
      });
    });
  }

  /**
   * @param {number} code
   * @param {number} connectedForMs
   */
  scheduleReconnect(code, connectedForMs) {
    const { env, stats } = this;
    if (reconnectDecision(code) === "stop") {
      this.stopped = true;
      increment(stats.stopped, String(code));
      return;
    }
    this.outage ??= { startedAt: env.now(), phase: stats.phase, attempts: 0 };
    this.outage.attempts += 1;
    this.attempt = nextAttempt(this.attempt, connectedForMs);
    let delayMs = backoffDelayMs(this.attempt, env.random);
    if (this.failures >= POLLING_AFTER_FAILURES) {
      // The app would poll now and retry the socket every ten minutes.
      if (this.failures === POLLING_AFTER_FAILURES) stats.pollingFallbacks += 1;
      delayMs = POLLING_RETRY_MS;
    }
    stats.reconnects.push({ phase: stats.phase, attempt: this.attempt, delayMs });
    this.cancelReconnect();
    this.reconnectTimer = env.setTimeout(() => {
      this.reconnectTimer = null;
      void this.connect();
    }, delayMs);
  }

  cancelReconnect() {
    if (this.reconnectTimer !== null) this.env.clearTimeout(this.reconnectTimer);
    this.reconnectTimer = null;
  }

  /** @param {unknown} data */
  onMessage(data) {
    const { stats } = this;
    if (data === "pong") {
      stats.pings.pongs += 1;
      const sentAt = this.pingsInFlight.shift();
      if (sentAt !== undefined) stats.pings.rtt.push(Math.round(this.env.now() - sentAt));
      return;
    }
    /** @type {any} */
    let message = null;
    try {
      message = JSON.parse(String(data));
    } catch {
      increment(stats.messages, "unparseable");
      return;
    }
    const type = typeof message?.type === "string" ? message.type : "unknown";
    if (type === "presence") increment(stats.messages, message.online ? "presence_online" : "presence_offline");
    else increment(stats.messages, type);
  }

  startPings() {
    this.stopPings();
    this.pingTimer = this.env.setInterval(() => {
      if (!this.open) return;
      this.pingsInFlight.push(this.env.now());
      this.stats.pings.sent += 1;
      this.socket.send("ping");
    }, this.options.pingSeconds * 1000);
  }

  stopPings() {
    if (this.pingTimer !== null) this.env.clearInterval(this.pingTimer);
    this.pingTimer = null;
    this.pingsInFlight = [];
  }

  /** Closes on purpose: no reconnect follows. */
  close() {
    this.intentionalClose = true;
    this.cancelReconnect();
    this.stopPings();
    this.openedAt = 0;
    try {
      this.socket?.close(1000, "measure");
    } catch {
      // Already closed.
    }
  }
}

/**
 * @typedef {(method: string, path: string, init?: { key?: string, body?: unknown, signal?: AbortSignal }) => Promise<{ status: number, json: any }>} Api
 */

/**
 * What setup created so far. Keys stay in memory only; never printed.
 * @typedef {object} SetupState
 * @property {{ key: string, groupId: string } | null} host
 * @property {string | null} inviteId set while an invite may still be usable
 * @property {{ trainerId: string, accessKey: string }[]} joined
 * @property {string | null} error why setup stopped early, or null when it finished
 */

/**
 * Creates the measurement group, issues an invite, joins `options.members` members and revokes
 * the invite. Never throws: on a failure or an interrupt it returns what exists so far with
 * `error` set, so the caller can undo it with releaseSetup.
 * @param {Api} api
 * @param {{ members: number }} options
 * @param {string} secret
 * @param {AbortSignal} signal aborted on interrupt
 * @param {() => string} now ISO time for the group name
 * @returns {Promise<SetupState>}
 */
export async function runSetup(api, options, secret, signal, now) {
  /** @type {SetupState} */
  const state = { host: null, inviteId: null, joined: [], error: null };
  const interrupted = () => {
    if (signal.aborted) state.error = "interrupted during setup";
    return signal.aborted;
  };
  try {
    if (interrupted()) return state;
    const created = await api("POST", "/v1/groups", {
      body: { operatorSecret: secret, groupName: `measure ${now().slice(0, 16)}`, displayEmail: "host@measure.invalid" },
      signal,
    });
    if (created.status === 200) state.host = { key: created.json.accessKey, groupId: created.json.group.groupId };
    if (interrupted()) return state;
    if (state.host === null) {
      state.error = `group creation failed with HTTP ${created.status}`;
      return state;
    }

    const invite = await api("POST", "/v1/invites", {
      key: state.host.key,
      body: { ttlSeconds: 3600, maxUses: options.members },
      signal,
    });
    if (invite.status === 200) state.inviteId = invite.json.invite.inviteId;
    if (interrupted()) return state;
    if (invite.status !== 200) {
      state.error = `invite failed with HTTP ${invite.status}`;
      return state;
    }

    for (let i = 1; i <= options.members; i += 1) {
      if (interrupted()) return state;
      const joined = await api("POST", "/v1/join", {
        body: { inviteCode: invite.json.inviteCode, displayEmail: memberEmail(i) },
        signal,
      });
      if (joined.status === 200) state.joined.push({ trainerId: joined.json.trainer.trainerId, accessKey: joined.json.accessKey });
      if (interrupted()) return state;
      if (joined.status !== 200) {
        state.error = `join ${i} failed with HTTP ${joined.status}`;
        return state;
      }
    }
    // Leave no usable invite behind.
    await revokeInvite(api, state);
  } catch {
    // An unexpected response shape. Its message could quote a response value, so it is dropped.
    state.error ??= "setup failed on an unexpected response";
  }
  return state;
}

/**
 * Revokes the setup's invite if it may still be usable. Uses no abort signal.
 * @param {Api} api
 * @param {SetupState} state
 * @returns {Promise<boolean>} true when no usable invite is left
 */
export async function revokeInvite(api, state) {
  if (state.host === null || state.inviteId === null) return true;
  const revoked = await api("POST", "/v1/invites/revoke", { key: state.host.key, body: { inviteId: state.inviteId } });
  if (revoked.status === 200) state.inviteId = null;
  return state.inviteId === null;
}

/**
 * Undoes a setup: revokes a still-usable invite and makes every joined member leave. The host
 * cannot leave (host_must_transfer) and groups cannot be deleted, so the group stays. Uses no
 * abort signal, so it also runs after an interrupt.
 * @param {Api} api
 * @param {SetupState} state
 */
export async function releaseSetup(api, state) {
  const inviteRevoked = await revokeInvite(api, state).catch(() => false);
  let membersLeft = 0;
  for (const member of state.joined) {
    const res = await api("POST", "/v1/leave", { key: member.accessKey }).catch(() => ({ status: 0 }));
    if (res.status === 200) membersLeft += 1;
  }
  return { inviteRevoked, membersJoined: state.joined.length, membersLeft };
}
